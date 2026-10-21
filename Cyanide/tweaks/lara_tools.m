//
//  lara_tools.m
//  Cyanide
//
//  Ported from lara by rooootdev (https://github.com/rooootdev/lara,
//  kexploit/pe/rc.m and views/tweaks/mobilegestalt/GestaltView.swift), with
//  his permission. lara's preference toggles come from Duy's SparseBox and the
//  Nugget tweak set (thanks to @jurre111 and @lunginspector, as credited there).
//
//  Differences from lara: every class, selector, method and IMP is checked
//  before anything is swapped (lara only checked on iOS 16), and the hidden
//  preferences go through cfprefsd from SpringBoard instead of overwriting the
//  Managed Preferences plists.
//

#import "lara_tools.h"
#import "remote_objc.h"
#import "../TaskRop/RemoteCall.h"
#import "../LogTextView.h"
#import "../FBAppContainers.h"
#import <errno.h>
#import <stdio.h>
#import <unistd.h>

#define LARA_CA_DEBUG_FLAG_PERFORMANCE_HUD 0x10000000ULL

#pragma mark - Performance HUD

int lara_perf_hud_get_in_session(void)
{
    uint64_t flags = r_dlsym_call(R_TIMEOUT, "CARenderServerGetDebugFlags", 0, 0, 0, 0, 0, 0, 0, 0);
    if (!r_last_call_ok()) return -2;
    if (!(flags & LARA_CA_DEBUG_FLAG_PERFORMANCE_HUD)) return -1;
    uint64_t mode = r_dlsym_call(R_TIMEOUT, "CARenderServerGetDebugValue", 0, 1, 0, 0, 0, 0, 0, 0);
    if (!r_last_call_ok()) return -2;
    return (int)mode;
}

bool lara_perf_hud_set_in_session(int mode)
{
    bool enable = mode >= 0;
    uint64_t flags = r_dlsym_call(R_TIMEOUT, "CARenderServerGetDebugFlags", 0, 0, 0, 0, 0, 0, 0, 0);
    if (!r_last_call_ok()) {
        printf("[LARA] HUD: CARenderServerGetDebugFlags failed\n");
        return false;
    }
    if (enable) {
        flags |= LARA_CA_DEBUG_FLAG_PERFORMANCE_HUD;
        r_dlsym_call(R_TIMEOUT, "CARenderServerSetDebugValue", 0, 1, (uint64_t)mode, 0, 0, 0, 0, 0);
    } else {
        flags &= ~LARA_CA_DEBUG_FLAG_PERFORMANCE_HUD;
    }
    r_dlsym_call(R_TIMEOUT, "CARenderServerSetDebugFlags", 0, LARA_CA_DEBUG_FLAG_PERFORMANCE_HUD, flags, 0, 0, 0, 0, 0);
    bool ok = r_last_call_ok();
    printf("[LARA] HUD mode=%d %s\n", mode, ok ? "set" : "failed");
    return ok;
}

#pragma mark - Method swapping

static uint64_t lara_instance_method(const char *clsName, const char *selName)
{
    uint64_t cls = r_class(clsName);
    uint64_t sel = r_sel(selName);
    if (!r_is_objc_ptr(cls) || !sel) return 0;
    return r_dlsym_call(R_TIMEOUT, "class_getInstanceMethod", cls, sel, 0, 0, 0, 0, 0, 0);
}

static uint64_t lara_method_imp(uint64_t method)
{
    return method ? r_dlsym_call(R_TIMEOUT, "method_getImplementation", method, 0, 0, 0, 0, 0, 0, 0) : 0;
}

static bool lara_set_imp(uint64_t method, uint64_t imp)
{
    return method && imp &&
           r_dlsym_call(R_TIMEOUT, "method_setImplementation", method, imp, 0, 0, 0, 0, 0, 0) != 0;
}

#pragma mark - Upside down

