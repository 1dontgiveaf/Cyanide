//
//  location_services.m
//  Cyanide
//

#import "location_services.h"
#import "remote_objc.h"
#import "../TaskRop/RemoteCall.h"
#import "../TaskRop/Exception.h"   // excport_gate_blocked: leaving the foreground
#import "../LogTextView.h"   // mirror printf into the chain log

#import <CoreLocation/CoreLocation.h>
#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <stdio.h>
#import <string.h>
#import <unistd.h>

int locationservices_enabled_local(void)
{
    return [CLLocationManager locationServicesEnabled] ? 1 : 0;
}

bool locationservices_wait_for_state(bool enabled, int timeoutMS)
{
    uint64_t deadline = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) + (uint64_t)timeoutMS * 1000000ULL;
    for (;;) {
        if (locationservices_enabled_local() == (enabled ? 1 : 0)) return true;
        if (excport_gate_blocked()) return false;   // leaving the foreground
        uint64_t now = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW);
        if (now >= deadline) return false;
        uint64_t left = deadline - now;
        usleep((useconds_t)MIN(left / 1000ULL, 100000ULL));
    }
}

// +[CLLocationManager setLocationServicesEnabled:] in whatever process the
// current RemoteCall session targets. locationd checks the caller's
// entitlements; SpringBoard and Preferences both hold the locationd ones the
// Settings switch needs.
static LSCallResult locationservices_call_in_current(bool enabled, const char *host)
{
    uint64_t cls = r_class("CLLocationManager");
    if (!r_is_objc_ptr(cls)) {
        uint64_t path = r_alloc_str("/System/Library/Frameworks/CoreLocation.framework/CoreLocation");
        if (path) {
            r_dlsym_call(R_TIMEOUT, "dlopen", path, RTLD_LAZY | RTLD_GLOBAL, 0, 0, 0, 0, 0, 0);
            r_free(path);
        }
        cls = r_class("CLLocationManager");
    }
    if (!r_is_objc_ptr(cls)) {
        printf("[LOCSVC] CLLocationManager unavailable in %s\n", host);
        return LSCallNotSent;
    }
    // Class object: respondsToSelector: answers for class methods.
    if (!r_responds(cls, "setLocationServicesEnabled:")) {
        printf("[LOCSVC] +setLocationServicesEnabled: missing in %s\n", host);
        return LSCallNotSent;
    }
    r_msg2(cls, "setLocationServicesEnabled:", enabled ? 1 : 0, 0, 0, 0);
    LSCallResult r = r_last_call_ok() ? LSCallSent : LSCallUncertain;
    printf("[LOCSVC] %s: setLocationServicesEnabled:%d %s\n", host, enabled,
           r == LSCallSent ? "sent" : "UNCERTAIN (result lost)");
    return r;
}

LSCallResult locationservices_set_enabled_in_session(bool enabled)
{
    return locationservices_call_in_current(enabled, "SpringBoard");
}

static bool locationservices_ios_below_18(void)
{
    NSInteger major = NSProcessInfo.processInfo.operatingSystemVersion.majorVersion;
    return major > 0 && major < 18;
}

LSCallResult locationservices_set_enabled_via_running_preferences(bool enabled)
{
    // Short first-exception budget: a running Preferences traps quickly; a
    // missing one fails at once, a suspended one would never trap.
    const int kFirstTrapMS = 3000;
    int rc = locationservices_ios_below_18()
        ? init_remote_call_original_thread_only_with_first_exception_timeout("Preferences", false, kFirstTrapMS)
        : init_remote_call_with_first_exception_timeout("Preferences", false, kFirstTrapMS);
    if (rc != 0) {
        printf("[LOCSVC] Preferences not usable (%s pid=%u) — not launching it\n",
               remote_call_init_failure_description(remote_call_last_init_failure()),
               remote_call_last_init_failure_pid());
        return LSCallNotSent;
    }
    LSCallResult r = locationservices_call_in_current(enabled, "Preferences");
    destroy_remote_call();
    return r;
}

#pragma mark - Origin

