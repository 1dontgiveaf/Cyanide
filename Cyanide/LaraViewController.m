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
#import "tweaks/app_decrypt.h"
#import "FileBrowserViewController.h"
#import <errno.h>
#import <PhotosUI/PhotosUI.h>

static NSString * const kLaraCredit = @"Ported from lara by rooootdev.";

typedef struct { int mode; const char *title; } LaraHUDMode;
static const LaraHUDMode kLaraHUDModes[] = {
    { -1, "Off" }, { 0, "Basic" }, { 1, "Backdrops" }, { 2, "Particles" }, { 3, "Full" },
    { 5, "Power" }, { 7, "EDR" }, { 8, "Glitches" }, { 9, "GPU Time" }, { 10, "Memory Bandwidth" },
};
static const NSInteger kLaraHUDModeCount = sizeof(kLaraHUDModes) / sizeof(kLaraHUDModes[0]);

@interface LaraViewController () <PHPickerViewControllerDelegate>
@property (nonatomic) LaraTool tool;
@property (nonatomic) BOOL busy;
@property (nonatomic, copy) NSString *status;        // shown in the first footer
@property (nonatomic) int hudMode;                   // -1 off, -2 unknown
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, NSNumber *> *prefStates;   // index -> 0/1
@property (nonatomic, copy) NSArray<NSDictionary *> *jitApps;   // nil until listed (JIT / app limit / cards)
@property (nonatomic, strong) NSDictionary *pickingCard;          // card whose image is being picked
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
            case LaraToolJIT:            self.title = @"JIT Enabler"; break;
            case LaraToolAppLimit:       self.title = @"3-App Limit"; break;
            case LaraToolCards:          self.title = @"Wallet Card Art"; break;
            case LaraToolDecrypt:        self.title = @"App Decrypt"; break;
        }
    }
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
    if (self.tool == LaraToolPerformanceHUD || self.tool == LaraToolHiddenSettings) [self readState];
    if (self.tool == LaraToolJIT || self.tool == LaraToolAppLimit || self.tool == LaraToolCards ||
        self.tool == LaraToolDecrypt) [self listJITApps];
}

// Apps signed with get-task-allow; needs the filesystem sandbox lifted.
- (void)listJITApps
{
    if (self.busy) return;
    self.busy = YES;
    self.status = @"Looking for apps…";
    [self.tableView reloadData];
    __weak typeof(self) weakSelf = self;
    settings_unlock_filesystem_async(NO, ^(BOOL ok, NSString *message) {
        typeof(self) me = weakSelf;
        if (!me) return;
        if (!ok) {
            me.busy = NO;
            BOOL needsRun = [message isEqualToString:kSettingsFullExploitRequiredMessage];
            me.status = needsRun ? kSettingsNoKernelAccessHint : (message ?: @"Filesystem access is not available.");
            [me.tableView reloadData];
            if (needsRun) settings_tool_needs_exploit(me, me.tableView, @"JIT Enabler", ^{ [weakSelf listJITApps]; });
            return;
        }
        BOOL limit = me.tool == LaraToolAppLimit, cards = me.tool == LaraToolCards, decrypt = me.tool == LaraToolDecrypt;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            NSArray *apps = decrypt ? app_decrypt_store_apps() : cards ? lara_wallet_cards()
                          : limit ? lara_sideloaded_apps() : lara_jit_candidate_apps();
            dispatch_async(dispatch_get_main_queue(), ^{
                typeof(self) me2 = weakSelf;
                if (!me2) return;
                me2.busy = NO;
                me2.jitApps = apps;
                // Keep a result message set while the list reloaded.
                BOOL placeholder = [me2.status isEqualToString:@"Looking for apps…"];
                me2.status = apps.count ? (placeholder ? nil : me2.status)
                    : decrypt ? @"No App Store apps found."
                    : cards ? @"No cards found in Wallet."
                    : limit ? @"No sideloaded apps found."
                    : @"No app here can get JIT. It only works for apps installed with a development profile (get-task-allow), e.g. sideloaded with a developer certificate.";
                [me2.tableView reloadData];
            });
        });
    });
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

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView
{
    // App limit: action, then the apps. Decrypt: finished IPAs, then the apps.
    return (self.tool == LaraToolAppLimit || self.tool == LaraToolDecrypt) ? 2 : 1;
}

