//
//  DaemonsViewController.m
//  Cyanide
//

#import "DaemonsViewController.h"
#import "SettingsViewController.h"
#import "tweaks/daemon_catalog.h"
#import "kexploit/persistence.h"

// Boot session in which the last change was saved: until the next restart
// the screen reminds the user that changes are pending.
static NSString * const kDaemonsChangedBootKey = @"DaemonsChangedBootUUID";

static BOOL daemons_restart_pending(void)
{
    NSString *saved = [NSUserDefaults.standardUserDefaults stringForKey:kDaemonsChangedBootKey];
    NSString *boot = krw_persistence_current_boot_uuid();
    return saved.length && boot.length && [saved isEqualToString:boot];
}

static void daemons_note_change(void)
{
    NSString *boot = krw_persistence_current_boot_uuid();
    if (boot.length) [NSUserDefaults.standardUserDefaults setObject:boot forKey:kDaemonsChangedBootKey];
}

@class DaemonGroupViewController;

@interface DaemonsViewController ()
@property (nonatomic, copy) NSDictionary *disabled;   // nil until loaded
@property (nonatomic, copy) NSString *status;          // shown while not loaded / on error
@property (nonatomic, assign) BOOL busy;
- (void)setLabels:(NSArray<NSString *> *)labels disabled:(BOOL)disable from:(UIViewController *)presenter;
- (BOOL)isLabelDisabled:(NSString *)label;
@end

#pragma mark - One group

@interface DaemonGroupViewController : UITableViewController
@property (nonatomic, strong) CYDaemonGroup *group;
@property (nonatomic, weak) DaemonsViewController *owner;
@end

@implementation DaemonGroupViewController

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.title = self.group.title;
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    return (NSInteger)self.group.labels.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section
{
    NSString *s = self.group.summary;
    if (self.group.caution) s = [s stringByAppendingFormat:@"\n\n⚠️ %@", self.group.caution];
    return [s stringByAppendingString:@"\n\nSwitched on means the daemon runs. Changes take effect after a restart."];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"label"];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"label"];
    NSString *label = self.group.labels[(NSUInteger)indexPath.row];
    UIListContentConfiguration *c = cell.defaultContentConfiguration;
    c.text = label;
    c.textProperties.font = [UIFont monospacedSystemFontOfSize:13 weight:UIFontWeightRegular];
    c.textProperties.adjustsFontSizeToFitWidth = YES;
    c.textProperties.minimumScaleFactor = 0.7;
    c.textProperties.numberOfLines = 1;
    cell.contentConfiguration = c;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    UISwitch *sw = [UISwitch new];
    sw.on = ![self.owner isLabelDisabled:label];
    sw.enabled = self.owner.disabled && !self.owner.busy;
    __weak typeof(self) weakSelf = self;
    [sw addAction:[UIAction actionWithHandler:^(UIAction *a) {
        typeof(self) me = weakSelf;
        BOOL on = ((UISwitch *)a.sender).isOn;
        [me.owner setLabels:@[ label ] disabled:!on from:me];
    }] forControlEvents:UIControlEventValueChanged];
    cell.accessoryView = sw;
    return cell;
}

@end

#pragma mark - All groups

@implementation DaemonsViewController

- (instancetype)init
{
    return [super initWithStyle:UITableViewStyleInsetGrouped];
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.title = @"Daemons";
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeAlways;
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"Turn All On" style:UIBarButtonItemStylePlain
                                        target:self action:@selector(confirmEnableAll)];
    self.refreshControl = [UIRefreshControl new];
    [self.refreshControl addTarget:self action:@selector(pullToRefresh) forControlEvents:UIControlEventValueChanged];
    self.status = @"Reading disabled daemons…";
    [self loadAllowingFullExploit:NO];
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    [self.tableView reloadData];   // a group screen may have changed something
}

- (void)pullToRefresh
{
    [self.refreshControl endRefreshing];
    [self loadAllowingFullExploit:NO];
}

