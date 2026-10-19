//
//  CleanerViewController.m
//  Cyanide
//

#import "CleanerViewController.h"
#import "FBAppContainers.h"
#import "SettingsViewController.h"
#import "FileBrowserViewController.h"
#import "installer/MainTabBarController.h"
#import <fts.h>
#import <sys/stat.h>
#import <errno.h>
#import <unistd.h>
#import <fcntl.h>
#import <dirent.h>

static NSString * const kCleanerAppDataPrefix =
    @"/private/var/mobile/Containers/Data/Application/";
static const NSUInteger kCleanerMaxScanEntries = 250000;

static void cleaner_suppress_popup_bar(UIViewController *vc, BOOL suppressed)
{
    UITabBarController *tbc = vc.tabBarController;
    if ([tbc isKindOfClass:MainTabBarController.class])
        [(MainTabBarController *)tbc setPopupBarSuppressed:suppressed];
}

static NSString *cleaner_bytes(unsigned long long bytes)
{
    return [NSByteCountFormatter stringFromByteCount:(long long)bytes
                                          countStyle:NSByteCountFormatterCountStyleFile];
}

static BOOL cleaner_path_is_app_data(NSString *path)
{
    NSString *canonical = fb_canonical_path(path);
    return canonical.length > kCleanerAppDataPrefix.length &&
           [canonical hasPrefix:kCleanerAppDataPrefix];
}

// procmgr names are truncated to 31 characters. An app whose executable is
// longer must still be recognized as active or Cleaner could delete its cache
// while it is live.
// Only the two disposable roots are ever cleared. The prefix check alone would
// also admit Documents or Library; require the exact tail as a second guard.
static BOOL cleaner_is_disposable_root(NSString *path)
{
    if (!cleaner_path_is_app_data(path)) return NO;
    NSArray<NSString *> *parts = fb_canonical_path(path).pathComponents;
    if (parts.count < 2) return NO;
    NSString *last = parts.lastObject;
    if ([last isEqualToString:@"tmp"]) return YES;
    return [last isEqualToString:@"Caches"] &&
           [parts[parts.count - 2] isEqualToString:@"Library"];
}

static BOOL cleaner_process_is_active(NSString *executable, NSSet<NSString *> *activeNames)
{
    if (executable.length == 0 || activeNames.count == 0) return NO;
    if ([activeNames containsObject:executable]) return YES;
    for (NSString *name in activeNames) {
        if (name.length > 0 && executable.length > name.length &&
            [executable hasPrefix:name]) return YES;
    }
    return NO;
}

// Physical walk: never follows symlinks and never crosses a mount. The result
// is a lower bound when `complete` is false (unreadable entry or scan cap).
static unsigned long long cleaner_tree_bytes(NSString *root,
                                             NSUInteger *fileCount,
                                             BOOL *complete)
{
    if (fileCount) *fileCount = 0;
    if (complete) *complete = YES;

    struct stat rootStat = {0};
    if (lstat(root.fileSystemRepresentation, &rootStat) != 0) {
        if (errno != ENOENT && complete) *complete = NO;
        return 0;
    }
    if (!S_ISDIR(rootStat.st_mode)) {
        if (complete) *complete = NO;
        return 0;
    }

    char *paths[] = { (char *)root.fileSystemRepresentation, NULL };
    FTS *fts = fts_open(paths, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, NULL);
    if (!fts) {
        if (complete) *complete = NO;
        return 0;
    }

    unsigned long long total = 0;
    NSUInteger count = 0;
    FTSENT *entry;
    while ((entry = fts_read(fts))) {
        if (entry->fts_info == FTS_DNR || entry->fts_info == FTS_ERR ||
            entry->fts_info == FTS_NS) {
            if (complete) *complete = NO;
            continue;
        }
        if (entry->fts_info == FTS_DP) continue;
        if (entry->fts_level == 0) continue;   // the cache/tmp root itself
        if (entry->fts_info == FTS_SL || entry->fts_info == FTS_SLNONE) continue;
        if (!entry->fts_statp ||
            (entry->fts_statp->st_mode & S_IFMT) != S_IFREG) continue;

        total += (unsigned long long)entry->fts_statp->st_size;
        count++;
        if (count >= kCleanerMaxScanEntries) {
            if (complete) *complete = NO;
            break;
        }
    }
    fts_close(fts);
    if (fileCount) *fileCount = count;
    return total;
}