- (NSUInteger)markedAppCount
{
    NSUInteger n = 0;
    for (NSDictionary *app in self.jitApps) if ([app[@"marked"] intValue] == 1) n++;
    return n;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    if (self.tool == LaraToolAppLimit) return section == 0 ? (self.jitApps ? 1 : 0) : (NSInteger)self.jitApps.count;
    if (self.tool == LaraToolDecrypt) return section == 0 ? 1 : (NSInteger)self.jitApps.count;
    switch (self.tool) {
        case LaraToolPerformanceHUD: return kLaraHUDModeCount;
        case LaraToolDebugOverlay:
        case LaraToolUpsideDown:     return 1;
        case LaraToolHiddenSettings: {
            NSInteger n = 0;
            for (const LaraPrefToggle *t = lara_pref_toggles(); t->title; t++) n++;
            return n;
        }
        case LaraToolJIT: return (NSInteger)self.jitApps.count;
        case LaraToolAppLimit: return 0;
        case LaraToolCards: return (NSInteger)self.jitApps.count;
        case LaraToolDecrypt: return 0;
    }
    return 0;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
    if (section != 1 || !self.jitApps.count) return nil;
    if (self.tool == LaraToolAppLimit) return @"Sideloaded Apps";
    if (self.tool == LaraToolDecrypt) return @"App Store Apps";
    return nil;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section
{
    if (section != [self numberOfSectionsInTableView:tableView] - 1) return nil;
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
        case LaraToolDecrypt:
            about = @"Makes a decrypted IPA of an App Store app on this device, e.g. to inject a tweak into it and sideload it. The app, its frameworks and extensions are decrypted by iOS itself. If an executable's encrypted range isn't 16 KB-aligned, Cyanide tries alternate decryption mappings; it does not launch the app. IPAs stay on this device (Documents/Decrypted) until you share them. Use it only for apps you own; removing copy protection may be restricted where you live.";
            break;
        case LaraToolCards:
            about = @"Replace the picture of a card in Wallet with your own (cosmetic only). The original is backed up and can be restored. Respring or reopen Wallet to see the change.";
            break;
        case LaraToolAppLimit:
            about = @"With a free Apple ID, iOS allows only 3 sideloaded apps: installd marks each one, and only marked apps count. Removing the marks frees the slots. Run it again after installing or refreshing (re-signing) an app, which marks it again.";
            break;
        case LaraToolJIT:
            about = @"Tap an app to open it with JIT (for emulators and similar apps). Only apps signed with a development profile can get it. JIT lasts until the app quits; some apps can't tell it's on.";
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
        case LaraToolDecrypt: {
            if (indexPath.section == 0) {
                NSUInteger n = 0;
                for (NSString *f in [NSFileManager.defaultManager contentsOfDirectoryAtPath:app_decrypt_output_dir() error:nil])
                    if ([f.pathExtension isEqualToString:@"ipa"]) n++;
                c.text = @"Decrypted IPAs";
                c.secondaryText = n ? [NSString stringWithFormat:@"%lu IPA%@ — open to share or delete", (unsigned long)n, n == 1 ? @"" : @"s"]
                                    : @"None yet";
                c.secondaryTextProperties.color = UIColor.secondaryLabelColor;
                c.image = [UIImage systemImageNamed:@"shippingbox.fill"];
                cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
                break;
            }
            NSDictionary *app = self.jitApps[indexPath.row];
            c.text = app[@"name"];
            c.secondaryText = [NSString stringWithFormat:@"%@ · %@", app[@"bundleID"], app[@"version"]];
            c.secondaryTextProperties.color = UIColor.secondaryLabelColor;
            c.image = app[@"icon"] ?: [UIImage systemImageNamed:@"app.dashed"];
            c.imageProperties.maximumSize = CGSizeMake(36, 36);
            c.imageProperties.cornerRadius = 8;
            break;
        }
        case LaraToolCards: {
            NSDictionary *card = self.jitApps[indexPath.row];
            c.text = card[@"name"];
            c.secondaryText = [card[@"hasBackup"] boolValue] ? @"Custom image — tap to change or restore" : @"Original image";
            c.secondaryTextProperties.color = UIColor.secondaryLabelColor;
            c.image = card[@"preview"] ?: [UIImage systemImageNamed:@"creditcard"];
            c.imageProperties.maximumSize = CGSizeMake(64, 41);
            c.imageProperties.cornerRadius = 4;
            break;
        }
        case LaraToolAppLimit: {
            if (indexPath.section == 0) {
                NSUInteger marked = [self markedAppCount];
                c.text = marked ? [NSString stringWithFormat:@"Remove Limit Marks (%lu)", (unsigned long)marked]
                                : @"No App Counts Toward the Limit";
                c.textProperties.color = (marked && !self.busy) ? UIColor.systemBlueColor : UIColor.secondaryLabelColor;
                break;
            }
            NSDictionary *app = self.jitApps[indexPath.row];
            int marked = [app[@"marked"] intValue];
            c.text = app[@"name"];
            c.secondaryText = marked == 1 ? @"Counts toward the limit" : marked == 0 ? @"Not counted" : @"Unknown";
            c.secondaryTextProperties.color = marked == 1 ? UIColor.systemOrangeColor : UIColor.secondaryLabelColor;
            c.image = app[@"icon"] ?: [UIImage systemImageNamed:@"app.dashed"];
            c.imageProperties.maximumSize = CGSizeMake(36, 36);
            c.imageProperties.cornerRadius = 8;
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            break;
        }
        case LaraToolJIT: {
            NSDictionary *app = self.jitApps[indexPath.row];
            c.text = app[@"name"];
            c.secondaryText = app[@"bundleID"];
            c.secondaryTextProperties.color = UIColor.secondaryLabelColor;
            c.image = app[@"icon"] ?: [UIImage systemImageNamed:@"app.dashed"];
            c.imageProperties.maximumSize = CGSizeMake(36, 36);
            c.imageProperties.cornerRadius = 8;
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
        case LaraToolAppLimit:
            if (indexPath.section == 0 && [self markedAppCount] > 0) [self removeLimitMarks];
            break;
        case LaraToolCards:
            [self cardTapped:self.jitApps[indexPath.row] at:indexPath];
            break;
        case LaraToolDecrypt:
            if (indexPath.section == 0) {
                [self.navigationController pushViewController:[[FileBrowserViewController alloc] initWithPath:app_decrypt_output_dir()]
                                                     animated:YES];
            } else {
                [self confirmDecrypt:self.jitApps[indexPath.row]];
            }
            break;
        case LaraToolJIT: {
            NSDictionary *app = self.jitApps[indexPath.row];
            NSString *bid = app[@"bundleID"], *name = app[@"name"];
            __block int err = 0;
            [self runNamed:[NSString stringWithFormat:@"Opening %@ with JIT", name]
                      work:^BOOL{ err = lara_jit_enable_in_session(bid); return err == 0; }
                      done:^(BOOL ok) {
                weakSelf.status = ok ? [NSString stringWithFormat:@"JIT is on for %@ until it quits.", name]
                    : err == ESRCH ? [NSString stringWithFormat:@"%@ didn't start. Open it once, then try again.", name]
                    : err == EPERM ? [NSString stringWithFormat:@"iOS refused to attach to %@. It needs a development profile (get-task-allow).", name]
                    : [NSString stringWithFormat:@"JIT couldn't be enabled for %@ (error %d). Check the log.", name, err];
            }];
            break;
        }
    }
}

#pragma mark App decrypt

- (void)confirmDecrypt:(NSDictionary *)app
{
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:[NSString stringWithFormat:@"Decrypt %@?", app[@"name"]]
        message:@"Makes a decrypted IPA of this app for your own use (e.g. tweak injection and sideloading). It can take a while for large apps; keep Cyanide open."
        preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [ac addAction:[UIAlertAction actionWithTitle:@"Decrypt" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        [weakSelf decrypt:app];
    }]];
    [self presentViewController:ac animated:YES completion:nil];
}

