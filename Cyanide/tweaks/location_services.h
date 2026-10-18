//
//  location_services.h
//  Cyanide
//
//  System-wide Location Services on/off, the same switch as Settings ->
//  Privacy & Security -> Location Services. Sent as
//  +[CLLocationManager setLocationServicesEnabled:] from a process locationd
//  accepts it from: SpringBoard first, Preferences as the fallback.
//

#ifndef location_services_h
#define location_services_h

#include <stdbool.h>
#include <stddef.h>

// Current state as seen by this app (no entitlement needed to read it):
// 1 = on, 0 = off.
int locationservices_enabled_local(void);

// What became of a setter request. NotSent: nothing reached the target
// (class/selector missing, session unusable) — the state can't change.
// Sent: the call completed. Uncertain: the call may or may not have run
// (transport lost its result) — verify by reading the state, never resend.
typedef enum {
    LSCallNotSent = 0,
    LSCallSent,
    LSCallUncertain,
} LSCallResult;

// Waits until the local state reads `enabled`, up to timeoutMS measured on a
// monotonic clock (query time included). Stops early, returning false, when
// the app starts leaving the foreground.
bool locationservices_wait_for_state(bool enabled, int timeoutMS);

// Sends the request through the already-open SpringBoard RemoteCall session.
LSCallResult locationservices_set_enabled_in_session(bool enabled);

// Fallback: sends the request from Preferences, but only if Preferences is
// already running (it is never launched: a foreground launch would push
// Cyanide into the background mid-operation). Opens and closes its own
// RemoteCall session; the caller must have closed any SpringBoard session.
LSCallResult locationservices_set_enabled_via_running_preferences(bool enabled);

// Where the user was when a request brought Cyanide to the front: SpringBoard's
// main-display layout state from before the current one (iOS 18 SpringBoard:
// SBWindowScene.layoutStateProvider.previousLayoutState). Home also covers the
// App Library and Today view. Unknown when the state can't be read, or when
// the current layout isn't Cyanide (the transition this is about didn't
// happen as expected) -- callers then keep their old behaviour.
typedef enum {
    LSOriginUnknown = 0,
    LSOriginHome,
    LSOriginApp,   // bundle ID in appOut
} LSOrigin;

// Needs an open SpringBoard session. selfBundleID is Cyanide's own.
LSOrigin locationservices_origin_in_session(const char *selfBundleID, char *appOut, size_t appLen);

#endif /* location_services_h */
