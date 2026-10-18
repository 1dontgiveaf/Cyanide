//
//  SystemInfoViewController.m
//  Cyanide
//

#import "SystemInfoViewController.h"
#import "SettingsViewController.h"
#import <fts.h>
#import <sys/mount.h>
#import <sys/stat.h>
#import <sys/sysctl.h>

typedef NS_ENUM(NSInteger, SISection) {
    SISectionDevice,
    SISectionKernel,
    SISectionBattery,
    SISectionStorage,
    SISectionApps,
    SISectionCount,
};

// One installed app: bundle and data container sizes in bytes.
@interface SIApp : NSObject
@property (nonatomic, copy) NSString *bundleID;
@property (nonatomic, copy) NSString *name;
@property (nonatomic) unsigned long long appBytes;
@property (nonatomic) unsigned long long dataBytes;
@property (nonatomic, strong) UIImage *icon;
@property (nonatomic) BOOL incomplete;   // a size couldn't be read fully: at least this much
@end
@implementation SIApp
@end

static NSString *si_string_sysctl(const char *name)
{
    char buf[256] = {0};
    size_t len = sizeof(buf) - 1;
    if (sysctlbyname(name, buf, &len, NULL, 0) != 0) return nil;
    return [NSString stringWithUTF8String:buf];
}

static NSString *si_bytes(unsigned long long bytes)
{
    return [NSByteCountFormatter stringFromByteCount:(long long)bytes countStyle:NSByteCountFormatterCountStyleFile];
}

static NSString *si_duration(NSTimeInterval t)
{
    long s = (long)t;
    long d = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60;
    if (d > 0) return [NSString stringWithFormat:@"%ldd %ldh %ldm", d, h, m];
    if (h > 0) return [NSString stringWithFormat:@"%ldh %ldm", h, m];
    return [NSString stringWithFormat:@"%ldm", m];
}

// Allocated size of a directory tree (hard links counted once). *complete
// is cleared when part of it couldn't be read: the size is then a minimum.
static unsigned long long si_tree_bytes(NSString *path, BOOL *complete)
{
    char *paths[] = { (char *)path.fileSystemRepresentation, NULL };
    FTS *fts = fts_open(paths, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, NULL);
    if (!fts) { *complete = NO; return 0; }
    unsigned long long total = 0;
    NSMutableSet<NSString *> *links = [NSMutableSet set];
    FTSENT *e;
    while ((e = fts_read(fts))) {
        if (e->fts_info == FTS_DNR || e->fts_info == FTS_ERR || e->fts_info == FTS_NS) { *complete = NO; continue; }
        if (e->fts_info == FTS_DP || !e->fts_statp) continue;
        struct stat *st = e->fts_statp;
        if (!S_ISDIR(st->st_mode) && st->st_nlink > 1) {
            NSString *key = [NSString stringWithFormat:@"%d:%llu", st->st_dev, (unsigned long long)st->st_ino];
            if ([links containsObject:key]) continue;
            [links addObject:key];
        }
        total += (unsigned long long)st->st_blocks * 512;
    }
    fts_close(fts);
    return total;
}

// The app's home screen icon at row size: the largest AppIcon PNG in the
// bundle (most apps still ship them next to the asset catalog), else what
// iOS hands out for the bundle ID (may be a generic icon in the sandbox).
static UIImage *si_app_icon(NSString *appDir, NSDictionary *info, NSString *bundleID)
{
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    // Any level can be malformed in a third-party Info.plist: check each type.
    NSDictionary *icons = [info[@"CFBundleIcons"] isKindOfClass:NSDictionary.class] ? info[@"CFBundleIcons"] : nil;
    NSDictionary *primary = [icons[@"CFBundlePrimaryIcon"] isKindOfClass:NSDictionary.class] ? icons[@"CFBundlePrimaryIcon"] : nil;
    NSArray *files = primary[@"CFBundleIconFiles"];
    if ([files isKindOfClass:NSArray.class]) [names addObjectsFromArray:files];
    NSString *iconName = primary[@"CFBundleIconName"];
    if ([iconName isKindOfClass:NSString.class]) [names addObject:iconName];
    UIImage *best = nil;
    for (NSString *file in [NSFileManager.defaultManager contentsOfDirectoryAtPath:appDir error:nil]) {
        if (![file.pathExtension.lowercaseString isEqualToString:@"png"]) continue;
        BOOL match = [file hasPrefix:@"AppIcon"] || [file hasPrefix:@"Icon"];
        for (NSString *n in names) if ([n isKindOfClass:NSString.class] && [file hasPrefix:n]) match = YES;
        if (!match) continue;
        UIImage *img = [UIImage imageWithContentsOfFile:[appDir stringByAppendingPathComponent:file]];
        if (img && img.size.width * img.scale > best.size.width * best.scale) best = img;
    }
    if (!best) {
        SEL sel = NSSelectorFromString(@"_applicationIconImageForBundleIdentifier:format:scale:");
        if ([UIImage respondsToSelector:sel]) {
            UIImage *(*fn)(id, SEL, NSString *, int, CGFloat) = (void *)[UIImage methodForSelector:sel];
            best = fn(UIImage.class, sel, bundleID, 2 /* home screen size */, UIScreen.mainScreen.scale);
        }
    }
    if (!best) return nil;
    // Pre-render small and rounded, off the main thread.
    CGFloat side = 36;
    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(side, side)];
    return [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(0, 0, side, side) cornerRadius:side * 0.225] addClip];
        [best drawInRect:CGRectMake(0, 0, side, side)];
    }];
}