- (void)decrypt:(NSDictionary *)app
{
    if (self.busy) return;
    self.busy = YES;
    self.status = [NSString stringWithFormat:@"Decrypting %@…", app[@"name"]];
    // Show the progress where it's visible (the footer is below the list).
    self.navigationItem.prompt = self.status;
    [self.tableView reloadData];
    // A large app takes a while: keep going for a bit if Cyanide is backgrounded.
    __block UIBackgroundTaskIdentifier bg = [UIApplication.sharedApplication beginBackgroundTaskWithName:@"Decrypt" expirationHandler:^{
        [UIApplication.sharedApplication endBackgroundTask:bg];
        bg = UIBackgroundTaskInvalid;
    }];
    __weak typeof(self) weakSelf = self;
    __block NSString *ipa = nil, *error = nil;
    __block CFAbsoluteTime lastUI = 0;
    void (^progress)(NSString *, double) = ^(NSString *step, double fraction) {
        CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
        if (now - lastUI < 0.25 && fraction < 1) return;   // don't flood the main queue
        lastUI = now;
        dispatch_async(dispatch_get_main_queue(), ^{
            weakSelf.status = [NSString stringWithFormat:@"%@ — %.0f %%", step, fraction * 100];
            weakSelf.navigationItem.prompt = [NSString stringWithFormat:@"%.0f %% · %@", fraction * 100, step];
        });
    };
    // Inside a SpringBoard session: when iOS won't decrypt in Cyanide,
    // SpringBoard does it (same kernel-access rules as the other tools).
    settings_springboard_tool_async("App Decrypt", ^BOOL{
        ipa = app_decrypt_make_ipa(app, YES, progress, &error);
        return ipa != nil;
    }, ^(BOOL ok, NSString *message) {
        if (bg != UIBackgroundTaskInvalid) { [UIApplication.sharedApplication endBackgroundTask:bg]; bg = UIBackgroundTaskInvalid; }
        typeof(self) me = weakSelf;
        if (!me) return;
        me.busy = NO;
        me.navigationItem.prompt = nil;
        if ([message isEqualToString:kSettingsFullExploitRequiredMessage]) {
            me.status = kSettingsNoKernelAccessHint;
            [me.tableView reloadData];
            settings_tool_needs_exploit(me, me.tableView, @"App Decrypt", ^{ [weakSelf decrypt:app]; });
            return;
        }
        NSString *failure = error ?: message ?: @"Decryption failed. Check the log.";
        me.status = ipa ? [NSString stringWithFormat:@"Saved %@.", ipa.lastPathComponent] : failure;
        [me.tableView reloadData];
        if (!me.view.window) return;
        // An alert, not just the footer: that is below the whole app list.
        UIAlertController *ac = [UIAlertController
            alertControllerWithTitle:ipa ? @"IPA Ready" : @"Decryption Failed"
                             message:ipa ? [NSString stringWithFormat:@"%@ is saved in Decrypted IPAs.%@", ipa.lastPathComponent,
                                            error.length ? [@"\n\n" stringByAppendingString:error] : @""] : failure
                      preferredStyle:UIAlertControllerStyleAlert];
        if (ipa) {
            NSString *path = ipa;
            [ac addAction:[UIAlertAction actionWithTitle:@"Share…" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
                typeof(self) me2 = weakSelf;
                UITableViewCell *cell = [me2.tableView cellForRowAtIndexPath:[NSIndexPath indexPathForRow:0 inSection:0]];
                if (me2) filebrowser_share_file(me2, path, NO, nil, cell, nil);
            }]];
        }
        [ac addAction:[UIAlertAction actionWithTitle:ipa ? @"Done" : @"OK" style:UIAlertActionStyleCancel handler:nil]];
        [me presentViewController:ac animated:YES completion:nil];
    });
}

