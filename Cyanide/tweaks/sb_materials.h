//
//  sb_materials.h
//  Cyanide
//
//  Settings → Lara → SpringBoard Tools: dock, folder, Control Center and
//  other material backgrounds. Idea from lara by rooootdev; implemented
//  differently: lara overwrites the recipe files in /System, here SpringBoard
//  gets edited recipes through CoreMaterial's own override folder
//  (+[NSBundle _setCoreMaterialOverrideRecipeBundleURL:]) and its recipe
//  cache. In memory until the next respring.
//

#import <Foundation/Foundation.h>
#import <stdbool.h>

typedef NS_ENUM(NSInteger, SBMatMode) {
    SBMatModeVisible = 0,    // Apple's recipe
    SBMatModeColor = 1,      // tint color and blur radius of your choice
    SBMatModeDisabled = 2,   // no material: what's behind shows through
};

typedef struct {
    const char *key;         // key in the config
    const char *title;
    const char *icon;        // SF Symbol
    const char *recipes;     // comma-separated recipe names
    double defaultBlur;      // blur radius offered for Color
    bool plainTint;          // Color as a plain tint instead of the filter's color matrix
} SBMatItem;

// The items, terminated by an entry with key == NULL.
const SBMatItem *sbmat_items(void);

// NSUserDefaults key of the saved config: item key -> @{ @"mode": @(SBMatMode),
// @"color": @[r, g, b, a] (0…1), @"blur": @(radius) }. Missing items are Visible.
extern NSString * const kSBMatConfigKey;

// Applies `config` in SpringBoard (inside an open RemoteCall session; caller
// holds settings_rc_lock()). Visible items get Apple's recipe back.
bool sbmat_apply_in_session(NSDictionary<NSString *, NSDictionary *> *config, NSString **why);