static NSString *si_container_identifier(NSString *container)
{
    NSDictionary *meta = [NSDictionary dictionaryWithContentsOfFile:
        [container stringByAppendingPathComponent:@".com.apple.mobile_container_manager.metadata.plist"]];
    NSString *bid = meta[@"MCMMetadataIdentifier"];
    return [bid isKindOfClass:NSString.class] ? bid : nil;
}

// Installed (non-system) apps with the size of their bundle and data
// containers. Needs filesystem access outside the sandbox.
static NSArray<SIApp *> *si_scan_apps(void)
{
    NSFileManager *fm = NSFileManager.defaultManager;
    NSMutableDictionary<NSString *, SIApp *> *apps = [NSMutableDictionary dictionary];
    NSString *bundles = @"/var/containers/Bundle/Application";
    for (NSString *uuid in [fm contentsOfDirectoryAtPath:bundles error:nil]) {
        NSString *container = [bundles stringByAppendingPathComponent:uuid];
        NSString *bid = si_container_identifier(container);
        NSString *appDir = nil;
        for (NSString *item in [fm contentsOfDirectoryAtPath:container error:nil])
            if ([item.pathExtension isEqualToString:@"app"]) { appDir = [container stringByAppendingPathComponent:item]; break; }
        NSDictionary *info = appDir ? [NSDictionary dictionaryWithContentsOfFile:[appDir stringByAppendingPathComponent:@"Info.plist"]] : nil;
        if (!bid) bid = info[@"CFBundleIdentifier"];
        if (![bid isKindOfClass:NSString.class]) continue;
        SIApp *app = apps[bid] ?: [SIApp new];
        app.bundleID = bid;
        NSString *name = info[@"CFBundleDisplayName"] ?: info[@"CFBundleName"];
        app.name = [name isKindOfClass:NSString.class] && name.length ? name : (appDir.lastPathComponent.stringByDeletingPathExtension ?: bid);
        BOOL complete = YES;
        app.appBytes = si_tree_bytes(container, &complete);
        if (!complete) app.incomplete = YES;
        if (appDir) app.icon = si_app_icon(appDir, info, bid);
        apps[bid] = app;
    }
    NSString *data = @"/var/mobile/Containers/Data/Application";
    for (NSString *uuid in [fm contentsOfDirectoryAtPath:data error:nil]) {
        NSString *container = [data stringByAppendingPathComponent:uuid];
        SIApp *app = apps[si_container_identifier(container) ?: @""];
        if (!app) continue;   // system apps' data, or metadata that couldn't be read
        BOOL complete = YES;
        app.dataBytes += si_tree_bytes(container, &complete);
        if (!complete) app.incomplete = YES;
    }
    return [apps.allValues sortedArrayUsingComparator:^NSComparisonResult(SIApp *a, SIApp *b) {
        unsigned long long ta = a.appBytes + a.dataBytes, tb = b.appBytes + b.dataBytes;
        return ta > tb ? NSOrderedAscending : ta < tb ? NSOrderedDescending : NSOrderedSame;
    }];
}

