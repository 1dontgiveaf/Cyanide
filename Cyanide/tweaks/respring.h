//
//  respring.h
//  Cyanide
//

#ifndef respring_h
#define respring_h

// Asks SpringBoard to relaunch itself after `delaySeconds`, scheduled on its
// own main run loop -- the same way it restarts after a settings change -- so
// it happens after this RemoteCall session is gone. Needs an open SpringBoard
// session. Same result values as the App Switcher card removal.
#include "app_switcher.h"
ASRemovalResult respring_schedule_in_session(double delaySeconds);

// Asks FrontBoard to reboot the device after `delaySeconds`
// (-[FBSystemService shutdownAndReboot:YES], the system's own restart),
// scheduled on SpringBoard's main run loop so it fires after this session is
// gone. Needs an open SpringBoard session.
ASRemovalResult reboot_schedule_in_session(double delaySeconds);

#endif /* respring_h */
