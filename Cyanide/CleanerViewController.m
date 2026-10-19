//
//  CleanerViewController.m
//  Cyanide
//

#import "CleanerViewController.h"
#import "FBAppContainers.h"
#import "SettingsViewController.h"
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

@interface CleanerViewController ()
@property (nonatomic, copy) NSArray<CYCleanerItem *> *items;
@property (nonatomic) BOOL processListAvailable;
@property (nonatomic) BOOL accessReady;
@property (nonatomic) BOOL loading;
@property (nonatomic) BOOL cleaning;
@property (nonatomic, strong) UIBarButtonItem *selectAllItem;
@property (nonatomic, strong) UIButton *cleanButton;
@property (nonatomic, strong) UILabel *cleanHintLabel;
@property (nonatomic, strong) UIAlertController *progressAlert;
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
    self.tableView.rowHeight = 64.0;
    self.tableView.estimatedRowHeight = 64.0;
    self.tableView.allowsMultipleSelection = NO;
    self.tableView.separatorInset = UIEdgeInsetsMake(0, 60, 0, 0);

    UIRefreshControl *refresh = [[UIRefreshControl alloc] init];
    [refresh addTarget:self action:@selector(refreshPulled:) forControlEvents:UIControlEventValueChanged];
    self.refreshControl = refresh;

    self.selectAllItem = [[UIBarButtonItem alloc] initWithTitle:@"Select All"
                                                          style:UIBarButtonItemStylePlain
                                                         target:self
                                                         action:@selector(toggleSelectAll:)];
    self.navigationItem.rightBarButtonItem = self.selectAllItem;

    [self buildTopBar];
    [self buildFooter];
    [self updateCleanButton];
}

- (void)viewDidAppear:(BOOL)animated
{
    [super viewDidAppear:animated];
    cleaner_suppress_popup_bar(self, YES);
    if (!self.accessReady && !self.loading) [self ensureAccessAndLoad];
}

- (void)viewWillDisappear:(BOOL)animated
{
    [super viewWillDisappear:animated];
    cleaner_suppress_popup_bar(self, NO);
}

- (void)buildTopBar
{
    UIView *header = [[UIView alloc] initWithFrame:CGRectMake(0, 0,
        self.tableView.bounds.size.width, 64)];
    header.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    header.backgroundColor = UIColor.clearColor;

    self.cleanButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.cleanButton.translatesAutoresizingMaskIntoConstraints = NO;
    self.cleanButton.titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
    self.cleanButton.titleLabel.adjustsFontSizeToFitWidth = YES;
    self.cleanButton.titleLabel.minimumScaleFactor = 0.8;
    self.cleanButton.backgroundColor = UIColor.systemBlueColor;
    self.cleanButton.tintColor = UIColor.whiteColor;
    self.cleanButton.layer.cornerRadius = 12.0;
    [self.cleanButton addTarget:self action:@selector(cleanSelected:) forControlEvents:UIControlEventTouchUpInside];
    [header addSubview:self.cleanButton];

    UILayoutGuide *m = header.layoutMarginsGuide;
    [NSLayoutConstraint activateConstraints:@[
        [self.cleanButton.leadingAnchor constraintEqualToAnchor:m.leadingAnchor],
        [self.cleanButton.trailingAnchor constraintEqualToAnchor:m.trailingAnchor],
        [self.cleanButton.topAnchor constraintEqualToAnchor:header.topAnchor constant:8],
        [self.cleanButton.heightAnchor constraintEqualToConstant:44],
    ]];
    self.tableView.tableHeaderView = header;
}