@interface SystemInfoViewController ()
@property (nonatomic, copy) NSArray<NSArray<NSString *> *> *deviceRows;     // @[title, value]
@property (nonatomic, copy) NSArray<NSArray<NSString *> *> *kernelRows;
@property (nonatomic, copy) NSArray<NSArray<NSString *> *> *batteryRows;
@property (nonatomic, copy) NSString *batteryStatus;
@property (nonatomic, copy) NSArray<NSArray<NSString *> *> *storageRows;
@property (nonatomic, copy) NSArray<SIApp *> *apps;
@property (nonatomic, copy) NSString *appsStatus;
@property (nonatomic) BOOL readingBattery;
@property (nonatomic) BOOL scanningApps;
@property (nonatomic) NSInteger appSort;   // SIAppSort
@end

typedef NS_ENUM(NSInteger, SIAppSort) { SIAppSortTotal, SIAppSortApp, SIAppSortData, SIAppSortName };
static NSString * const kSIAppSortKey = @"SystemInfoAppSort";

@implementation SystemInfoViewController

- (instancetype)init
{
    return [super initWithStyle:UITableViewStyleInsetGrouped];
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.title = @"System Info";
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeAlways;
    self.refreshControl = [UIRefreshControl new];
    [self.refreshControl addTarget:self action:@selector(pullToRefresh) forControlEvents:UIControlEventValueChanged];
    self.appsStatus = @"Tap to calculate";
    self.appSort = [NSUserDefaults.standardUserDefaults integerForKey:kSIAppSortKey];
    [self updateSortMenu];
    [self refreshLocal];
    [self readBatteryAllowingFullExploit:NO];
}

- (void)pullToRefresh
{
    [self.refreshControl endRefreshing];
    [self refreshLocal];
    [self readBatteryAllowingFullExploit:NO];
    if (self.apps.count) [self scanAppsAllowingFullExploit:NO];   // only once calculated
}

#pragma mark Sorting

- (void)updateSortMenu
{
    NSArray *titles = @[ @"Total Size", @"App Size", @"Data Size", @"Name" ];
    NSMutableArray *actions = [NSMutableArray array];
    __weak typeof(self) weakSelf = self;
    for (NSInteger i = 0; i < (NSInteger)titles.count; i++) {
        UIAction *a = [UIAction actionWithTitle:titles[(NSUInteger)i] image:nil identifier:nil handler:^(UIAction *x) {
            typeof(self) me = weakSelf;
            me.appSort = i;
            [NSUserDefaults.standardUserDefaults setInteger:i forKey:kSIAppSortKey];
            me.apps = [me sortedApps:me.apps];
            [me updateSortMenu];
            [me.tableView reloadSections:[NSIndexSet indexSetWithIndex:SISectionApps]
                        withRowAnimation:UITableViewRowAnimationAutomatic];
        }];
        a.state = i == self.appSort ? UIMenuElementStateOn : UIMenuElementStateOff;
        [actions addObject:a];
    }
    UIBarButtonItem *item = [[UIBarButtonItem alloc]
        initWithImage:[UIImage systemImageNamed:@"arrow.up.arrow.down"]
                 menu:[UIMenu menuWithTitle:@"Sort Apps By" children:actions]];
    item.enabled = self.apps.count > 0;
    self.navigationItem.rightBarButtonItem = item;
}

- (NSArray<SIApp *> *)sortedApps:(NSArray<SIApp *> *)apps
{
    SIAppSort sort = (SIAppSort)self.appSort;
    return [apps sortedArrayUsingComparator:^NSComparisonResult(SIApp *a, SIApp *b) {
        if (sort == SIAppSortName) return [a.name localizedCaseInsensitiveCompare:b.name];
        unsigned long long va = sort == SIAppSortApp ? a.appBytes : sort == SIAppSortData ? a.dataBytes : a.appBytes + a.dataBytes;
        unsigned long long vb = sort == SIAppSortApp ? b.appBytes : sort == SIAppSortData ? b.dataBytes : b.appBytes + b.dataBytes;
        if (va != vb) return va > vb ? NSOrderedAscending : NSOrderedDescending;   // largest first
        return [a.name localizedCaseInsensitiveCompare:b.name];
    }];
}

#pragma mark Data

