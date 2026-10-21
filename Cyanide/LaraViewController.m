//
//  LaraViewController.m
//  Cyanide
//
//  Settings → Lara: tools ported from lara by rooootdev
//  (https://github.com/rooootdev/lara), with his permission. The SpringBoard
//  work lives in tweaks/lara_tools.m; this screen only drives it.
//

#import "LaraViewController.h"
#import "SettingsViewController.h"
#import "tweaks/lara_tools.h"

static NSString * const kLaraCredit = @"Ported from lara by rooootdev.";

typedef struct { int mode; const char *title; } LaraHUDMode;
static const LaraHUDMode kLaraHUDModes[] = {
    { -1, "Off" }, { 0, "Basic" }, { 1, "Backdrops" }, { 2, "Particles" }, { 3, "Full" },
    { 5, "Power" }, { 7, "EDR" }, { 8, "Glitches" }, { 9, "GPU Time" }, { 10, "Memory Bandwidth" },
};
static const NSInteger kLaraHUDModeCount = sizeof(kLaraHUDModes) / sizeof(kLaraHUDModes[0]);

@interface LaraViewController ()
@property (nonatomic) LaraTool tool;
@property (nonatomic) BOOL busy;
@property (nonatomic, copy) NSString *status;        // shown in the first footer
@property (nonatomic) int hudMode;                   // -1 off, -2 unknown
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, NSNumber *> *prefStates;   // index -> 0/1
@end

@implementation LaraViewController

- (instancetype)initWithTool:(LaraTool)tool
{
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (self) {
        _tool = tool;
        _hudMode = -2;
        _prefStates = [NSMutableDictionary dictionary];
        switch (tool) {
            case LaraToolPerformanceHUD: self.title = @"Performance HUD"; break;
            case LaraToolDebugOverlay:   self.title = @"Debug Overlay"; break;
            case LaraToolUpsideDown:     self.title = @"Upside Down"; break;
            case LaraToolHiddenSettings: self.title = @"Hidden Settings"; break;
        }
    }
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
    if (self.tool == LaraToolPerformanceHUD || self.tool == LaraToolHiddenSettings) [self readState];
}

#pragma mark Running

// Runs `work` in SpringBoard; handles busy state, the kernel-access popup and
// errors the same way for every Lara tool.
- (void)runNamed:(NSString *)name work:(BOOL (^)(void))work done:(void (^)(BOOL ok))done
{
    if (self.busy) return;
    self.busy = YES;
    self.status = [name stringByAppendingString:@"…"];
    [self.tableView reloadData];
    __weak typeof(self) weakSelf = self;
    settings_springboard_tool_async("Lara", work, ^(BOOL ok, NSString *message) {
        typeof(self) me = weakSelf;
        if (!me) return;
        me.busy = NO;
        if ([message isEqualToString:kSettingsFullExploitRequiredMessage]) {
            me.status = kSettingsNoKernelAccessHint;
            [me.tableView reloadData];
            settings_tool_needs_exploit(me, me.tableView, @"Lara", ^{
                [weakSelf runNamed:name work:work done:done];
            });
            return;
        }
        me.status = ok ? nil : (message ?: @"It didn't work. Check the log.");
        if (done) done(ok);
        [me.tableView reloadData];
    });
}

- (void)readState
{
    __weak typeof(self) weakSelf = self;
    if (self.tool == LaraToolPerformanceHUD) {
        __block int mode = -2;
        [self runNamed:@"Reading" work:^BOOL{
            mode = lara_perf_hud_get_in_session();
            return mode != -2;
        } done:^(BOOL ok) { weakSelf.hudMode = mode; }];
        return;
    }
    NSMutableDictionary *states = [NSMutableDictionary dictionary];
    [self runNamed:@"Reading" work:^BOOL{
        const LaraPrefToggle *t = lara_pref_toggles();
        for (NSInteger i = 0; t[i].title; i++) {
            int v = lara_pref_get_in_session(&t[i]);
            if (v >= 0) states[@(i)] = @(v);
        }
        return YES;
    } done:^(BOOL ok) { [weakSelf.prefStates setDictionary:states]; }];
}