bool lara_upside_down_enable_in_session(void)
{
    // Targets, and existing methods whose implementation just returns the
    // constant we need (lara's "gadgets"):
    //   6    = portrait | portrait upside down (orientation mask)
    //   1    = YES
    //   0x1e = every orientation, for the scene participant's orientation
    //          mode / supported orientations
    uint64_t allowed     = lara_instance_method("SBTraitsSceneParticipantDelegate", "_isAllowedToHavePortraitUpsideDown");
    uint64_t home        = lara_instance_method("SBHomeScreenViewController", "supportedInterfaceOrientations");
    uint64_t lock        = lara_instance_method("SBCoverSheetPrimarySlidingViewController", "supportedInterfaceOrientations");
    uint64_t mode        = lara_instance_method("SBTraitsSceneParticipantDelegate", "_orientationMode");
    uint64_t supported   = lara_instance_method("SBTraitsSceneParticipantDelegate", "_supportedOrientations");
    uint64_t return1     = lara_instance_method("SBCoverSheetPrimarySlidingViewController", "_canShowWhileLocked");
    uint64_t return6     = lara_instance_method("SBShelfExpansionSwitcherModifier", "transactionCompletionOptions");
    uint64_t return0x1e  = lara_instance_method("SBAlertItemRootViewController", "supportedInterfaceOrientations");
    uint64_t imp1 = lara_method_imp(return1), imp6 = lara_method_imp(return6), imp1e = lara_method_imp(return0x1e);

    if (!allowed || !home || !lock || !mode || !supported || !imp1 || !imp6 || !imp1e) {
        printf("[LARA] upside down: missing method (allowed=%d home=%d lock=%d mode=%d supported=%d "
               "imp1=%d imp6=%d imp1e=%d) — nothing changed\n",
               !!allowed, !!home, !!lock, !!mode, !!supported, !!imp1, !!imp6, !!imp1e);
        log_user("[LARA] Upside Down isn't available on this iOS version.\n");
        return false;
    }
    bool ok = lara_set_imp(home, imp6) & lara_set_imp(lock, imp6) & lara_set_imp(allowed, imp1) &
              lara_set_imp(mode, imp1e) & lara_set_imp(supported, imp1e);
    printf("[LARA] upside down %s\n", ok ? "enabled" : "partially applied");
    return ok;
}

#pragma mark - UIKit debug overlay

static pid_t g_lara_overlay_pid = 0;   // SpringBoard pid the overlay was enabled in

// Our swap gives the overlay UIWindow's plain -init, which leaves it with a
// zero frame (it showed up tiny): size it to the screen explicitly.
static void lara_debug_overlay_size(uint64_t overlay, CGRect screenBounds)
{
    if (!r_is_objc_ptr(overlay) || CGRectIsEmpty(screenBounds)) return;
    double rect[4] = { screenBounds.origin.x, screenBounds.origin.y,
                       screenBounds.size.width, screenBounds.size.height };
    r_msg2_main_raw(overlay, "setFrame:", rect, sizeof(rect), NULL, 0, NULL, 0, NULL, 0);
}