- (void)refreshLocal
{
    struct timeval boot = {0};
    size_t len = sizeof(boot);
    NSString *uptime = @"—", *booted = @"—";
    if (sysctlbyname("kern.boottime", &boot, &len, NULL, 0) == 0 && boot.tv_sec > 0) {
        NSDate *bootDate = [NSDate dateWithTimeIntervalSince1970:boot.tv_sec];
        uptime = si_duration(-bootDate.timeIntervalSinceNow);
        booted = [NSDateFormatter localizedStringFromDate:bootDate dateStyle:NSDateFormatterMediumStyle
                                                timeStyle:NSDateFormatterShortStyle];
    }
    UIDevice *dev = UIDevice.currentDevice;
    self.deviceRows = @[
        @[ @"Model", si_string_sysctl("hw.machine") ?: dev.model ],
        @[ dev.systemName ?: @"iOS", [NSString stringWithFormat:@"%@ (%@)", dev.systemVersion,
                                       si_string_sysctl("kern.osversion") ?: @"?"] ],
        @[ @"Uptime", uptime ],
        @[ @"Last restart", booted ],
    ];

    NSDictionary *k = settings_kernel_access_status();
    self.kernelRows = @[
        @[ @"State", k[@"state"] ],
        @[ @"SpringBoard session", [k[@"springboard"] boolValue] ? @"Open" : @"Closed" ],
        @[ @"", k[@"detail"] ],
    ];

    struct statfs fs;
    if (statfs("/private/var", &fs) == 0) {
        unsigned long long total = (unsigned long long)fs.f_blocks * fs.f_bsize;
        unsigned long long avail = (unsigned long long)fs.f_bavail * fs.f_bsize;
        self.storageRows = @[
            @[ @"Capacity", si_bytes(total) ],
            @[ @"Used", si_bytes(total - avail) ],
            @[ @"Available", si_bytes(avail) ],
        ];
    } else {
        self.storageRows = @[ @[ @"Storage", @"Unavailable" ] ];
    }
    [self.tableView reloadData];
}

// Battery values as iOS reports them in AppleSmartBattery. Capacities are
// mAh, Temperature is in hundredths of °C, Voltage in mV.
- (void)applyBattery:(NSDictionary *)b source:(NSString *)source
{
    NSMutableArray *rows = [NSMutableArray array];
    NSNumber *(^num)(NSString *) = ^NSNumber *(NSString *key) {
        id v = b[key] ?: b[@"BatteryData"][key];
        return [v isKindOfClass:NSNumber.class] ? v : nil;
    };
    NSNumber *cycles = num(@"CycleCount");
    if (cycles != nil) [rows addObject:@[ @"Cycle count", cycles.stringValue ]];
    NSNumber *design = num(@"DesignCapacity");
    NSNumber *full = num(@"NominalChargeCapacity") ?: num(@"AppleRawMaxCapacity");
    NSNumber *applePct = num(@"MaximumCapacityPercent");
    if (applePct != nil) [rows addObject:@[ @"Maximum capacity", [NSString stringWithFormat:@"%@%%", applePct] ]];
    if (design.doubleValue > 0 && full != nil) {
        [rows addObject:@[ applePct != nil ? @"Measured capacity" : @"Maximum capacity",
                           [NSString stringWithFormat:@"%.1f%% (%@ of %@ mAh)",
                            100.0 * full.doubleValue / design.doubleValue, full, design] ]];
    }
    NSNumber *charge = num(@"CurrentCapacity");
    if (charge != nil) [rows addObject:@[ @"Charge", [NSString stringWithFormat:@"%@%%", charge] ]];
    NSNumber *temp = num(@"Temperature");
    if (temp != nil) [rows addObject:@[ @"Temperature", [NSString stringWithFormat:@"%.1f °C", temp.doubleValue / 100.0] ]];
    NSNumber *voltage = num(@"Voltage");
    if (voltage != nil) [rows addObject:@[ @"Voltage", [NSString stringWithFormat:@"%.2f V", voltage.doubleValue / 1000.0] ]];
    NSNumber *amps = num(@"InstantAmperage") ?: num(@"Amperage");
    if (amps != nil) [rows addObject:@[ @"Current", [NSString stringWithFormat:@"%d mA", amps.intValue] ]];
    NSNumber *charging = num(@"IsCharging"), *external = num(@"ExternalConnected");
    if (charging != nil || external != nil)
        [rows addObject:@[ @"Power", charging.boolValue ? @"Charging" : external.boolValue ? @"Connected, not charging" : @"On battery" ]];
    self.batteryRows = rows;
    self.batteryStatus = rows.count ? [NSString stringWithFormat:@"Read from AppleSmartBattery in %@.", source]
                                    : @"The battery driver returned no values.";
}