- (void)buildFooter
{
    UIView *footer = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 0, 56)];
    footer.backgroundColor = UIColor.clearColor;

    self.cleanHintLabel = [[UILabel alloc] init];
    self.cleanHintLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.cleanHintLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    self.cleanHintLabel.textColor = UIColor.secondaryLabelColor;
    self.cleanHintLabel.numberOfLines = 0;
    self.cleanHintLabel.text = @"Only Library/Caches and tmp contents are removed. Documents, settings and app data are not touched. Active apps are skipped.";
    [footer addSubview:self.cleanHintLabel];

    UILayoutGuide *m = footer.layoutMarginsGuide;
    [NSLayoutConstraint activateConstraints:@[
        [self.cleanHintLabel.leadingAnchor constraintEqualToAnchor:m.leadingAnchor],
        [self.cleanHintLabel.trailingAnchor constraintEqualToAnchor:m.trailingAnchor],
        [self.cleanHintLabel.topAnchor constraintEqualToAnchor:footer.topAnchor constant:8],
        [self.cleanHintLabel.bottomAnchor constraintEqualToAnchor:footer.bottomAnchor constant:-8],
    ]];
    self.tableView.tableFooterView = footer;
}

- (void)ensureAccessAndLoad
{
    if (self.loading) return;
    if (settings_filesystem_access_available()) {
        self.accessReady = YES;
        [self reloadData];
        return;
    }

    self.loading = YES;
    [self updateCleanButton];
    __weak typeof(self) weakSelf = self;
    settings_unlock_filesystem_async(NO, ^(BOOL ok, NSString *message) {
        typeof(self) self = weakSelf;
        if (!self) return;
        self.loading = NO;
        if (!ok) {
            [self updateCleanButton];
            UIAlertController *alert = [UIAlertController
                alertControllerWithTitle:@"Filesystem Access Needed"
                                 message:message ?: @"Run the kernel chain once, then reopen Cleaner."
                          preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
            [self presentViewController:alert animated:YES completion:nil];
            return;
        }
        self.accessReady = YES;
        [self reloadData];
    });
}

- (void)refreshPulled:(UIRefreshControl *)sender
{
    (void)sender;
    if (self.loading || self.cleaning) {
        [self.refreshControl endRefreshing];
        return;
    }
    [self reloadData];
}

- (void)reloadData
{
    if (self.loading || self.cleaning) return;
    if (!self.accessReady || !settings_filesystem_access_available()) {
        [self ensureAccessAndLoad];
        return;
    }

    self.loading = YES;
    [self updateCleanButton];
    [self.refreshControl beginRefreshing];
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        @autoreleasepool {
            // Keep the scan independent of the File Browser's cached metadata.
            fb_containers_reset();
            NSArray<FBAppContainer *> *containers = fb_app_data_containers();
            NSSet<NSString *> *active = settings_active_process_names();
            BOOL processListAvailable = (active != nil);
            if (!active) active = [NSSet set];

            NSMutableArray<CYCleanerItem *> *items = [NSMutableArray array];
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
                // Apps with nothing reclaimable are noise in this screen.
                if (item.totalBytes == 0) continue;
                item.selected = processListAvailable && !item.active && !item.systemApp;
                [items addObject:item];
            }

            [items sortUsingComparator:^NSComparisonResult(CYCleanerItem *a, CYCleanerItem *b) {
                if (a.systemApp != b.systemApp) return a.systemApp ? NSOrderedDescending : NSOrderedAscending;
                return [a.name caseInsensitiveCompare:b.name];
            }];

            dispatch_async(dispatch_get_main_queue(), ^{
                typeof(self) self = weakSelf;
                if (!self) return;
                self.items = items;
                self.processListAvailable = processListAvailable;
                self.loading = NO;
                [self.refreshControl endRefreshing];
                [self.tableView reloadData];
                [self updateCleanButton];
            });
        }
    });
}

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
    [self updateCleanButton];
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