// Recursive removal relative to an open directory, with O_NOFOLLOW at every
// step. Using fstatat/openat/unlinkat instead of path-based NSFileManager closes
// the symlink-swap race: an app being cleaned cannot turn one of its cache
// entries into a link to another container between our check and our delete.
static unsigned long long cleaner_remove_tree_at(int parentFD, const char *name,
                                                 NSUInteger *removed,
                                                 NSUInteger *failed)
{
    struct stat st = {0};
    if (fstatat(parentFD, name, &st, AT_SYMLINK_NOFOLLOW) != 0) {
        if (errno != ENOENT && failed) (*failed)++;
        return 0;
    }

    if (!S_ISDIR(st.st_mode)) {
        if (unlinkat(parentFD, name, 0) == 0) {
            if (removed) (*removed)++;
            return S_ISREG(st.st_mode) ? (unsigned long long)st.st_size : 0;
        }
        if (failed) (*failed)++;
        return 0;
    }

    int dirFD = openat(parentFD, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (dirFD < 0) {
        if (failed) (*failed)++;
        return 0;
    }
    DIR *dir = fdopendir(dirFD);
    if (!dir) {
        close(dirFD);
        if (failed) (*failed)++;
        return 0;
    }

    unsigned long long freed = 0;
    struct dirent *entry;
    while ((entry = readdir(dir))) {
        if (!entry->d_name[0] ||
            (entry->d_name[0] == '.' && entry->d_name[1] == '\0') ||
            (entry->d_name[0] == '.' && entry->d_name[1] == '.' &&
             entry->d_name[2] == '\0')) continue;
        freed += cleaner_remove_tree_at(dirFD, entry->d_name, removed, failed);
    }
    closedir(dir);

    if (unlinkat(parentFD, name, AT_REMOVEDIR) != 0) {
        if (failed) (*failed)++;
        return 0;   // partial deletion: do not claim its bytes as freed
    }
    return freed;
}

// Removes the CONTENTS of `dir`, never the directory itself. Returns the number
// of bytes whose removal succeeded.
static unsigned long long cleaner_clear_directory(NSString *dir,
                                                  NSUInteger *removed,
                                                  NSUInteger *failed)
{
    if (removed) *removed = 0;
    if (failed) *failed = 0;
    if (!cleaner_is_disposable_root(dir)) return 0;

    int rootFD = open(dir.fileSystemRepresentation,
                      O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (rootFD < 0) {
        if (errno != ENOENT && failed) (*failed)++;
        return 0;
    }
    DIR *root = fdopendir(rootFD);
    if (!root) {
        close(rootFD);
        if (failed) (*failed)++;
        return 0;
    }

    unsigned long long freed = 0;
    struct dirent *entry;
    while ((entry = readdir(root))) {
        if (!entry->d_name[0] ||
            (entry->d_name[0] == '.' && entry->d_name[1] == '\0') ||
            (entry->d_name[0] == '.' && entry->d_name[1] == '.' &&
             entry->d_name[2] == '\0')) continue;
        freed += cleaner_remove_tree_at(rootFD, entry->d_name, removed, failed);
    }
    closedir(root);
    return freed;
}

@interface CYCleanerItem : NSObject
@property (nonatomic, strong) FBAppContainer *container;
@property (nonatomic, strong) UIImage *icon;
@property (nonatomic, copy) NSString *name;
@property (nonatomic) unsigned long long cacheBytes;
@property (nonatomic) unsigned long long tempBytes;
@property (nonatomic) BOOL active;
@property (nonatomic) BOOL systemApp;
@property (nonatomic) BOOL selected;
@property (nonatomic) BOOL incomplete;
@end

@implementation CYCleanerItem
- (unsigned long long)totalBytes
{
    return self.cacheBytes + self.tempBytes;
}
@end

@interface CYCleanerFoldersViewController : UITableViewController
@property (nonatomic, copy) NSArray<CYCleanerItem *> *items;
@end

#pragma mark - Cells

// App row: selection circle, icon, name, "cache · temp" below, and the size
// right-aligned in a fixed column (same look as System Info's app list).
@interface CYCleanerAppCell : UITableViewCell
@property (nonatomic, strong) UIImageView *checkView;
@property (nonatomic, strong) UIImageView *iconView;
@property (nonatomic, strong) UILabel *nameLabel;
@property (nonatomic, strong) UILabel *detailLabel;
@property (nonatomic, strong) UILabel *sizeLabel;
@end

@implementation CYCleanerAppCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier
{
    if ((self = [super initWithStyle:style reuseIdentifier:reuseIdentifier])) {
        _checkView = [UIImageView new];
        _checkView.contentMode = UIViewContentModeScaleAspectFit;
        _iconView = [UIImageView new];
        _iconView.contentMode = UIViewContentModeScaleAspectFit;
        _iconView.layer.cornerRadius = 8;
        _iconView.layer.cornerCurve = kCACornerCurveContinuous;
        _iconView.clipsToBounds = YES;
        _nameLabel = [UILabel new];
        _nameLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
        _detailLabel = [UILabel new];
        _detailLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
        _detailLabel.textColor = UIColor.secondaryLabelColor;
        _sizeLabel = [UILabel new];
        _sizeLabel.font = [UIFont monospacedDigitSystemFontOfSize:15 weight:UIFontWeightSemibold];
        _sizeLabel.textAlignment = NSTextAlignmentRight;
        for (UIView *v in @[ _checkView, _iconView, _nameLabel, _detailLabel, _sizeLabel ]) {
            v.translatesAutoresizingMaskIntoConstraints = NO;
            [self.contentView addSubview:v];
        }
        UILayoutGuide *m = self.contentView.layoutMarginsGuide;
        [_sizeLabel setContentCompressionResistancePriority:UILayoutPriorityRequired
                                                    forAxis:UILayoutConstraintAxisHorizontal];
        [NSLayoutConstraint activateConstraints:@[
            [_checkView.leadingAnchor constraintEqualToAnchor:m.leadingAnchor],
            [_checkView.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
            [_checkView.widthAnchor constraintEqualToConstant:24],
            [_checkView.heightAnchor constraintEqualToConstant:24],
            [_iconView.leadingAnchor constraintEqualToAnchor:_checkView.trailingAnchor constant:12],
            [_iconView.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
            [_iconView.widthAnchor constraintEqualToConstant:36],
            [_iconView.heightAnchor constraintEqualToConstant:36],
            [_sizeLabel.trailingAnchor constraintEqualToAnchor:m.trailingAnchor],
            [_sizeLabel.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
            [_sizeLabel.widthAnchor constraintGreaterThanOrEqualToConstant:76],
            [_nameLabel.leadingAnchor constraintEqualToAnchor:_iconView.trailingAnchor constant:12],
            [_nameLabel.trailingAnchor constraintLessThanOrEqualToAnchor:_sizeLabel.leadingAnchor constant:-8],
            [_nameLabel.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:11],
            [_detailLabel.leadingAnchor constraintEqualToAnchor:_nameLabel.leadingAnchor],
            [_detailLabel.trailingAnchor constraintLessThanOrEqualToAnchor:_sizeLabel.leadingAnchor constant:-8],
            [_detailLabel.topAnchor constraintEqualToAnchor:_nameLabel.bottomAnchor constant:2],
            [_detailLabel.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-11],
        ]];
    }
    return self;
}

@end

// Summary card: the reclaimable total, a bar for the selected share, and the
// scan progress or the last result.
@interface CYCleanerSummaryCell : UITableViewCell
@property (nonatomic, strong) UILabel *captionLabel;
@property (nonatomic, strong) UILabel *totalLabel;
@property (nonatomic, strong) UIProgressView *bar;
@property (nonatomic, strong) UILabel *statusLabel;
@end

@implementation CYCleanerSummaryCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier
{
    if ((self = [super initWithStyle:style reuseIdentifier:reuseIdentifier])) {
        self.selectionStyle = UITableViewCellSelectionStyleNone;
        _captionLabel = [UILabel new];
        _captionLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
        _captionLabel.textColor = UIColor.secondaryLabelColor;
        _totalLabel = [UILabel new];
        UIFont *big = [UIFont systemFontOfSize:34 weight:UIFontWeightBold];
        _totalLabel.font = [[UIFontMetrics metricsForTextStyle:UIFontTextStyleLargeTitle] scaledFontForFont:big];
        _totalLabel.adjustsFontForContentSizeCategory = YES;
        _bar = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
        _bar.progressTintColor = UIColor.systemBlueColor;
        _statusLabel = [UILabel new];
        _statusLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
        _statusLabel.textColor = UIColor.secondaryLabelColor;
        _statusLabel.numberOfLines = 0;
        UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[ _captionLabel, _totalLabel, _bar, _statusLabel ]];
        stack.axis = UILayoutConstraintAxisVertical;
        stack.spacing = 6;
        [stack setCustomSpacing:10 afterView:_totalLabel];
        stack.translatesAutoresizingMaskIntoConstraints = NO;
        [self.contentView addSubview:stack];
        UILayoutGuide *m = self.contentView.layoutMarginsGuide;
        [NSLayoutConstraint activateConstraints:@[
            [stack.leadingAnchor constraintEqualToAnchor:m.leadingAnchor],
            [stack.trailingAnchor constraintEqualToAnchor:m.trailingAnchor],
            [stack.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:14],
            [stack.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-14],
        ]];
    }
    return self;
}

@end

#pragma mark - Cleaner

typedef NS_ENUM(NSInteger, CYCleanerSection) {
    CYCleanerSectionSummary,
    CYCleanerSectionApps,
    CYCleanerSectionSystem,
    CYCleanerSectionSkipped,
    CYCleanerSectionCount,
};

typedef NS_ENUM(NSInteger, CYCleanerSort) { CYCleanerSortSize, CYCleanerSortName };
static NSString * const kCleanerSortKey = @"CleanerSort";

@interface CleanerViewController () <UISearchResultsUpdating>
@property (nonatomic, copy) NSArray<CYCleanerItem *> *items;
@property (nonatomic) BOOL processListAvailable;
@property (nonatomic) BOOL accessReady;
@property (nonatomic) BOOL loading;
@property (nonatomic) BOOL cleaning;
@property (nonatomic) NSUInteger scanDone;
@property (nonatomic) NSUInteger scanTotal;
@property (nonatomic, copy) NSString *scanName;
@property (nonatomic, copy) NSString *resultText;     // last clean's result, shown on the card
@property (nonatomic, copy) NSString *accessMessage;  // why there's no list
@property (nonatomic) BOOL skippedExpanded;
@property (nonatomic) CYCleanerSort sort;
@property (nonatomic, copy) NSString *filter;
@property (nonatomic, strong) UISearchController *searchCtrl;
@property (nonatomic, strong) UIButton *cleanButton;
@property (nonatomic, strong) UIProgressView *cleanProgress;
@end

@implementation CleanerViewController

- (instancetype)init
{
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (self) self.title = @"Cleaner";
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeAlways;
    self.tableView.estimatedRowHeight = 64.0;
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.sort = (CYCleanerSort)[NSUserDefaults.standardUserDefaults integerForKey:kCleanerSortKey];
    self.filter = @"";

    self.searchCtrl = [[UISearchController alloc] initWithSearchResultsController:nil];
    self.searchCtrl.searchResultsUpdater = self;
    self.searchCtrl.obscuresBackgroundDuringPresentation = NO;
    self.searchCtrl.searchBar.placeholder = @"Filter apps";
    self.navigationItem.searchController = self.searchCtrl;
    self.navigationItem.hidesSearchBarWhenScrolling = YES;
    self.definesPresentationContext = YES;

    UIRefreshControl *refresh = [[UIRefreshControl alloc] init];
    [refresh addTarget:self action:@selector(refreshPulled:) forControlEvents:UIControlEventValueChanged];
    self.refreshControl = refresh;

    [self buildBottomBar];
    [self updateControls];
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    [self.navigationController setToolbarHidden:NO animated:animated];
}

- (void)viewDidAppear:(BOOL)animated
{
    [super viewDidAppear:animated];
    cleaner_suppress_popup_bar(self, YES);
    if (!self.accessReady && !self.loading) [self ensureAccessAllowingFullExploit:NO];
}

- (void)viewWillDisappear:(BOOL)animated
{
    [super viewWillDisappear:animated];
    [self.navigationController setToolbarHidden:YES animated:animated];
    cleaner_suppress_popup_bar(self, NO);
}

// The clean button lives in the toolbar so it stays put while the list scrolls.
- (void)buildBottomBar
{
    UIButtonConfiguration *cfg = [UIButtonConfiguration filledButtonConfiguration];
    cfg.baseBackgroundColor = UIColor.systemBlueColor;
    cfg.cornerStyle = UIButtonConfigurationCornerStyleLarge;
    cfg.contentInsets = NSDirectionalEdgeInsetsMake(10, 16, 10, 16);
    self.cleanButton = [UIButton buttonWithConfiguration:cfg primaryAction:nil];
    [self.cleanButton addTarget:self action:@selector(cleanSelected:) forControlEvents:UIControlEventTouchUpInside];
    self.cleanProgress = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleBar];
    self.cleanProgress.progressTintColor = UIColor.whiteColor;
    self.cleanProgress.trackTintColor = [UIColor.whiteColor colorWithAlphaComponent:0.3];
    self.cleanProgress.hidden = YES;
    self.cleanProgress.translatesAutoresizingMaskIntoConstraints = NO;
    self.cleanProgress.userInteractionEnabled = NO;
    [self.cleanButton addSubview:self.cleanProgress];
    [NSLayoutConstraint activateConstraints:@[
        [self.cleanProgress.leadingAnchor constraintEqualToAnchor:self.cleanButton.leadingAnchor constant:16],
        [self.cleanProgress.trailingAnchor constraintEqualToAnchor:self.cleanButton.trailingAnchor constant:-16],
        [self.cleanProgress.bottomAnchor constraintEqualToAnchor:self.cleanButton.bottomAnchor constant:-6],
    ]];
    self.cleanButton.translatesAutoresizingMaskIntoConstraints = NO;
    UIView *holder = [UIView new];
    [holder addSubview:self.cleanButton];
    holder.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:@[
        [self.cleanButton.leadingAnchor constraintEqualToAnchor:holder.leadingAnchor],
        [self.cleanButton.trailingAnchor constraintEqualToAnchor:holder.trailingAnchor],
        [self.cleanButton.topAnchor constraintEqualToAnchor:holder.topAnchor],
        [self.cleanButton.bottomAnchor constraintEqualToAnchor:holder.bottomAnchor],
        [holder.widthAnchor constraintEqualToConstant:MIN(UIScreen.mainScreen.bounds.size.width - 40, 520)],
    ]];
    UIBarButtonItem *flex = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace
                                                                          target:nil action:nil];
    self.toolbarItems = @[ flex, [[UIBarButtonItem alloc] initWithCustomView:holder], flex ];
}

#pragma mark Data views

- (BOOL)matchesFilter:(CYCleanerItem *)item
{
    if (!self.filter.length) return YES;
    return [item.name rangeOfString:self.filter options:NSCaseInsensitiveSearch].location != NSNotFound ||
           (item.container.identifier &&
            [item.container.identifier rangeOfString:self.filter options:NSCaseInsensitiveSearch].location != NSNotFound);
}

- (NSArray<CYCleanerItem *> *)itemsInSection:(NSInteger)section
{
    NSMutableArray<CYCleanerItem *> *out = [NSMutableArray array];
    for (CYCleanerItem *item in self.items) {
        if (![self matchesFilter:item]) continue;
        BOOL skipped = item.active || !self.processListAvailable;
        if (section == CYCleanerSectionSkipped && skipped) [out addObject:item];
        else if (section == CYCleanerSectionApps && !skipped && !item.systemApp) [out addObject:item];
        else if (section == CYCleanerSectionSystem && !skipped && item.systemApp) [out addObject:item];
    }
    CYCleanerSort sort = self.sort;
    [out sortUsingComparator:^NSComparisonResult(CYCleanerItem *a, CYCleanerItem *b) {
        if (sort == CYCleanerSortSize && a.totalBytes != b.totalBytes)
            return a.totalBytes > b.totalBytes ? NSOrderedAscending : NSOrderedDescending;
        return [a.name localizedCaseInsensitiveCompare:b.name];
    }];
    return out;
}

- (BOOL)itemSelectable:(CYCleanerItem *)item
{
    return !item.active && item.totalBytes > 0 && self.processListAvailable && !self.loading && !self.cleaning;
}

- (NSUInteger)selectedCount
{
    NSUInteger count = 0;
    for (CYCleanerItem *item in self.items) if (item.selected) count++;
    return count;
}

- (unsigned long long)selectedBytes
{
    unsigned long long bytes = 0;
    for (CYCleanerItem *item in self.items) if (item.selected) bytes += item.totalBytes;
    return bytes;
}

- (unsigned long long)totalBytes
{
    unsigned long long bytes = 0;
    for (CYCleanerItem *item in self.items) bytes += item.totalBytes;
    return bytes;
}

#pragma mark Controls

- (void)updateControls
{
    NSUInteger count = [self selectedCount];
    BOOL enabled = !self.loading && !self.cleaning && self.accessReady && self.processListAvailable && count > 0;
    UIButtonConfiguration *cfg = self.cleanButton.configuration;
    if (self.cleaning) cfg.title = @"Cleaning…";
    else if (count > 0)
        cfg.title = [NSString stringWithFormat:@"Clean %lu App%@ · %@", (unsigned long)count,
                     count == 1 ? @"" : @"s", cleaner_bytes([self selectedBytes])];
    else cfg.title = @"Select Apps to Clean";
    self.cleanButton.configuration = cfg;
    self.cleanButton.enabled = enabled;
    self.cleanProgress.hidden = !self.cleaning;

    // ⋯ menu: sorting, select all, folder review.
    __weak typeof(self) weakSelf = self;
    UIAction *(^sortAction)(NSString *, CYCleanerSort) = ^UIAction *(NSString *title, CYCleanerSort s) {
        UIAction *a = [UIAction actionWithTitle:title image:nil identifier:nil handler:^(UIAction *x) {
            weakSelf.sort = s;
            [NSUserDefaults.standardUserDefaults setInteger:s forKey:kCleanerSortKey];
            [weakSelf.tableView reloadData];
            [weakSelf updateControls];
        }];
        a.state = self.sort == s ? UIMenuElementStateOn : UIMenuElementStateOff;
        return a;
    };
    BOOL busy = self.loading || self.cleaning;
    NSUInteger selectable = 0, selected = 0;
    for (CYCleanerItem *item in self.items) {
        if (item.active || item.systemApp || item.totalBytes == 0) continue;
        selectable++;
        if (item.selected) selected++;
    }
    BOOL allSelected = selectable > 0 && selected == selectable;
    UIAction *selectAll = [UIAction actionWithTitle:allSelected ? @"Deselect All" : @"Select All Apps"
                                              image:[UIImage systemImageNamed:allSelected ? @"circle" : @"checkmark.circle"]
                                         identifier:nil handler:^(UIAction *x) { [weakSelf toggleSelectAll:nil]; }];
    if (busy || !self.processListAvailable || selectable == 0) selectAll.attributes = UIMenuElementAttributesDisabled;
    UIAction *folders = [UIAction actionWithTitle:@"Review Folders" image:[UIImage systemImageNamed:@"folder"]
                                       identifier:nil handler:^(UIAction *x) { [weakSelf showSelectedFolders:nil]; }];
    if (busy || count == 0) folders.attributes = UIMenuElementAttributesDisabled;
    UIMenu *menu = [UIMenu menuWithChildren:@[
        [UIMenu menuWithTitle:@"" image:nil identifier:nil options:UIMenuOptionsDisplayInline children:@[ selectAll, folders ]],
        [UIMenu menuWithTitle:@"Sort By" image:nil identifier:nil options:UIMenuOptionsDisplayInline children:@[
            sortAction(@"Size", CYCleanerSortSize), sortAction(@"Name", CYCleanerSortName),
        ]],
    ]];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithImage:[UIImage systemImageNamed:@"ellipsis.circle"] menu:menu];
}

