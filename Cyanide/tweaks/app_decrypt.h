//
//  app_decrypt.h
//  Cyanide
//
//  Settings → Lara → App Decrypt: makes a decrypted IPA of an App Store app
//  installed on this device, e.g. to inject a tweak into it and sideload it.
//  Idea from lara by rooootdev; implemented differently: every Mach-O in the
//  bundle (app, frameworks and app extensions) is decrypted with the kernel's
//  own FairPlay pager through mremap_encrypted. A range that isn't 16 KB
//  aligned cannot use mremap_encrypted; that executable is started suspended,
//  its already-decrypted pages are read from the task, and it is killed before
//  it can run its UI. If iOS refuses the direct spawn, the app is opened
//  briefly through SpringBoard and stopped as soon as its pid exists.
//
//  Needs filesystem access (sandbox lifted). Blocking; run off-main.
//

#import <Foundation/Foundation.h>

// App Store apps (FairPlay-encrypted: SC_Info, no embedded.mobileprovision).
// Each: @{ name, bundleID, version, path (the .app), (icon) }.
NSArray<NSDictionary *> *app_decrypt_store_apps(void);

// Where finished IPAs are kept (Cyanide's Documents/Decrypted).
NSString *app_decrypt_output_dir(void);

// Builds <output dir>/<Name>_<version>_decrypted.ipa. `progress(step, 0…1)` is
// called on the calling thread. Returns the IPA path, or nil with *errorOut.
// useSpringBoard: a SpringBoard session is open (caller holds it); when iOS
// won't decrypt inside Cyanide, SpringBoard does it.
NSString *app_decrypt_make_ipa(NSDictionary *app, BOOL useSpringBoard,
                               void (^progress)(NSString *step, double fraction), NSString **errorOut);