- (void)updateCleanButton
{
    NSUInteger count = [self selectedCount];
    unsigned long long bytes = [self selectedBytes];
    BOOL enabled = !self.loading && !self.cleaning && self.accessReady &&
                   self.processListAvailable && count > 0;
    self.cleanButton.enabled = enabled;
    self.cleanButton.alpha = enabled ? 1.0 : 0.5;
    NSString *title = count > 0
        ? [NSString stringWithFormat:@"Clean Selected · %@", cleaner_bytes(bytes)]
        : @"Clean Selected";
    [self.cleanButton setTitle:title forState:UIControlStateNormal];
    self.selectAllItem.enabled = !self.loading && !self.cleaning &&
                                 self.processListAvailable && self.items.count > 0;
    NSUInteger selectable = 0, selectedSelectable = 0;
    for (CYCleanerItem *item in self.items) {
        if (item.active || item.systemApp || item.totalBytes == 0) continue;
        selectable++;
        if (item.selected) selectedSelectable++;
    }
    self.selectAllItem.title = (selectable > 0 && selectedSelectable == selectable)
        ? @"Deselect All" : @"Select All";
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
        @"Remove Library/Caches and tmp contents for %lu app%@? Documents, settings and app data are not touched. Apps may need to redownload content.",
        (unsigned long)count, count == 1 ? @"" : @"s"];
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
    [self updateCleanButton];

    UIAlertController *progress = [UIAlertController alertControllerWithTitle:@"Cleaning…"
                                                                      message:@"Removing cache and temporary files."
                                                               preferredStyle:UIAlertControllerStyleAlert];
    UIActivityIndicatorView *spinner = [[UIActivityIndicatorView alloc]
        initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    spinner.translatesAutoresizingMaskIntoConstraints = NO;
    [spinner startAnimating];
    [progress.view addSubview:spinner];
    [NSLayoutConstraint activateConstraints:@[
        [spinner.centerXAnchor constraintEqualToAnchor:progress.view.centerXAnchor],
        [spinner.bottomAnchor constraintEqualToAnchor:progress.view.bottomAnchor constant:-20],
    ]];
    self.progressAlert = progress;
    [self presentViewController:progress animated:YES completion:nil];

    __block UIBackgroundTaskIdentifier bgTask =
        [UIApplication.sharedApplication beginBackgroundTaskWithName:@"cyanide.cleaner" expirationHandler:^{}];

    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        @autoreleasepool {
            NSSet<NSString *> *active = settings_active_process_names();
            NSUInteger cleanedApps = 0, skippedActive = 0, failedApps = 0;
            unsigned long long freed = 0;

            if (active) {
                for (CYCleanerItem *item in self.items) {
                    if (!item.selected) continue;
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
                if (!self) return;
                if (bgTask != UIBackgroundTaskInvalid) {
                    [UIApplication.sharedApplication endBackgroundTask:bgTask];
                    bgTask = UIBackgroundTaskInvalid;
                }
                self.cleaning = NO;
                [self.progressAlert dismissViewControllerAnimated:YES completion:nil];
                self.progressAlert = nil;
                [self.tableView reloadData];
                [self updateCleanButton];

                if (!active) {
                    UIAlertController *alert = [UIAlertController
                        alertControllerWithTitle:@"Cleaner Stopped"
                                         message:@"The active-process list was unavailable, so nothing was removed."
                                  preferredStyle:UIAlertControllerStyleAlert];
                    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
                    [self presentViewController:alert animated:YES completion:nil];
                    return;
                }

                NSMutableString *result = [NSMutableString stringWithFormat:
                    @"Freed %@ from %lu app%@.", cleaner_bytes(freed),
                    (unsigned long)cleanedApps, cleanedApps == 1 ? @"" : @"s"];
                if (skippedActive > 0)
                    [result appendFormat:@" Skipped %lu active app%@.", (unsigned long)skippedActive,
                     skippedActive == 1 ? @"" : @"s"];
                if (failedApps > 0)
                    [result appendFormat:@" Some files in %lu app%@ could not be removed.",
                     (unsigned long)failedApps, failedApps == 1 ? @"" : @"s"];
                UIAlertController *alert = [UIAlertController
                    alertControllerWithTitle:@"Cleanup Complete"
                                     message:result
                              preferredStyle:UIAlertControllerStyleAlert];
                [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
                [self presentViewController:alert animated:YES completion:nil];
            });
        }
    });
}