- (void)reloadSummary
{
    NSIndexPath *ip = [NSIndexPath indexPathForRow:0 inSection:CYCleanerSectionSummary];
    CYCleanerSummaryCell *cell = (CYCleanerSummaryCell *)[self.tableView cellForRowAtIndexPath:ip];
    if ([cell isKindOfClass:CYCleanerSummaryCell.class]) [self configureSummary:cell];
}

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController
{
    self.filter = [searchController.searchBar.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet] ?: @"";
    [self.tableView reloadData];
}

#pragma mark Access and scanning

// Like System Info: live or parked kernel access is used directly; a full
// exploit run only after asking (it can reboot A18/M4 devices).
- (void)ensureAccessAllowingFullExploit:(BOOL)allowFullExploit
{
    if (self.loading) return;
    if (settings_filesystem_access_available()) {
        self.accessReady = YES;
        [self reloadData];
        return;
    }
    self.loading = YES;
    self.accessMessage = nil;
    self.scanName = nil;
    [self.tableView reloadData];
    [self updateControls];
    __weak typeof(self) weakSelf = self;
    settings_unlock_filesystem_async(allowFullExploit, ^(BOOL ok, NSString *message) {
        typeof(self) self = weakSelf;
        if (!self) return;
        self.loading = NO;
        if (ok) {
            self.accessReady = YES;
            [self reloadData];
            return;
        }
        BOOL needsFullRun = [message isEqualToString:kSettingsFullExploitRequiredMessage];
        self.accessMessage = needsFullRun
            ? @"Needs kernel access, and there is no saved session. Tap here to run the full exploit."
            : (message ?: @"Filesystem access is not available.");
        [self.tableView reloadData];
        [self updateControls];
        if (needsFullRun && !allowFullExploit && self.view.window && !self.presentedViewController)
            [self confirmFullExploit];
    });
}