- (void)readBatteryAllowingFullExploit:(BOOL)allowFullExploit
{
    if (self.readingBattery) return;
    self.readingBattery = YES;
    if (!self.batteryRows.count) self.batteryStatus = @"Reading…";
    [self.tableView reloadData];
    __weak typeof(self) weakSelf = self;
    settings_battery_info_async(allowFullExploit, ^(NSDictionary *battery, NSString *source, NSString *message) {
        typeof(self) me = weakSelf;
        if (!me) return;
        me.readingBattery = NO;
        if (battery) {
            [me applyBattery:battery source:source];
        } else {
            me.batteryRows = nil;   // never show an old reading as current
            me.batteryStatus = [message isEqualToString:kSettingsFullExploitRequiredMessage]
                ? @"Needs kernel access, and there is no saved session. Tap to run the full exploit."
                : (message ?: @"Unavailable.");
        }
        [me refreshLocal];   // kernel state may have changed too
    });
}

- (void)scanAppsAllowingFullExploit:(BOOL)allowFullExploit
{
    if (self.scanningApps) return;
    self.scanningApps = YES;
    self.appsStatus = @"Calculating… this can take a moment";
    [self.tableView reloadData];
    __weak typeof(self) weakSelf = self;
    void (^scan)(void) = ^{
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            NSArray *apps = si_scan_apps();
            dispatch_async(dispatch_get_main_queue(), ^{
                typeof(self) me = weakSelf;
                if (!me) return;
                me.scanningApps = NO;
                me.apps = [me sortedApps:apps];
                me.appsStatus = apps.count ? nil : @"No apps could be read. Tap to try again.";
                [me updateSortMenu];
                [me.tableView reloadData];
            });
        });
    };
    if (settings_filesystem_access_available()) { scan(); return; }
    settings_unlock_filesystem_async(allowFullExploit, ^(BOOL ok, NSString *message) {
        typeof(self) me = weakSelf;
        if (!me) return;
        if (ok) { scan(); return; }
        me.scanningApps = NO;
        me.appsStatus = [message isEqualToString:kSettingsFullExploitRequiredMessage]
            ? @"Needs kernel access, and there is no saved session. Tap to run the full exploit."
            : (message ?: @"Filesystem access is not available.");
        [me.tableView reloadData];
    });
}

- (void)confirmFullExploitThen:(void (^)(void))run
{
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"No parked kernel state"
        message:@"This needs kernel access, and there is no saved session to reuse. Running the full exploit can reboot the device on A18/M4. Continue?"
        preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [ac addAction:[UIAlertAction actionWithTitle:@"Run Full Exploit" style:UIAlertActionStyleDefault
                                         handler:^(UIAlertAction *a) { run(); }]];
    [self presentViewController:ac animated:YES completion:nil];
}

#pragma mark Table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView
{
    return SISectionCount;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
    switch ((SISection)section) {
        case SISectionDevice:  return @"Device";
        case SISectionKernel:  return @"Kernel Access";
        case SISectionBattery: return @"Battery";
        case SISectionStorage: return @"Storage";
        case SISectionApps:    return self.apps.count ? [NSString stringWithFormat:@"%lu Apps", (unsigned long)self.apps.count] : @"Apps";
        default: return nil;
    }
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section
{
    if (section == SISectionBattery) return self.batteryStatus;
    if (section == SISectionApps)
        return @"Installed apps only, app bundle plus data container. Shared App Group data and system apps are not "
               @"included, so iOS Settings can show larger numbers. “≥” marks an app whose folders couldn't all be read. "
               @"Pull down to recalculate.";
    return nil;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    switch ((SISection)section) {
        case SISectionDevice:  return (NSInteger)self.deviceRows.count;
        case SISectionKernel:  return (NSInteger)self.kernelRows.count;
        case SISectionBattery: return (NSInteger)self.batteryRows.count + (self.batteryRows.count ? 0 : 1);
        case SISectionStorage: return (NSInteger)self.storageRows.count;
        case SISectionApps:    return (NSInteger)self.apps.count + (self.appsStatus ? 1 : 0);
        default: return 0;
    }
}

- (UITableViewCell *)valueCell:(NSArray<NSString *> *)row
{
    UITableViewCell *cell = [self.tableView dequeueReusableCellWithIdentifier:@"value"];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:@"value"];
    UIListContentConfiguration *c = [UIListContentConfiguration valueCellConfiguration];
    if (row[0].length) {
        c.text = row[0];
        c.secondaryText = row[1];
    } else {
        c.text = row[1];   // a full-width note
        c.textProperties.color = UIColor.secondaryLabelColor;
        c.textProperties.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    }
    c.textProperties.numberOfLines = 0;
    cell.contentConfiguration = c;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    cell.accessoryType = UITableViewCellAccessoryNone;
    return cell;
}