#pragma mark - Table data

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView
{
    (void)tableView;
    return 2;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    (void)tableView;
    if (section == 0) return 1;
    if (self.items.count == 0) return 1;
    return self.items.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
    (void)tableView;
    if (section != 1 || self.items.count == 0) return nil;
    return [NSString stringWithFormat:@"Apps (%lu)", (unsigned long)self.items.count];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (indexPath.section == 0) {
        UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"cleaner-summary"];
        if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                                 reuseIdentifier:@"cleaner-summary"];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        cell.textLabel.text = @"Reclaimable";
        cell.textLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
        cell.detailTextLabel.numberOfLines = 0;
        if (self.loading) {
            cell.detailTextLabel.text = @"Scanning app caches…";
        } else if (!self.accessReady) {
            cell.detailTextLabel.text = @"Filesystem access is not available.";
        } else {
            NSUInteger selected = [self selectedCount];
            unsigned long long selectedBytes = [self selectedBytes];
            unsigned long long total = 0;
            for (CYCleanerItem *item in self.items) total += item.totalBytes;
            NSString *detail = nil;
            if (selected > 0) {
                detail = [NSString stringWithFormat:@"%@ across %lu selected app%@.",
                          cleaner_bytes(selectedBytes), (unsigned long)selected,
                          selected == 1 ? @"" : @"s"];
                if (total != selectedBytes) {
                    detail = [detail stringByAppendingFormat:@" %@ total across %lu app%@.",
                              cleaner_bytes(total), (unsigned long)self.items.count,
                              self.items.count == 1 ? @"" : @"s"];
                }
            } else {
                detail = [NSString stringWithFormat:@"%@ total across %lu app%@. Select apps below.",
                          cleaner_bytes(total), (unsigned long)self.items.count,
                          self.items.count == 1 ? @"" : @"s"];
            }
            if (!self.processListAvailable)
                detail = [detail stringByAppendingString:@" Kernel access is unavailable, so active-app protection is off."];
            cell.detailTextLabel.text = detail;
        }
        return cell;
    }

    if (self.items.count == 0) {
        UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"cleaner-empty"];
        if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                                 reuseIdentifier:@"cleaner-empty"];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        cell.textLabel.text = self.loading ? @"Scanning…" : @"No app caches found";
        cell.detailTextLabel.text = self.loading ? nil : @"Pull to refresh after opening the File Browser once.";
        cell.accessoryType = UITableViewCellAccessoryNone;
        return cell;
    }

    CYCleanerItem *item = self.items[indexPath.row];
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"cleaner-app"];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                             reuseIdentifier:@"cleaner-app"];
    cell.textLabel.text = item.name;
    cell.textLabel.textColor = item.active ? UIColor.secondaryLabelColor : UIColor.labelColor;
    cell.detailTextLabel.numberOfLines = 2;
    cell.imageView.image = item.icon;

    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    if (item.cacheBytes > 0)
        [parts addObject:[NSString stringWithFormat:@"%@ cache", cleaner_bytes(item.cacheBytes)]];
    if (item.tempBytes > 0)
        [parts addObject:[NSString stringWithFormat:@"%@ temp", cleaner_bytes(item.tempBytes)]];
    if (parts.count == 0) [parts addObject:@"No cache data"];
    if (item.incomplete) [parts addObject:@"≥"];
    NSString *detail = [parts componentsJoinedByString:@" · "];
    if (item.active) detail = [detail stringByAppendingString:@" · Active — skipped"];
    else if (item.systemApp) detail = [detail stringByAppendingString:@" · System"];
    cell.detailTextLabel.text = detail;
    cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    cell.selectionStyle = (item.active || item.totalBytes == 0 || !self.processListAvailable)
        ? UITableViewCellSelectionStyleNone : UITableViewCellSelectionStyleDefault;
    cell.accessoryType = item.selected ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    cell.accessoryView = nil;
    return cell;
}

- (BOOL)tableView:(UITableView *)tableView shouldHighlightRowAtIndexPath:(NSIndexPath *)indexPath
{
    (void)tableView;
    if (indexPath.section != 1 || self.items.count == 0) return NO;
    CYCleanerItem *item = self.items[indexPath.row];
    return !item.active && item.totalBytes > 0 && self.processListAvailable &&
           !self.loading && !self.cleaning;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section != 1 || self.items.count == 0) return;
    if (![self tableView:tableView shouldHighlightRowAtIndexPath:indexPath]) return;
    CYCleanerItem *item = self.items[indexPath.row];
    item.selected = !item.selected;
    [tableView reloadRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationNone];
    [self updateCleanButton];
}

@end