- (void)confirmFullExploit
{
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"No parked kernel state"
        message:@"Cleaner needs kernel access, and there is no saved session to reuse. Running the full exploit can reboot the device on A18/M4. Continue?"
        preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [ac addAction:[UIAlertAction actionWithTitle:@"Run Full Exploit" style:UIAlertActionStyleDefault
                                         handler:^(UIAlertAction *a) { [weakSelf ensureAccessAllowingFullExploit:YES]; }]];
    [self presentViewController:ac animated:YES completion:nil];
}

- (void)refreshPulled:(UIRefreshControl *)sender
{
    (void)sender;
    if (self.loading || self.cleaning) {
        [self.refreshControl endRefreshing];
        return;
    }
    [self.refreshControl endRefreshing];
    self.resultText = nil;
    [self reloadData];
}

- (void)reloadData
{
    if (self.loading || self.cleaning) return;
    if (!self.accessReady || !settings_filesystem_access_available()) {
        [self ensureAccessAllowingFullExploit:NO];
        return;
    }

    self.loading = YES;
    self.scanDone = 0;
    self.scanTotal = 0;
    self.scanName = nil;
    self.accessMessage = nil;
    [self.tableView reloadData];
    [self updateControls];
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        @autoreleasepool {
            // Keep the scan independent of the File Browser's cached metadata.
            fb_containers_reset();
            NSArray<FBAppContainer *> *containers = fb_app_data_containers();
            NSUInteger total = containers.count;
            dispatch_async(dispatch_get_main_queue(), ^{
                typeof(self) self = weakSelf;
                if (!self || !self.loading) return;
                self.scanTotal = total;
                [self reloadSummary];
            });
            NSSet<NSString *> *active = settings_active_process_names();
            BOOL processListAvailable = (active != nil);
            if (!active) active = [NSSet set];

            NSMutableArray<CYCleanerItem *> *items = [NSMutableArray array];
            NSUInteger scanned = 0;
            for (FBAppContainer *container in containers) {
                if (![container isKindOfClass:FBAppContainer.class]) continue;
                if (!cleaner_path_is_app_data(container.path)) continue;

                CYCleanerItem *item = [[CYCleanerItem alloc] init];
                item.container = container;
                item.name = container.displayName.length ? container.displayName : container.identifier;
                item.systemApp = container.systemApp;
                item.active = cleaner_process_is_active(container.executableName, active);

                NSString *cachePath = [container.path stringByAppendingPathComponent:@"Library/Caches"];
                NSString *tmpPath = [container.path stringByAppendingPathComponent:@"tmp"];
                BOOL complete = NO;
                item.cacheBytes = cleaner_tree_bytes(cachePath, NULL, &complete);
                item.incomplete = !complete;
                complete = NO;
                item.tempBytes = cleaner_tree_bytes(tmpPath, NULL, &complete);
                item.incomplete = item.incomplete || !complete;
                item.icon = container.icon;   // loaded off the main thread
                scanned++;
                NSString *name = item.name;
                NSUInteger done = scanned;
                dispatch_async(dispatch_get_main_queue(), ^{
                    typeof(self) self = weakSelf;
                    if (!self || !self.loading) return;
                    self.scanDone = done;
                    self.scanName = name;
                    [self reloadSummary];
                });
                // Apps with nothing reclaimable are noise in this screen.
                if (item.totalBytes == 0) continue;
                item.selected = processListAvailable && !item.active && !item.systemApp;
                [items addObject:item];
            }

            dispatch_async(dispatch_get_main_queue(), ^{
                typeof(self) self = weakSelf;
                if (!self) return;
                self.items = items;
                self.processListAvailable = processListAvailable;
                self.loading = NO;
                [self.tableView reloadData];
                [self updateControls];
            });
        }
    });
}