- (BOOL)isLabelDisabled:(NSString *)label
{
    return [self.disabled[label] boolValue];
}

- (void)refreshUI
{
    self.navigationItem.rightBarButtonItem.enabled = self.disabled && !self.busy;
    [self.tableView reloadData];
    for (UIViewController *vc in self.navigationController.viewControllers)
        if ([vc isKindOfClass:DaemonGroupViewController.class]) [((UITableViewController *)vc).tableView reloadData];
}

#pragma mark Loading and saving

- (void)loadAllowingFullExploit:(BOOL)allowFullExploit
{
    if (self.busy) return;
    self.busy = YES;
    [self refreshUI];
    __weak typeof(self) weakSelf = self;
    settings_daemons_read_async(allowFullExploit, ^(NSDictionary *disabled, NSString *message) {
        typeof(self) me = weakSelf;
        if (!me) return;
        me.busy = NO;
        if (disabled) {
            me.disabled = disabled;
            me.status = nil;
        } else if (!me.disabled) {
            me.status = message;
        }
        [me refreshUI];
        if (!disabled) [me handleFailure:message retry:^{ [weakSelf loadAllowingFullExploit:YES]; } from:me];
    });
}

- (void)setLabels:(NSArray<NSString *> *)labels disabled:(BOOL)disable from:(UIViewController *)presenter
{
    CYDaemonGroup *group = nil;
    for (CYDaemonGroup *g in daemon_catalog_groups())
        if ([g.labels containsObject:labels.firstObject]) { group = g; break; }
    if (disable && group.caution) {
        UIAlertController *ac = [UIAlertController alertControllerWithTitle:[NSString stringWithFormat:@"Disable %@?", group.title]
                                                                    message:group.caution
                                                             preferredStyle:UIAlertControllerStyleAlert];
        [ac addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:^(UIAlertAction *a) {
            [self refreshUI];   // flip the switch back
        }]];
        [ac addAction:[UIAlertAction actionWithTitle:@"Disable" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
            [self applyLabels:labels disabled:YES allowFullExploit:NO from:presenter];
        }]];
        [presenter presentViewController:ac animated:YES completion:nil];
        return;
    }
    [self applyLabels:labels disabled:disable allowFullExploit:NO from:presenter];
}

- (void)applyLabels:(NSArray<NSString *> *)labels disabled:(BOOL)disable allowFullExploit:(BOOL)allowFullExploit
               from:(UIViewController *)presenter
{
    if (self.busy || !self.disabled) { [self refreshUI]; return; }
    NSMutableDictionary *changes = [NSMutableDictionary dictionary];
    for (NSString *label in labels) changes[label] = @(disable);
    self.busy = YES;
    [self refreshUI];
    __weak typeof(self) weakSelf = self;
    settings_daemons_apply_async(changes, allowFullExploit, ^(BOOL ok, NSString *message) {
        typeof(self) me = weakSelf;
        if (!me) return;
        me.busy = NO;
        if (ok) {
            NSMutableDictionary *d = [me.disabled mutableCopy];
            for (NSString *label in labels) {
                if (disable) d[label] = @YES;
                else [d removeObjectForKey:label];
            }
            me.disabled = d;
            daemons_note_change();
        }
        [me refreshUI];
        if (!ok) [me handleFailure:message retry:^{
            [weakSelf applyLabels:labels disabled:disable allowFullExploit:YES from:presenter];
        } from:presenter];
    });
}

