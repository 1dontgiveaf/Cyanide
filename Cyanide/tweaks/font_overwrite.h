//
//  font_overwrite.h
//  Cyanide
//
//  Settings → Lara → Font Overwrite. Idea from lara by rooootdev: replace a
//  system font in memory (the file cache), so SpringBoard and apps loading it
//  after a respring get another font; the sealed system volume itself never
//  changes and a reboot brings the original back. lara makes its read-only
//  mapping of the font writable by patching the VM map entry's protection;
//  Cyanide instead maps the file's own VM object a second time, writable,
//  through the same path App Decrypt and RemoteCall use (vm_map_object_range).
//
//  Needs kernel access and an open SpringBoard session (the Lock Screen's
//  PosterBoard and chronod are restarted from there after a change); blocking,
//  run off-main.
//

#import <Foundation/Foundation.h>
#import <stdbool.h>

typedef NS_ENUM(NSInteger, FontOWTarget) {
    FontOWTargetSystem,
    FontOWTargetItalic,
    FontOWTargetMono,
    FontOWTargetCount,
};

NSString *fontow_target_title(FontOWTarget target);
NSString *fontow_target_path(FontOWTarget target);
// Size of the system's file (the limit for a replacement), 0 if missing.
unsigned long long fontow_target_size(FontOWTarget target);

// Imported fonts (Documents/Fonts), newest first.
NSArray<NSString *> *fontow_imported_fonts(void);
// Copies a picked .ttf/.otf/.ttc into Documents/Fonts. Returns its path.
NSString *fontow_import(NSURL *url, NSString **errorOut);

// Replaced since the last reboot (so Restore has something to undo).
bool fontow_is_replaced(FontOWTarget target);

// Writes `fontPath` over the target in the file cache. Backs the original up
// first (only while it's still the original, i.e. not replaced since boot).
bool fontow_apply(FontOWTarget target, NSString *fontPath, NSString **result);
// Writes the backed-up original back.
bool fontow_restore(FontOWTarget target, NSString **result);
