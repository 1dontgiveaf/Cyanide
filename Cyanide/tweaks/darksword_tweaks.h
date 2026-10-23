//
//  darksword_tweaks.h
//

#ifndef darksword_tweaks_h
#define darksword_tweaks_h

#import <stdbool.h>

bool darksword_tweak_disable_app_library_in_session(void);
bool darksword_tweak_disable_icon_fly_in_in_session(void);
bool darksword_tweak_zero_wake_animation_in_session(void);
bool darksword_tweak_zero_backlight_fade_in_session(void);
bool darksword_tweak_double_tap_to_lock_in_session(void);
// No blue "new" dot next to the names of newly installed or updated apps:
// clears the existing ones (SpringBoard's own clear, which also drops their
// stored state) and makes SBApplication report none until the next respring.
bool darksword_tweak_hide_new_app_dots_in_session(void);

// Extends the lock-screen idle timer (the short "dim then sleep" countdown
// that is separate from Settings > Auto-Lock) to the given number of seconds.
bool darksword_tweak_extend_lockscreen_duration_in_session(long long seconds);

// Reads the currently-configured lock-screen floor (SBMinimumLockscreenIdleTime
// in com.apple.springboard). Returns the seconds value, 0 if unset (stock), or
// -1 on failure. Must run inside SpringBoard via RemoteCall.
long long darksword_tweak_read_lockscreen_duration_in_session(void);

bool darksword_tweaks_apply_in_session(bool disableAppLibrary,
                                       bool disableIconFlyIn,
                                       bool zeroWakeAnimation,
                                       bool zeroBacklightFade,
                                       bool doubleTapToLock);

#endif