#pragma mark Wallet card art

- (void)cardTapped:(NSDictionary *)card at:(NSIndexPath *)indexPath
{
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:card[@"name"] message:nil
                                                         preferredStyle:UIAlertControllerStyleActionSheet];
    __weak typeof(self) weakSelf = self;
    [ac addAction:[UIAlertAction actionWithTitle:@"Choose Image…" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        [weakSelf pickImageForCard:card];
    }]];
    if ([card[@"hasBackup"] boolValue]) {
        [ac addAction:[UIAlertAction actionWithTitle:@"Restore Original" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
            NSString *err = nil;
            BOOL ok = lara_wallet_card_restore(card, &err);
            weakSelf.status = ok ? @"Original restored. Respring or reopen Wallet to see it." : err;
            [weakSelf listJITApps];
        }]];
    }
    [ac addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    UITableViewCell *cell = [self.tableView cellForRowAtIndexPath:indexPath];
    ac.popoverPresentationController.sourceView = cell ?: self.view;
    ac.popoverPresentationController.sourceRect = cell ? cell.bounds : self.view.bounds;
    [self presentViewController:ac animated:YES completion:nil];
}

- (void)pickImageForCard:(NSDictionary *)card
{
    self.pickingCard = card;
    PHPickerConfiguration *cfg = [[PHPickerConfiguration alloc] init];
    cfg.filter = PHPickerFilter.imagesFilter;
    cfg.selectionLimit = 1;
    PHPickerViewController *picker = [[PHPickerViewController alloc] initWithConfiguration:cfg];
    picker.delegate = self;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)picker:(PHPickerViewController *)picker didFinishPicking:(NSArray<PHPickerResult *> *)results
{
    [picker dismissViewControllerAnimated:YES completion:nil];
    NSDictionary *card = self.pickingCard;
    self.pickingCard = nil;
    NSItemProvider *provider = results.firstObject.itemProvider;
    if (!card || ![provider canLoadObjectOfClass:UIImage.class]) return;
    __weak typeof(self) weakSelf = self;
    [provider loadObjectOfClass:UIImage.class completionHandler:^(id<NSItemProviderReading> object, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if ([object isKindOfClass:UIImage.class]) [weakSelf applyImage:(UIImage *)object toCard:card];
        });
    }];
}

