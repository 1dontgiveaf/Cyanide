//
//  lara_tools.h
//  Cyanide
//
//  Tools ported from lara by rooootdev (https://github.com/rooootdev/lara),
//  with his permission. All run inside SpringBoard through an open RemoteCall
//  session (the *_in_session functions); callers hold settings_rc_lock().
//

#import <Foundation/Foundation.h>
#import <stdbool.h>
#import <CoreGraphics/CoreGraphics.h>

// Core Animation's performance HUD. Modes as in lara: -1 off, 0 Basic,
// 1 Backdrops, 2 Particles, 3 Full, 5 Power, 7 EDR, 8 Glitches, 9 GPU Time,
// 10 Memory Bandwidth. Lasts until backboardd restarts (respring keeps it).
bool lara_perf_hud_set_in_session(int mode);
// Current mode, -1 when off, -2 when it couldn't be read.
int  lara_perf_hud_get_in_session(void);

// UIKit's internal debug overlay, opened by double-tapping the status bar.
// Until the next respring.
// screenBounds: the screen in points (read on main by the caller); the overlay
// window is sized to it, since the bypassed -init no longer sizes it.
bool lara_debug_overlay_enable_in_session(CGRect screenBounds);

// Lets the Home Screen and Lock Screen rotate to portrait upside down. Until
// the next respring.
bool lara_upside_down_enable_in_session(void);

// Hidden preference toggles (the "Nugget" keys lara exposes), written through
// cfprefsd from SpringBoard into the user preference domains. Most need a
// respring to take effect; they persist across reboots.
typedef struct {
    const char *title;
    const char *detail;
    const char *key;
    const char *domain;   // preferences domain; "kCFPreferencesAnyApplication" = global
} LaraPrefToggle;
// The toggles, terminated by an entry with title == NULL.
const LaraPrefToggle *lara_pref_toggles(void);
// 1 on, 0 off/unset, -1 read failed.
int  lara_pref_get_in_session(const LaraPrefToggle *toggle);
bool lara_pref_set_in_session(const LaraPrefToggle *toggle, bool on);

// JIT for a sideloaded app signed with get-task-allow (a development
// profile): SpringBoard attaches to it as a debugger and detaches again,
// which marks the process as debugged so it may use JIT. Opens the app first
// when it isn't running. Lasts until the app quits.
// 0 on success, else an errno-style code (ESRCH: app didn't start).
int lara_jit_enable_in_session(NSString *bundleID);

// Installed apps that can get JIT (their embedded.mobileprovision allows
// get-task-allow). Each: @{ name, bundleID, path, (icon) }. Needs filesystem
// access (sandbox lifted); blocking.
NSArray<NSDictionary *> *lara_jit_candidate_apps(void);

// The free-account 3-app limit: installd marks every app installed with a
// free (non-paid) profile with this extended attribute, and only marked apps
// count. Sideloaded apps (with an embedded.mobileprovision), each:
// @{ name, bundleID, path, (icon), marked: @1 counted / @0 not / @-1 unknown }.
// Needs filesystem access; blocking.
extern const char *const kLaraFreeProfileXattr;
NSArray<NSDictionary *> *lara_sideloaded_apps(void);