bool lara_debug_overlay_enable_in_session(CGRect screenBounds)
{
    pid_t sbPid = (pid_t)remote_call_current_pid();
    if (sbPid > 0 && sbPid == g_lara_overlay_pid) {
        // A second gesture recognizer would only double-fire; just resize.
        uint64_t clsOverlay = r_class("UIDebuggingInformationOverlay");
        if (r_is_objc_ptr(clsOverlay))
            lara_debug_overlay_size(r_msg2_main(clsOverlay, "overlay", 0, 0, 0, 0), screenBounds);
        printf("[LARA] debug overlay already enabled in this SpringBoard\n");
        return true;
    }

    uint64_t clsOverlay = r_class("UIDebuggingInformationOverlay");
    uint64_t clsHandler = r_class("UIDebuggingInformationOverlayInvokeGestureHandler");
    uint64_t clsWorkspace = r_class("SBMainWorkspace");
    uint64_t clsApp = r_class("UIApplication");
    uint64_t clsTap = r_class("UITapGestureRecognizer");
    uint64_t overlayInit = lara_instance_method("UIDebuggingInformationOverlay", "init");
    uint64_t windowInitImp = lara_method_imp(lara_instance_method("UIWindow", "init"));
    if (!r_is_objc_ptr(clsOverlay) || !r_is_objc_ptr(clsHandler) || !r_is_objc_ptr(clsWorkspace) ||
        !r_is_objc_ptr(clsApp) || !r_is_objc_ptr(clsTap) || !overlayInit || !windowInitImp) {
        printf("[LARA] debug overlay: missing class/method — nothing changed\n");
        log_user("[LARA] The UIKit debug overlay isn't available on this iOS version.\n");
        return false;
    }

    uint64_t workspace = r_msg2_main(clsWorkspace, "sharedInstance", 0, 0, 0, 0);
    uint64_t scene = r_is_objc_ptr(workspace) ? r_msg2_main(workspace, "mainWindowScene", 0, 0, 0, 0) : 0;
    uint64_t app = r_msg2_main(clsApp, "sharedApplication", 0, 0, 0, 0);
    uint64_t statusBar = (r_is_objc_ptr(app) && r_responds(app, "statusBarForEmbeddedDisplay"))
        ? r_msg2_main(app, "statusBarForEmbeddedDisplay", 0, 0, 0, 0) : 0;
    uint64_t target = r_msg2_main(clsHandler, "mainHandler", 0, 0, 0, 0);
    if (!r_is_objc_ptr(scene) || !r_is_objc_ptr(statusBar) || !r_is_objc_ptr(target)) {
        printf("[LARA] debug overlay: scene=0x%llx statusBar=0x%llx handler=0x%llx — nothing changed\n",
               scene, statusBar, target);
        log_user("[LARA] Couldn't find the status bar to attach the debug overlay to.\n");
        return false;
    }

    // The overlay's -init refuses on customer builds: give it UIWindow's.
    if (!lara_set_imp(overlayInit, windowInitImp)) {
        printf("[LARA] debug overlay: init swap failed\n");
        return false;
    }
    uint64_t overlay = r_msg2_main(clsOverlay, "overlay", 0, 0, 0, 0);
    if (!r_is_objc_ptr(overlay)) {
        printf("[LARA] debug overlay: +overlay returned nil\n");
        return false;
    }
    r_msg2_main(overlay, "setWindowScene:", scene, 0, 0, 0);
    lara_debug_overlay_size(overlay, screenBounds);

    uint64_t tap = r_msg2_main(clsTap, "alloc", 0, 0, 0, 0);
    tap = r_is_objc_ptr(tap)
        ? r_msg2_main(tap, "initWithTarget:action:", target, r_sel("_handleActivationGesture:"), 0, 0) : 0;
    if (!r_is_objc_ptr(tap)) {
        printf("[LARA] debug overlay: gesture recognizer alloc failed\n");
        return false;
    }
    r_msg2_main(tap, "setNumberOfTapsRequired:", 2, 0, 0, 0);
    r_msg2_main(statusBar, "addGestureRecognizer:", tap, 0, 0, 0);
    g_lara_overlay_pid = sbPid;
    printf("[LARA] debug overlay enabled (double-tap the status bar)\n");
    return true;
}

#pragma mark - Hidden preferences

static const LaraPrefToggle kLaraPrefToggles[] = {
    { "Show Touches", "Draws a dot wherever you touch the screen.",
      "BKDigitizerVisualizeTouches", "com.apple.backboardd" },
    { "Show Build Version", "Shows the iOS build number in the status bar.",
      "UIStatusBarShowBuildVersion", "kCFPreferencesAnyApplication" },
    { "Metal HUD in All Apps", "Shows the Metal frame-rate overlay in apps that render with Metal.",
      "MetalForceHudEnabled", "kCFPreferencesAnyApplication" },
    { "Disable Low Battery Alerts", "No more 20 % / 10 % battery pop-ups.",
      "SBHideLowPowerAlerts", "com.apple.springboard" },
    { "Disable Breadcrumbs", "No \"◀ App\" back link in the status bar after switching apps.",
      "SBNeverBreadcrumb", "com.apple.springboard" },
    { "Disable Lock After Respring", "The device stays unlocked after a respring.",
      "SBDontLockAfterCrash", "com.apple.springboard" },
    { "Play Sound on Paste", "Plays a sound when an app reads the clipboard.",
      "PlaySoundOnPaste", "com.apple.Pasteboard" },
    { "System Paste Notifications", "Shows a banner whenever an app pastes.",
      "AnnounceAllPastes", "com.apple.Pasteboard" },
    { "App Store Debug Gesture", "Enables the App Store's hidden debug menu gesture.",
      "debugGestureEnabled", "com.apple.AppStore" },
    { "Notes Debug Mode", "Enables Notes' debug mode.",
      "DebugModeEnabled", "com.apple.mobilenotes" },
    { NULL, NULL, NULL, NULL },
};

const LaraPrefToggle *lara_pref_toggles(void)
{
    return kLaraPrefToggles;
}