// Scales the picture to fill the original card image (same pixel size, so
// Wallet lays it out exactly like the original), then writes it.
- (void)applyImage:(UIImage *)picked toCard:(NSDictionary *)card
{
    UIImage *original = [UIImage imageWithContentsOfFile:card[@"imagePath"]];
    CGSize px = original ? CGSizeMake(original.size.width * original.scale, original.size.height * original.scale)
                         : CGSizeMake(1536, 969);
    UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat preferredFormat];
    fmt.scale = 1;
    fmt.opaque = YES;
    UIImage *scaled = [[[UIGraphicsImageRenderer alloc] initWithSize:px format:fmt] imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        CGFloat k = MAX(px.width / picked.size.width, px.height / picked.size.height);
        CGSize s = CGSizeMake(picked.size.width * k, picked.size.height * k);
        [picked drawInRect:CGRectMake((px.width - s.width) / 2, (px.height - s.height) / 2, s.width, s.height)];
    }];
    NSString *err = nil;
    BOOL ok = lara_wallet_card_set_image(card, UIImagePNGRepresentation(scaled), &err);
    self.status = ok ? @"Card image replaced. Respring or reopen Wallet to see it." : err;
    [self listJITApps];
}

// Removes installd's free-profile mark from every counted app, as root
// through launchd (the bundles stay owned by installd), then rescans.
- (void)removeLimitMarks
{
    NSMutableArray<NSString *> *paths = [NSMutableArray array];
    for (NSDictionary *app in self.jitApps) if ([app[@"marked"] intValue] == 1) [paths addObject:app[@"path"]];
    if (!paths.count || self.busy) return;
    self.busy = YES;
    self.status = @"Removing the marks…";
    [self.tableView reloadData];
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSUInteger done = 0;
        NSString *lastError = nil;
        for (NSString *path in paths) {
            NSString *err = nil;
            if (settings_root_remove_xattr(path, kLaraFreeProfileXattr, &err)) done++;
            else lastError = err;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) me = weakSelf;
            if (!me) return;
            me.busy = NO;
            [me listJITApps];
            me.status = done == paths.count
                ? [NSString stringWithFormat:@"Removed the mark from %lu app%@.", (unsigned long)done, done == 1 ? @"" : @"s"]
                : [NSString stringWithFormat:@"Removed %lu of %lu: %@", (unsigned long)done, (unsigned long)paths.count,
                                             lastError ?: @"see the log"];
        });
    });
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