#pragma mark Table

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    switch (self.tool) {
        case LaraToolPerformanceHUD: return kLaraHUDModeCount;
        case LaraToolDebugOverlay:
        case LaraToolUpsideDown:     return 1;
        case LaraToolHiddenSettings: {
            NSInteger n = 0;
            for (const LaraPrefToggle *t = lara_pref_toggles(); t->title; t++) n++;
            return n;
        }
    }
    return 0;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section
{
    NSString *about = nil;
    switch (self.tool) {
        case LaraToolPerformanceHUD:
            about = @"Core Animation's frame-rate and GPU overlay. Stays on until you turn it off or restart the device.";
            break;
        case LaraToolDebugOverlay:
            about = @"Apple's internal UIKit inspector. After enabling, double-tap the status bar to open it. Lasts until the next respring.";
            break;
        case LaraToolUpsideDown:
            about = @"Lets the Home Screen and Lock Screen rotate to portrait upside down. Lasts until the next respring.";
            break;
        case LaraToolHiddenSettings:
            about = @"Hidden iOS preferences. Most take effect after a respring and stay until you turn them off.";
            break;
    }
    NSMutableArray *parts = [NSMutableArray array];
    if (self.status) [parts addObject:self.status];
    [parts addObject:about];
    [parts addObject:kLaraCredit];
    return [parts componentsJoinedByString:@"\n\n"];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    UIListContentConfiguration *c = [UIListContentConfiguration subtitleCellConfiguration];
    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.accessoryView = nil;
    switch (self.tool) {
        case LaraToolPerformanceHUD: {
            LaraHUDMode m = kLaraHUDModes[indexPath.row];
            c.text = [NSString stringWithUTF8String:m.title];
            if (m.mode == self.hudMode) cell.accessoryType = UITableViewCellAccessoryCheckmark;
            break;
        }
        case LaraToolDebugOverlay:
            c.text = @"Enable Debug Overlay";
            c.textProperties.color = self.busy ? UIColor.secondaryLabelColor : UIColor.systemBlueColor;
            break;
        case LaraToolUpsideDown:
            c.text = @"Enable Upside Down";
            c.textProperties.color = self.busy ? UIColor.secondaryLabelColor : UIColor.systemBlueColor;
            break;
        case LaraToolHiddenSettings: {
            const LaraPrefToggle *t = &lara_pref_toggles()[indexPath.row];
            c.text = [NSString stringWithUTF8String:t->title];
            c.secondaryText = [NSString stringWithUTF8String:t->detail];
            c.secondaryTextProperties.color = UIColor.secondaryLabelColor;
            UISwitch *sw = [UISwitch new];
            NSNumber *state = self.prefStates[@(indexPath.row)];
            sw.on = state.boolValue;
            sw.enabled = !self.busy && state != nil;
            sw.tag = indexPath.row;
            [sw addTarget:self action:@selector(prefSwitched:) forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = sw;
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            break;
        }
    }
    cell.contentConfiguration = c;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (self.busy) return;
    __weak typeof(self) weakSelf = self;
    switch (self.tool) {
        case LaraToolPerformanceHUD: {
            int mode = kLaraHUDModes[indexPath.row].mode;
            [self runNamed:@"Setting the HUD" work:^BOOL{ return lara_perf_hud_set_in_session(mode); }
                      done:^(BOOL ok) { if (ok) weakSelf.hudMode = mode; }];
            break;
        }
        case LaraToolDebugOverlay: {
            CGRect screen = self.view.window.windowScene.screen.bounds;   // UIKit: read here, on main
            [self runNamed:@"Enabling" work:^BOOL{ return lara_debug_overlay_enable_in_session(screen); }
                      done:^(BOOL ok) { if (ok) weakSelf.status = @"Enabled. Double-tap the status bar."; }];
            break;
        }
        case LaraToolUpsideDown: {
            [self runNamed:@"Enabling" work:^BOOL{ return lara_upside_down_enable_in_session(); }
                      done:^(BOOL ok) { if (ok) weakSelf.status = @"Enabled. Turn the device upside down."; }];
            break;
        }
        case LaraToolHiddenSettings:
            break;
    }
}

- (void)prefSwitched:(UISwitch *)sw
{
    NSInteger index = sw.tag;
    BOOL on = sw.isOn;
    const LaraPrefToggle *t = &lara_pref_toggles()[index];
    __weak typeof(self) weakSelf = self;
    [self runNamed:@"Saving" work:^BOOL{ return lara_pref_set_in_session(t, on); }
              done:^(BOOL ok) {
        typeof(self) me = weakSelf;
        if (ok) {
            me.prefStates[@(index)] = @(on);
            me.status = @"Saved. Respring to apply.";
        }
    }];
}

@end