// First app bundle ID in a layout state's app layout ("" if none).
static bool locsvc_layout_app(uint64_t layoutState, char *out, size_t outLen)
{
    out[0] = 0;
    if (!r_is_objc_ptr(layoutState) || !r_responds(layoutState, "appLayout")) return false;
    uint64_t appLayout = r_msg2_main(layoutState, "appLayout", 0, 0, 0, 0);
    if (!r_is_objc_ptr(appLayout) || !r_responds(appLayout, "allItems")) return false;
    // Fetched and retained in one checked step: 0 when the retain's outcome
    // is unknown, and then nothing is walked or released (a compensating
    // release after an uncertain retain could over-release the array).
    uint64_t items = r_msg2_main_retained(appLayout, "allItems");
    if (!items) return false;
    uint64_t n = r_msg2_main(items, "count", 0, 0, 0, 0);
    if (n > 8) n = 8;
    bool found = false;
    for (uint64_t i = 0; i < n && !found; i++) {
        uint64_t item = r_msg2_main(items, "objectAtIndex:", i, 0, 0, 0);
        if (!r_is_objc_ptr(item) || !r_responds(item, "bundleIdentifier")) continue;
        uint64_t bid = r_msg2_main(item, "bundleIdentifier", 0, 0, 0, 0);
        found = r_is_objc_ptr(bid) && r_read_nsstring(bid, out, outLen);
    }
    r_release(items);
    return found;
}

LSOrigin locationservices_origin_in_session(const char *selfBundleID, char *appOut, size_t appLen)
{
    if (!appOut || appLen == 0) return LSOriginUnknown;
    appOut[0] = 0;

    uint64_t appClass = r_class("UIApplication");
    uint64_t springboard = r_is_objc_ptr(appClass) ? r_msg2_main(appClass, "sharedApplication", 0, 0, 0, 0) : 0;
    uint64_t sceneManager = r_is_objc_ptr(springboard) && r_responds(springboard, "windowSceneManager")
        ? r_msg2_main(springboard, "windowSceneManager", 0, 0, 0, 0) : 0;
    uint64_t scene = r_is_objc_ptr(sceneManager) && r_responds(sceneManager, "embeddedDisplayWindowScene")
        ? r_msg2_main(sceneManager, "embeddedDisplayWindowScene", 0, 0, 0, 0) : 0;
    uint64_t provider = r_is_objc_ptr(scene) && r_responds(scene, "layoutStateProvider")
        ? r_msg2_main(scene, "layoutStateProvider", 0, 0, 0, 0) : 0;
    if (!r_is_objc_ptr(provider) || !r_responds(provider, "previousLayoutState")) {
        printf("[LOCSVC] origin: no layout state provider on this iOS\n");
        return LSOriginUnknown;
    }

    // The provider retains both states, so they stay valid while we read.
    uint64_t current = r_msg2_main(provider, "layoutState", 0, 0, 0, 0);
    uint64_t previous = r_msg2_main(provider, "previousLayoutState", 0, 0, 0, 0);
    char currentApp[256];
    locsvc_layout_app(current, currentApp, sizeof(currentApp));
    if (!selfBundleID || strcmp(currentApp, selfBundleID) != 0) {
        printf("[LOCSVC] origin: the current layout is not Cyanide\n");
        return LSOriginUnknown;
    }
    if (!r_is_objc_ptr(previous)) {
        printf("[LOCSVC] origin: no previous layout state\n");
        return LSOriginUnknown;
    }

    bool home = r_responds(previous, "effectivelyRepresentsHomeScreen") &&
                r_msg2_main(previous, "effectivelyRepresentsHomeScreen", 0, 0, 0, 0) != 0;
    if (!home && locsvc_layout_app(previous, appOut, appLen)) {
        // Not the bundle ID: logs can be uploaded, and which app was open is
        // the user's business.
        printf("[LOCSVC] origin: an app\n");
        return LSOriginApp;
    }
    appOut[0] = 0;
    // No app in the previous layout is the home screen (or App Library /
    // Today view, which are part of it).
    printf("[LOCSVC] origin: home screen\n");
    return LSOriginHome;
}