#pragma mark Actions

- (void)toggleSelectAll:(id)sender
{
    (void)sender;
    if (self.loading || self.cleaning || !self.processListAvailable) return;
    NSArray<CYCleanerItem *> *selectable = [self.items filteredArrayUsingPredicate:
        [NSPredicate predicateWithBlock:^BOOL(CYCleanerItem *item, NSDictionary *bindings) {
            (void)bindings;
            return !item.active && !item.systemApp && item.totalBytes > 0;
        }]];
    BOOL allSelected = selectable.count > 0;
    for (CYCleanerItem *item in selectable) {
        if (!item.selected) { allSelected = NO; break; }
    }
    for (CYCleanerItem *item in selectable) item.selected = !allSelected;
    [self.tableView reloadData];
    [self updateControls];
}

- (void)showSelectedFolders:(id)sender
{
    (void)sender;
    NSMutableArray<CYCleanerItem *> *selected = [NSMutableArray array];
    for (CYCleanerItem *item in self.items) if (item.selected) [selected addObject:item];
    if (selected.count == 0) return;
    CYCleanerFoldersViewController *vc = [[CYCleanerFoldersViewController alloc] init];
    vc.items = selected;
    [self.navigationController pushViewController:vc animated:YES];
}

- (void)openInFileBrowser:(NSString *)path
{
    FileBrowserViewController *vc = [[FileBrowserViewController alloc] initWithPath:path];
    [self.navigationController pushViewController:vc animated:YES];
}

