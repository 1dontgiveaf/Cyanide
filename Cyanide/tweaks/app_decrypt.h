//
//  app_decrypt.h
//  Cyanide
//
//  Settings → Lara → App Decrypt: makes a decrypted IPA of an App Store app
//  installed on this device, e.g. to inject a tweak into it and sideload it.
//  Idea from lara by rooootdev; implemented differently: every Mach-O in the
//  bundle (app, frameworks and app extensions) is decrypted with the kernel's
//  own FairPlay pager through mremap_encrypted, without launching the app and
//  without walking another process's memory.
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
NSString *app_decrypt_make_ipa(NSDictionary *app, void (^progress)(NSString *step, double fraction),
                               NSString **errorOut);