int lara_pref_get_in_session(const LaraPrefToggle *t)
{
    if (!t || !t->key) return -1;
    uint64_t key = r_cfstr(t->key), domain = r_cfstr(t->domain);
    if (!key || !domain) return -1;
    r_dlsym_call(R_TIMEOUT, "CFPreferencesAppSynchronize", domain, 0, 0, 0, 0, 0, 0, 0);
    uint64_t value = r_dlsym_call(R_TIMEOUT, "CFPreferencesCopyAppValue", key, domain, 0, 0, 0, 0, 0, 0);
    if (!r_last_call_ok()) return -1;
    if (!r_is_objc_ptr(value)) return 0;
    int on = r_responds(value, "boolValue") ? (r_msg2(value, "boolValue", 0, 0, 0, 0) & 0xff) != 0 : 0;
    r_dlsym_call(R_TIMEOUT, "CFRelease", value, 0, 0, 0, 0, 0, 0, 0);
    return on;
}

bool lara_pref_set_in_session(const LaraPrefToggle *t, bool on)
{
    if (!t || !t->key) return false;
    uint64_t key = r_cfstr(t->key), domain = r_cfstr(t->domain);
    uint64_t clsNumber = r_class("NSNumber");
    if (!key || !domain || !r_is_objc_ptr(clsNumber)) return false;
    // Off removes the key (back to the iOS default) rather than storing NO.
    uint64_t value = on ? r_msg2(clsNumber, "numberWithBool:", 1, 0, 0, 0) : 0;
    if (on && !r_is_objc_ptr(value)) return false;
    r_dlsym_call(R_TIMEOUT, "CFPreferencesSetAppValue", key, value, domain, 0, 0, 0, 0, 0);
    r_dlsym_call(R_TIMEOUT, "CFPreferencesAppSynchronize", domain, 0, 0, 0, 0, 0, 0, 0);
    int now = lara_pref_get_in_session(t);
    bool ok = now == (on ? 1 : 0);
    printf("[LARA] pref %s/%s -> %d (readback %d)\n", t->domain, t->key, on, now);
    return ok;
}

#pragma mark - JIT

#define LARA_PT_ATTACHEXC 14
#define LARA_PT_DETACH    11

// The app's pid through RunningBoard, as SpringBoard sees it; 0 if not running.
static int lara_pid_for_bundle(uint64_t bundleStr)
{
    uint64_t clsPred = r_class("RBSProcessPredicate");
    uint64_t clsHandle = r_class("RBSProcessHandle");
    if (!r_is_objc_ptr(clsPred) || !r_is_objc_ptr(clsHandle)) return 0;
    uint64_t pred = r_msg2(clsPred, "predicateMatchingBundleIdentifier:", bundleStr, 0, 0, 0);
    if (!r_is_objc_ptr(pred)) return 0;
    uint64_t handle = r_msg2(clsHandle, "handleForPredicate:error:", pred, 0, 0, 0);
    if (!r_is_objc_ptr(handle)) return 0;
    return (int)(r_msg2(handle, "rbs_pid", 0, 0, 0, 0) & 0xffffffffULL);
}

int lara_jit_enable_in_session(NSString *bundleID)
{
    if (bundleID.length == 0) return EINVAL;
    uint64_t bundleStr = r_cfstr(bundleID.UTF8String);
    if (!bundleStr) return ENOMEM;

    int pid = lara_pid_for_bundle(bundleStr);
    uint64_t clsWorkspace = r_class("LSApplicationWorkspace");
    uint64_t workspace = r_is_objc_ptr(clsWorkspace) ? r_msg2(clsWorkspace, "defaultWorkspace", 0, 0, 0, 0) : 0;
    if (pid <= 0) {
        // Not running: open it from SpringBoard and wait for it to come up.
        if (!r_is_objc_ptr(workspace)) return ESRCH;
        r_msg2_main(workspace, "openApplicationWithBundleID:", bundleStr, 0, 0, 0);
        for (int i = 0; i < 25 && pid <= 0; i++) {
            usleep(200000);
            pid = lara_pid_for_bundle(bundleStr);
        }
        if (pid <= 0) {
            printf("[LARA] JIT: %s did not start\n", bundleID.UTF8String);
            return ESRCH;
        }
    }
    if (pid == getpid()) return EPERM;   // never Cyanide itself
    // ptrace returns an int: only w0 is meaningful, hence the (int) casts.

    int rc = (int)r_dlsym_call(R_TIMEOUT, "ptrace", LARA_PT_ATTACHEXC, (uint64_t)pid, 0, 0, 0, 0, 0, 0);
    if (rc == -1 || !r_last_call_ok()) {
        printf("[LARA] JIT: attach to %s (pid %d) refused — not signed with get-task-allow?\n",
               bundleID.UTF8String, pid);
        return EPERM;
    }
    usleep(100000);
    rc = (int)r_dlsym_call(R_TIMEOUT, "ptrace", LARA_PT_DETACH, (uint64_t)pid, 0, 0, 0, 0, 0, 0);
    if (rc == -1 || !r_last_call_ok()) {
        // Still attached would leave the app stopped: say so loudly.
        printf("[LARA] JIT: detach from %s (pid %d) failed\n", bundleID.UTF8String, pid);
        return EIO;
    }
    // Bring it to the front (it may have been running in the background).
    if (r_is_objc_ptr(workspace)) r_msg2_main(workspace, "openApplicationWithBundleID:", bundleStr, 0, 0, 0);
    printf("[LARA] JIT enabled for %s (pid %d)\n", bundleID.UTF8String, pid);
    return 0;
}