- (void)cleanSelected:(id)sender
{
    (void)sender;
    if (self.loading || self.cleaning || !self.accessReady) return;
    if (!self.processListAvailable) {
        UIAlertController *alert = [UIAlertController
            alertControllerWithTitle:@"Kernel Access Needed"
                             message:@"Cleaner cannot tell which apps are active without kernel access. Run the chain once, then try again."
                      preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }
    NSUInteger count = [self selectedCount];
    if (count == 0) return;

    NSString *message = [NSString stringWithFormat:
        @"Remove Library/Caches and tmp contents for %lu app%@ (%@)? Documents, settings and app data are not touched. Apps may need to redownload content.",
        (unsigned long)count, count == 1 ? @"" : @"s", cleaner_bytes([self selectedBytes])];
    UIAlertController *confirm = [UIAlertController alertControllerWithTitle:@"Clean Caches?"
                                                                     message:message
                                                              preferredStyle:UIAlertControllerStyleAlert];
    [confirm addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [confirm addAction:[UIAlertAction actionWithTitle:@"Clean" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        (void)action;
        [weakSelf performClean];
    }]];
    [self presentViewController:confirm animated:YES completion:nil];
}

- (void)performClean
{
    if (self.cleaning) return;
    self.cleaning = YES;
    self.resultText = nil;
    self.cleanProgress.progress = 0;
    [self updateControls];
    [self.tableView reloadData];

    // The selection, taken on the main thread before the work starts.
    NSMutableArray<CYCleanerItem *> *work = [NSMutableArray array];
    for (CYCleanerItem *item in self.items) if (item.selected) [work addObject:item];

    __block UIBackgroundTaskIdentifier bgTask =
        [UIApplication.sharedApplication beginBackgroundTaskWithName:@"cyanide.cleaner" expirationHandler:^{}];

    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        @autoreleasepool {
            NSSet<NSString *> *active = settings_active_process_names();
            NSUInteger cleanedApps = 0, skippedActive = 0, failedApps = 0, done = 0;
            unsigned long long freed = 0;

            if (active) {
                for (CYCleanerItem *item in work) {
                    done++;
                    float fraction = (float)done / (float)MAX(work.count, (NSUInteger)1);
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [weakSelf.cleanProgress setProgress:fraction animated:YES];
                    });
                    if (!cleaner_path_is_app_data(item.container.path)) { failedApps++; continue; }
                    if (cleaner_process_is_active(item.container.executableName, active)) {
                        item.active = YES;
                        item.selected = NO;
                        skippedActive++;
                        continue;
                    }

                    NSUInteger removed = 0, failed = 0;
                    unsigned long long appFreed = 0;
                    appFreed += cleaner_clear_directory(
                        [item.container.path stringByAppendingPathComponent:@"Library/Caches"],
                        &removed, &failed);
                    appFreed += cleaner_clear_directory(
                        [item.container.path stringByAppendingPathComponent:@"tmp"],
                        &removed, &failed);
                    freed += appFreed;

                    BOOL complete = NO;
                    item.cacheBytes = cleaner_tree_bytes(
                        [item.container.path stringByAppendingPathComponent:@"Library/Caches"], NULL, &complete);
                    item.incomplete = !complete;
                    complete = NO;
                    item.tempBytes = cleaner_tree_bytes(
                        [item.container.path stringByAppendingPathComponent:@"tmp"], NULL, &complete);
                    item.incomplete = item.incomplete || !complete;
                    item.selected = NO;
                    if (failed > 0) failedApps++;
                    if (removed > 0) cleanedApps++;
                }
            }

            dispatch_async(dispatch_get_main_queue(), ^{
                typeof(self) self = weakSelf;
                if (bgTask != UIBackgroundTaskInvalid) {
                    [UIApplication.sharedApplication endBackgroundTask:bgTask];
                    bgTask = UIBackgroundTaskInvalid;
                }
                if (!self) return;
                self.cleaning = NO;
                if (!active) {
                    self.resultText = @"Stopped: the active-app list was unavailable, so nothing was removed.";
                } else {
                    NSMutableString *result = [NSMutableString stringWithFormat:
                        @"Freed %@ from %lu app%@.", cleaner_bytes(freed),
                        (unsigned long)cleanedApps, cleanedApps == 1 ? @"" : @"s"];
                    if (skippedActive > 0)
                        [result appendFormat:@" Skipped %lu active app%@.", (unsigned long)skippedActive,
                         skippedActive == 1 ? @"" : @"s"];
                    if (failedApps > 0)
                        [result appendFormat:@" Some files in %lu app%@ could not be removed.",
                         (unsigned long)failedApps, failedApps == 1 ? @"" : @"s"];
                    self.resultText = result;
                }
                // Emptied apps drop out of the list; the card shows the result.
                self.items = [self.items filteredArrayUsingPredicate:
                    [NSPredicate predicateWithBlock:^BOOL(CYCleanerItem *item, NSDictionary *b) {
                        return item.totalBytes > 0;
                    }]];
                [self.tableView reloadData];
                [self updateControls];
                UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification, self.resultText);
            });
        }
    });
}