- (UITableViewCell *)actionCell:(NSString *)text busy:(BOOL)busy
{
    UITableViewCell *cell = [self.tableView dequeueReusableCellWithIdentifier:@"action"];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"action"];
    UIListContentConfiguration *c = cell.defaultContentConfiguration;
    c.text = text;
    c.textProperties.color = busy ? UIColor.secondaryLabelColor : self.view.tintColor;
    c.textProperties.numberOfLines = 0;
    cell.contentConfiguration = c;
    if (busy) {
        UIActivityIndicatorView *spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
        [spinner startAnimating];
        cell.accessoryView = spinner;
    } else {
        cell.accessoryView = nil;
    }
    cell.selectionStyle = busy ? UITableViewCellSelectionStyleNone : UITableViewCellSelectionStyleDefault;
    return cell;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    NSUInteger row = (NSUInteger)indexPath.row;
    switch ((SISection)indexPath.section) {
        case SISectionDevice:  return [self valueCell:self.deviceRows[row]];
        case SISectionKernel:  return [self valueCell:self.kernelRows[row]];
        case SISectionStorage: return [self valueCell:self.storageRows[row]];
        case SISectionBattery:
            if (self.batteryRows.count) return [self valueCell:self.batteryRows[row]];
            return [self actionCell:self.readingBattery ? @"Reading battery…" : @"Read Battery Info" busy:self.readingBattery];
        case SISectionApps: {
            if (self.appsStatus && row == 0) return [self actionCell:self.appsStatus busy:self.scanningApps];
            SIApp *app = self.apps[row - (self.appsStatus ? 1 : 0)];
            UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"app"];
            if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"app"];
            UIListContentConfiguration *c = [UIListContentConfiguration subtitleCellConfiguration];
            c.image = app.icon ?: [UIImage systemImageNamed:@"app.dashed"];
            c.imageProperties.maximumSize = CGSizeMake(36, 36);
            c.imageProperties.reservedLayoutSize = CGSizeMake(36, 36);
            c.imageProperties.tintColor = UIColor.tertiaryLabelColor;
            c.text = app.name;
            c.textProperties.numberOfLines = 1;
            c.secondaryText = [NSString stringWithFormat:@"App %@ · Data %@%@", si_bytes(app.appBytes), si_bytes(app.dataBytes),
                               app.incomplete ? @" · partly unreadable" : @""];
            c.secondaryTextProperties.color = UIColor.secondaryLabelColor;
            c.secondaryTextProperties.numberOfLines = 1;
            cell.contentConfiguration = c;
            // The sorted-by value, right-aligned in its own column.
            SIAppSort sort = (SIAppSort)self.appSort;
            unsigned long long shown = sort == SIAppSortApp ? app.appBytes
                                     : sort == SIAppSortData ? app.dataBytes : app.appBytes + app.dataBytes;
            UILabel *total = [UILabel new];
            total.text = app.incomplete ? [@"≥ " stringByAppendingString:si_bytes(shown)] : si_bytes(shown);
            total.font = [UIFont monospacedDigitSystemFontOfSize:15 weight:UIFontWeightSemibold];
            total.textColor = UIColor.labelColor;
            total.textAlignment = NSTextAlignmentRight;
            [total sizeToFit];
            total.frame = CGRectMake(0, 0, MAX(78, total.bounds.size.width), total.bounds.size.height);
            cell.accessoryView = total;
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            return cell;
        }
        default: return [self valueCell:@[ @"", @"" ]];
    }
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    __weak typeof(self) weakSelf = self;
    if (indexPath.section == SISectionBattery && !self.batteryRows.count && !self.readingBattery) {
        if ([self.batteryStatus hasPrefix:@"Needs kernel access"])
            [self confirmFullExploitThen:^{ [weakSelf readBatteryAllowingFullExploit:YES]; }];
        else
            [self readBatteryAllowingFullExploit:NO];
    } else if (indexPath.section == SISectionApps && self.appsStatus && indexPath.row == 0 && !self.scanningApps) {
        if ([self.appsStatus hasPrefix:@"Needs kernel access"])
            [self confirmFullExploitThen:^{ [weakSelf scanAppsAllowingFullExploit:YES]; }];
        else
            [self scanAppsAllowingFullExploit:NO];
    }
}

@end