// A failure that only a full exploit run can fix is asked about first (it can
// reboot A18/M4 devices), like the File Browser does; anything else is shown.
- (void)handleFailure:(NSString *)message retry:(void (^)(void))retry from:(UIViewController *)presenter
{
    if (!presenter.view.window || presenter.presentedViewController) return;
    UIAlertController *ac;
    if ([message isEqualToString:kSettingsFullExploitRequiredMessage]) {
        ac = [UIAlertController alertControllerWithTitle:@"No parked kernel state"
                                                 message:@"Daemons need kernel access, and there is no saved session to reuse. Running the full exploit can reboot the device on A18/M4. Continue?"
                                          preferredStyle:UIAlertControllerStyleAlert];
        [ac addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
        [ac addAction:[UIAlertAction actionWithTitle:@"Run Full Exploit" style:UIAlertActionStyleDefault
                                             handler:^(UIAlertAction *a) { retry(); }]];
    } else {
        ac = [UIAlertController alertControllerWithTitle:@"Daemons" message:message ?: @"Something went wrong."
                                          preferredStyle:UIAlertControllerStyleAlert];
        [ac addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    }
    [presenter presentViewController:ac animated:YES completion:nil];
}

- (void)confirmEnableAll
{
    NSMutableArray *labels = [NSMutableArray array];
    for (CYDaemonGroup *g in daemon_catalog_groups())
        for (NSString *label in g.labels)
            if ([self isLabelDisabled:label]) [labels addObject:label];
    if (!labels.count) return;
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"Turn All On?"
                                                                message:[NSString stringWithFormat:@"Lets all %lu disabled daemons from this list run again after the next restart.", (unsigned long)labels.count]
                                                         preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [ac addAction:[UIAlertAction actionWithTitle:@"Turn All On" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        [self applyLabels:labels disabled:NO allowFullExploit:NO from:self];
    }]];
    [self presentViewController:ac animated:YES completion:nil];
}

#pragma mark Table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView
{
    return 1;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    return (NSInteger)daemon_catalog_groups().count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
    if (self.status) return self.status;
    return daemons_restart_pending() ? @"Restart the device to apply your changes" : nil;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section
{
    return @"Switched on means the service runs. Turning one off writes it to launchd's disabled.plist; "
           @"it stops after the next restart. Only daemons from a list that is known to be safe to disable "
           @"on iOS 17 and 18 are offered. If something you need stops working, switch it back on and restart.";
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"group"];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"group"];
    CYDaemonGroup *g = daemon_catalog_groups()[(NSUInteger)indexPath.row];
    NSUInteger off = 0;
    for (NSString *label in g.labels) off += [self isLabelDisabled:label];

    UIListContentConfiguration *c = [UIListContentConfiguration subtitleCellConfiguration];
    c.image = [UIImage systemImageNamed:g.symbol] ?: [UIImage systemImageNamed:@"gearshape"];
    c.imageProperties.tintColor = g.caution ? UIColor.systemOrangeColor : UIColor.systemBlueColor;
    c.text = g.title;
    NSString *detail = g.summary;
    if (off > 0 && off < g.labels.count)
        detail = [NSString stringWithFormat:@"%lu of %lu disabled · %@", (unsigned long)off,
                  (unsigned long)g.labels.count, detail];
    c.secondaryText = detail;
    c.secondaryTextProperties.color = UIColor.secondaryLabelColor;
    c.secondaryTextProperties.numberOfLines = 0;
    cell.contentConfiguration = c;

    UISwitch *sw = [UISwitch new];
    sw.on = off == 0;   // partly disabled shows as off
    sw.enabled = self.disabled && !self.busy;
    __weak typeof(self) weakSelf = self;
    NSArray *labels = g.labels;
    [sw addAction:[UIAction actionWithHandler:^(UIAction *a) {
        typeof(self) me = weakSelf;
        [me setLabels:labels disabled:!((UISwitch *)a.sender).isOn from:me];
    }] forControlEvents:UIControlEventValueChanged];
    cell.accessoryView = sw;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    DaemonGroupViewController *vc = [[DaemonGroupViewController alloc] initWithStyle:UITableViewStyleInsetGrouped];
    vc.group = daemon_catalog_groups()[(NSUInteger)indexPath.row];
    vc.owner = self;
    [self.navigationController pushViewController:vc animated:YES];
}

@end
