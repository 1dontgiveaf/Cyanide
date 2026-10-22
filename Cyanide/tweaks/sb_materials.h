//
//  sb_materials.h
//  Cyanide
//
//  Settings → Lara → SpringBoard Tools: dock, folder, Control Center and
//  other material backgrounds. Idea from lara by rooootdev; implemented
//  differently: lara overwrites CoreMaterial's recipe files in /System, here
//  SpringBoard is pointed at a folder of edited recipes through CoreMaterial's
//  own override (+[NSBundle _setCoreMaterialOverrideRecipeBundleURL:]) and
//  its recipe cache is cleared. In memory until the next respring.
//
//  *_in_session: inside an open SpringBoard RemoteCall session (caller holds
//  settings_rc_lock()).
//

#import <Foundation/Foundation.h>
#import <stdbool.h>

// Test build: the dock background off (disable = YES) or back to normal.
bool sbmat_dock_test_in_session(bool disable, NSString **why);