#pragma mark Table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView
{
    return CYCleanerSectionCount;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    if (section == CYCleanerSectionSummary) return 1;
    NSInteger count = (NSInteger)[self itemsInSection:section].count;
    if (section == CYCleanerSectionSkipped && !self.skippedExpanded) return 0;
    return count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
    NSUInteger count = section == CYCleanerSectionSummary ? 0 : [self itemsInSection:section].count;
    if (!count) return nil;
    switch ((CYCleanerSection)section) {
        case CYCleanerSectionApps:   return [NSString stringWithFormat:@"Apps (%lu)", (unsigned long)count];
        case CYCleanerSectionSystem: return [NSString stringWithFormat:@"Built-in Apps (%lu)", (unsigned long)count];
        default: return nil;
    }
}

// "Skipped (in use)" folds open and closed on tap.
- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section
{
    if (section != CYCleanerSectionSkipped) return nil;
    NSUInteger count = [self itemsInSection:section].count;
    if (!count) return nil;
    UIButtonConfiguration *cfg = [UIButtonConfiguration plainButtonConfiguration];
    cfg.title = [NSString stringWithFormat:@"%@ (%lu)", self.processListAvailable ? @"Skipped — In Use" : @"Not Checked",
                 (unsigned long)count];
    cfg.image = [UIImage systemImageNamed:self.skippedExpanded ? @"chevron.down" : @"chevron.right"];
    cfg.imagePlacement = NSDirectionalRectEdgeTrailing;
    cfg.imagePadding = 6;
    cfg.baseForegroundColor = UIColor.secondaryLabelColor;
    cfg.contentInsets = NSDirectionalEdgeInsetsMake(8, 20, 4, 20);
    __weak typeof(self) weakSelf = self;
    UIButton *b = [UIButton buttonWithConfiguration:cfg primaryAction:[UIAction actionWithHandler:^(UIAction *a) {
        weakSelf.skippedExpanded = !weakSelf.skippedExpanded;
        [weakSelf.tableView reloadSections:[NSIndexSet indexSetWithIndex:CYCleanerSectionSkipped]
                          withRowAnimation:UITableViewRowAnimationAutomatic];
    }]];
    b.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeading;
    return b;
}

- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section
{
    if (section == CYCleanerSectionSkipped)
        return [self itemsInSection:section].count ? 40 : CGFLOAT_MIN;
    return UITableViewAutomaticDimension;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section
{
    if (section != CYCleanerSectionSkipped) return nil;
    return @"Only Library/Caches and tmp contents are removed. Documents, settings and app data are not touched. "
           @"Apps in use are skipped; built-in apps are not selected by default. Long-press an app to open its caches "
           @"in the File Browser.";
}

- (void)configureSummary:(CYCleanerSummaryCell *)cell
{
    unsigned long long total = [self totalBytes], selected = [self selectedBytes];
    if (self.loading) {
        cell.captionLabel.text = @"Scanning";
        cell.totalLabel.text = self.scanTotal ? [NSString stringWithFormat:@"%lu / %lu",
                                                 (unsigned long)self.scanDone, (unsigned long)self.scanTotal] : @"…";
        cell.bar.progress = self.scanTotal ? (float)self.scanDone / (float)self.scanTotal : 0;
        cell.bar.progressTintColor = UIColor.systemBlueColor;
        cell.statusLabel.text = self.scanName.length ? [NSString stringWithFormat:@"Checking %@…", self.scanName]
                              : (self.accessReady ? @"Finding app containers…" : @"Getting filesystem access…");
        return;
    }
    cell.bar.progressTintColor = UIColor.systemBlueColor;
    if (!self.accessReady) {
        cell.captionLabel.text = @"Cleaner";
        cell.totalLabel.text = @"—";
        cell.bar.progress = 0;
        cell.statusLabel.text = self.accessMessage ?: @"Filesystem access is not available.";
        return;
    }
    cell.captionLabel.text = @"Reclaimable";
    cell.totalLabel.text = cleaner_bytes(total);
    cell.bar.progress = total ? (float)((double)selected / (double)total) : 0;
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    if (self.resultText) [lines addObject:self.resultText];
    [lines addObject:[NSString stringWithFormat:@"%@ selected in %lu app%@", cleaner_bytes(selected),
                      (unsigned long)[self selectedCount], [self selectedCount] == 1 ? @"" : @"s"]];
    if (!self.processListAvailable)
        [lines addObject:@"Kernel access is unavailable, so apps in use can't be detected and nothing can be cleaned."];
    cell.statusLabel.text = [lines componentsJoinedByString:@"\n"];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (indexPath.section == CYCleanerSectionSummary) {
        CYCleanerSummaryCell *cell = [tableView dequeueReusableCellWithIdentifier:@"cleaner-summary"];
        if (!cell) cell = [[CYCleanerSummaryCell alloc] initWithStyle:UITableViewCellStyleDefault
                                                      reuseIdentifier:@"cleaner-summary"];
        [self configureSummary:cell];
        return cell;
    }
    CYCleanerItem *item = [self itemsInSection:indexPath.section][(NSUInteger)indexPath.row];
    CYCleanerAppCell *cell = [tableView dequeueReusableCellWithIdentifier:@"cleaner-app"];
    if (!cell) cell = [[CYCleanerAppCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"cleaner-app"];
    BOOL selectable = [self itemSelectable:item];
    cell.nameLabel.text = item.name;
    cell.nameLabel.textColor = selectable ? UIColor.labelColor : UIColor.secondaryLabelColor;
    cell.iconView.image = item.icon ?: [UIImage systemImageNamed:@"app.dashed"];
    cell.iconView.tintColor = UIColor.tertiaryLabelColor;
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    if (item.cacheBytes > 0) [parts addObject:[NSString stringWithFormat:@"%@ cache", cleaner_bytes(item.cacheBytes)]];
    if (item.tempBytes > 0) [parts addObject:[NSString stringWithFormat:@"%@ temp", cleaner_bytes(item.tempBytes)]];
    if (item.active) [parts addObject:@"in use"];
    else if (item.incomplete) [parts addObject:@"partly unreadable"];
    cell.detailLabel.text = [parts componentsJoinedByString:@" · "];
    cell.sizeLabel.text = item.incomplete ? [@"≥ " stringByAppendingString:cleaner_bytes(item.totalBytes)]
                                          : cleaner_bytes(item.totalBytes);
    cell.checkView.image = [UIImage systemImageNamed:item.active ? @"minus.circle"
                                                    : item.selected ? @"checkmark.circle.fill" : @"circle"];
    cell.checkView.tintColor = item.selected ? UIColor.systemBlueColor : UIColor.tertiaryLabelColor;
    cell.selectionStyle = selectable ? UITableViewCellSelectionStyleDefault : UITableViewCellSelectionStyleNone;
    cell.accessibilityTraits = item.selected ? UIAccessibilityTraitSelected : UIAccessibilityTraitNone;
    return cell;
}

- (BOOL)tableView:(UITableView *)tableView shouldHighlightRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (indexPath.section == CYCleanerSectionSummary)
        return !self.accessReady && !self.loading && self.accessMessage != nil;
    return [self itemSelectable:[self itemsInSection:indexPath.section][(NSUInteger)indexPath.row]];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == CYCleanerSectionSummary) {
        if (!self.accessReady && !self.loading) {
            if ([self.accessMessage hasPrefix:@"Needs kernel access"]) [self confirmFullExploit];
            else [self ensureAccessAllowingFullExploit:NO];
        }
        return;
    }
    CYCleanerItem *item = [self itemsInSection:indexPath.section][(NSUInteger)indexPath.row];
    if (![self itemSelectable:item]) return;
    item.selected = !item.selected;
    [tableView reloadRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationNone];
    [self reloadSummary];
    [self updateControls];
}

- (UIContextMenuConfiguration *)tableView:(UITableView *)tableView
    contextMenuConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath point:(CGPoint)point
{
    if (indexPath.section == CYCleanerSectionSummary) return nil;
    CYCleanerItem *item = [self itemsInSection:indexPath.section][(NSUInteger)indexPath.row];
    NSString *caches = [item.container.path stringByAppendingPathComponent:@"Library/Caches"];
    NSString *tmp = [item.container.path stringByAppendingPathComponent:@"tmp"];
    __weak typeof(self) weakSelf = self;
    return [UIContextMenuConfiguration configurationWithIdentifier:nil previewProvider:nil
                                                    actionProvider:^UIMenu *(NSArray<UIMenuElement *> *s) {
        NSMutableArray *actions = [NSMutableArray arrayWithObject:
            [UIAction actionWithTitle:@"Show Caches in File Browser" image:[UIImage systemImageNamed:@"folder"]
                           identifier:nil handler:^(UIAction *a) { [weakSelf openInFileBrowser:caches]; }]];
        if (item.tempBytes > 0)
            [actions addObject:[UIAction actionWithTitle:@"Show tmp in File Browser" image:[UIImage systemImageNamed:@"folder"]
                                              identifier:nil handler:^(UIAction *a) { [weakSelf openInFileBrowser:tmp]; }]];
        return [UIMenu menuWithTitle:item.name children:actions];
    }];
}

@end


@implementation CYCleanerFoldersViewController

- (instancetype)init
{
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (self) self.title = @"Folders to Clean";
    return self;
}

- (NSArray<NSDictionary<NSString *, id> *> *)foldersForItem:(CYCleanerItem *)item
{
    NSMutableArray *out = [NSMutableArray array];
    if (item.cacheBytes > 0) {
        [out addObject:@{ @"title": @"Library/Caches",
                          @"path": [item.container.path stringByAppendingPathComponent:@"Library/Caches"],
                          @"bytes": @(item.cacheBytes) }];
    }
    if (item.tempBytes > 0) {
        [out addObject:@{ @"title": @"tmp",
                          @"path": [item.container.path stringByAppendingPathComponent:@"tmp"],
                          @"bytes": @(item.tempBytes) }];
    }
    return out;
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView
{
    (void)tableView;
    return self.items.count;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    (void)tableView;
    return [self foldersForItem:self.items[section]].count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
    (void)tableView;
    return self.items[section].name;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    NSDictionary *folder = [self foldersForItem:self.items[indexPath.section]][indexPath.row];
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"cleaner-folder"];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                             reuseIdentifier:@"cleaner-folder"];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    cell.textLabel.text = folder[@"path"];
    cell.textLabel.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
    cell.textLabel.numberOfLines = 3;
    cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ · %@",
        folder[@"title"], cleaner_bytes([(NSNumber *)folder[@"bytes"] unsignedLongLongValue])];
    cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    cell.accessoryType = UITableViewCellAccessoryNone;
    return cell;
}

@end