// get-task-allow from the app's embedded.mobileprovision (a signed blob with
// the XML plist inside).
static BOOL lara_profile_allows_debugging(NSString *appPath)
{
    NSData *data = [NSData dataWithContentsOfFile:[appPath stringByAppendingPathComponent:@"embedded.mobileprovision"]];
    if (data.length == 0) return NO;
    NSData *open = [@"<?xml" dataUsingEncoding:NSUTF8StringEncoding];
    NSData *close = [@"</plist>" dataUsingEncoding:NSUTF8StringEncoding];
    NSRange start = [data rangeOfData:open options:0 range:NSMakeRange(0, data.length)];
    if (start.location == NSNotFound) return NO;
    NSRange end = [data rangeOfData:close options:0 range:NSMakeRange(start.location, data.length - start.location)];
    if (end.location == NSNotFound) return NO;
    NSData *xml = [data subdataWithRange:NSMakeRange(start.location, NSMaxRange(end) - start.location)];
    NSDictionary *plist = [NSPropertyListSerialization propertyListWithData:xml options:0 format:NULL error:nil];
    NSDictionary *ents = [plist isKindOfClass:NSDictionary.class] ? plist[@"Entitlements"] : nil;
    id gta = [ents isKindOfClass:NSDictionary.class] ? ents[@"get-task-allow"] : nil;
    return [gta respondsToSelector:@selector(boolValue)] && [gta boolValue];
}

NSArray<NSDictionary *> *lara_jit_candidate_apps(void)
{
    NSString *root = @"/var/containers/Bundle/Application";
    NSFileManager *fm = NSFileManager.defaultManager;
    NSMutableArray *apps = [NSMutableArray array];
    for (NSString *uuid in [fm contentsOfDirectoryAtPath:root error:nil]) {
        NSString *container = [root stringByAppendingPathComponent:uuid];
        for (NSString *item in [fm contentsOfDirectoryAtPath:container error:nil]) {
            if (![item.pathExtension isEqualToString:@"app"]) continue;
            NSString *appPath = [container stringByAppendingPathComponent:item];
            if (!lara_profile_allows_debugging(appPath)) continue;
            NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:[appPath stringByAppendingPathComponent:@"Info.plist"]];
            NSString *bid = info[@"CFBundleIdentifier"];
            if (![bid isKindOfClass:NSString.class] || bid.length == 0) continue;
            if ([bid isEqualToString:NSBundle.mainBundle.bundleIdentifier]) continue;
            FBAppContainer *c = fb_container_for_path(container, NO);
            NSString *name = c.displayName.length ? c.displayName
                           : ([info[@"CFBundleDisplayName"] isKindOfClass:NSString.class] ? info[@"CFBundleDisplayName"]
                           : item.stringByDeletingPathExtension);
            NSMutableDictionary *app = [@{ @"name": name, @"bundleID": bid, @"path": appPath } mutableCopy];
            if (c.icon) app[@"icon"] = c.icon;
            [apps addObject:app];
        }
    }
    [apps sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [a[@"name"] localizedCaseInsensitiveCompare:b[@"name"]];
    }];
    return apps;
}

