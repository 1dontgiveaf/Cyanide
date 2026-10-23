//
//  sb_materials.m
//  Cyanide
//
//  See sb_materials.h. How CoreMaterial finds a recipe (iOS 18):
//  _SharedMaterialSettingsForRecipeWithNameFromBundle looks the name up in a
//  private cache (static NSMutableDictionary, name -> MTRecipeMaterialSettings)
//  and only on a miss loads <name>.materialrecipe: from the bundle the view
//  passed, then the override folder, then CoreMaterial's own bundle. So:
//   - our recipes go into an override folder in SpringBoard's temp directory;
//   - their names are removed from the cache and loaded again through a layer
//     that passes no bundle, which finds ours -- now every later request gets
//     them from the cache, even from views that name their own bundle
//     (folders: SpringBoardHome);
//   - views that already exist (the dock) load the recipe again, and their
//     weighting is set to 1: a layer blends its previous settings (weighting
//     0) into the new ones (1), and only the material view animates that.
//
//  The cache has no API. The shared cache is mapped at the same address in
//  every process, so its static variable is found here, in Cyanide: load a
//  recipe once and look through CoreMaterial's data for the dictionary that
//  now holds it. The same address in SpringBoard holds SpringBoard's cache.
//

#import "sb_materials.h"
#import "remote_objc.h"
#import "../TaskRop/RemoteCall.h"
#import "../LogTextView.h"
#import "sb_walk.h"
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <malloc/malloc.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <ptrauth.h>

extern const uintptr_t objc_debug_isa_class_mask;

static NSString * const kSBMatCoreMaterialPath = @"/System/Library/PrivateFrameworks/CoreMaterial.framework/CoreMaterial";

#pragma mark - Local (in Cyanide)

static BOOL sbmat_load_corematerial(void)
{
    static BOOL loaded;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        loaded = dlopen(kSBMatCoreMaterialPath.fileSystemRepresentation, RTLD_NOW) != NULL &&
                 objc_getClass("MTMaterialLayer") != Nil;
        if (!loaded) printf("[SBMAT] CoreMaterial couldn't be loaded: %s\n", dlerror() ?: "MTMaterialLayer missing");
    });
    return loaded;
}

// The system's <name>.materialrecipe: CoreMaterial's own bundle, or the
// framework that ships it (SpringBoard's recipes live with SpringBoard).
static NSURL *sbmat_system_recipe_url(NSString *name)
{
    for (NSString *framework in @[ @"SpringBoardHome", @"SpringBoard", @"SpringBoardFoundation", @"PlatterKit",
                                   @"ControlCenterUI", @"ControlCenterUIKit", @"CoverSheet" ]) {
        NSString *path = [NSString stringWithFormat:@"/System/Library/PrivateFrameworks/%@.framework/%@.materialrecipe",
                          framework, name];
        if ([NSFileManager.defaultManager fileExistsAtPath:path]) return [NSURL fileURLWithPath:path];
    }
    if (!sbmat_load_corematerial()) return nil;
    SEL bundleSel = sel_registerName("coreMaterialRecipeBundle"), urlSel = sel_registerName("URLForMaterialRecipe:");
    if (![NSBundle respondsToSelector:bundleSel]) return nil;
    NSBundle *bundle = ((id (*)(id, SEL))objc_msgSend)(NSBundle.class, bundleSel);
    if (![bundle respondsToSelector:urlSel]) return nil;
    return ((id (*)(id, SEL, id))objc_msgSend)(bundle, urlSel, name);
}

// The system's <name>.descendantrecipe (an ancestor recipe plus changes,
// e.g. Control Center's modulesSheer), as a dictionary, or nil.
static NSDictionary *sbmat_system_descendant(NSString *name)
{
    NSURL *url = nil;
    for (NSString *framework in @[ @"CoreMaterial", @"SpringBoardHome", @"SpringBoard", @"ControlCenterUI", @"ControlCenterUIKit" ]) {
        NSString *path = [NSString stringWithFormat:@"/System/Library/PrivateFrameworks/%@.framework/%@.descendantrecipe",
                          framework, name];
        if ([NSFileManager.defaultManager fileExistsAtPath:path]) { url = [NSURL fileURLWithPath:path]; break; }
    }
    if (!url && sbmat_load_corematerial()) {
        SEL bundleSel = sel_registerName("coreMaterialRecipeBundle"), urlSel = sel_registerName("URLForMaterialRecipeDescendant:");
        NSBundle *bundle = [NSBundle respondsToSelector:bundleSel] ? ((id (*)(id, SEL))objc_msgSend)(NSBundle.class, bundleSel) : nil;
        if ([bundle respondsToSelector:urlSel]) url = ((id (*)(id, SEL, id))objc_msgSend)(bundle, urlSel, name);
    }
    NSData *data = url ? [NSData dataWithContentsOfURL:url] : nil;
    NSDictionary *plist = data ? [NSPropertyListSerialization propertyListWithData:data options:0 format:NULL error:nil] : nil;
    return [plist isKindOfClass:NSDictionary.class] ? plist : nil;
}

// Address of CoreMaterial's recipe cache variable (the same in every
// process), found by loading `probe` here and looking for the dictionary
// holding it. 0 when not found.
static uint64_t sbmat_cache_slot(NSString *probe)
{
    static uint64_t slot;
    if (slot) return slot;
    if (!sbmat_load_corematerial()) return 0;
    id layer = [objc_getClass("MTMaterialLayer") new];
    ((void (*)(id, SEL, id))objc_msgSend)(layer, sel_registerName("setRecipeName:"), probe);

    const struct mach_header_64 *mh = NULL;
    intptr_t slide = 0;
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        const char *name = _dyld_get_image_name(i);
        if (name && strcmp(name, kSBMatCoreMaterialPath.fileSystemRepresentation) == 0) {
            mh = (const struct mach_header_64 *)_dyld_get_image_header(i);
            slide = _dyld_get_image_vmaddr_slide(i);
            break;
        }
    }
    if (!mh) { printf("[SBMAT] CoreMaterial image not found\n"); return 0; }

    // What the cache can be: +[NSMutableDictionary new] or a CF dictionary.
    CFMutableDictionaryRef cf = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    uintptr_t dictClasses[2] = { (uintptr_t)object_getClass([NSMutableDictionary new]), (uintptr_t)object_getClass((__bridge id)cf) };
    CFRelease(cf);
    Class settingsCls = objc_getClass("MTRecipeMaterialSettings");

    const uint8_t *p = (const uint8_t *)(mh + 1);
    for (uint32_t c = 0; c < mh->ncmds && !slot; c++) {
        const struct load_command *lc = (const void *)p;
        p += lc->cmdsize;
        if (lc->cmd != LC_SEGMENT_64) continue;
        const struct segment_command_64 *seg = (const void *)lc;
        if (strncmp(seg->segname, "__DATA", 6) != 0) continue;   // __DATA, __DATA_DIRTY (statics)
        const struct section_64 *sect = (const void *)(seg + 1);
        for (uint32_t s = 0; s < seg->nsects && !slot; s++) {
            const uintptr_t *w = (const uintptr_t *)(uintptr_t)(sect[s].addr + slide);
            uint64_t words = sect[s].size / sizeof(uintptr_t);
            for (uint64_t k = 0; k < words; k++) {
                uintptr_t v = w[k];
                // Only heap blocks are dereferenced, and only their isa read,
                // until the class is known to be a dictionary.
                if (!v || (v & 0xf) || !malloc_zone_from_ptr((const void *)v)) continue;
                uintptr_t cls = (uintptr_t)ptrauth_strip((void *)(*(const uintptr_t *)v & objc_debug_isa_class_mask),
                                                         ptrauth_key_asda);
                if (cls != dictClasses[0] && cls != dictClasses[1]) continue;
                id value = ((__bridge NSDictionary *)(void *)v)[probe];
                if (value && (!settingsCls || [value isKindOfClass:settingsCls])) {
                    slot = (uint64_t)(uintptr_t)&w[k];
                    break;
                }
            }
        }
    }
    printf("[SBMAT] recipe cache variable: %s (0x%llx)\n", slot ? "found" : "not found", slot);
    (void)layer;
    return slot;
}

// CoreMaterial asserts (and SpringBoard aborts) on a color component outside
// 0…1; the color picker hands out extended sRGB (P3 colors go past it).
static double sbmat_unit(NSArray<NSNumber *> *rgba, NSUInteger i, double fallback)
{
    double v = i < rgba.count && [rgba[i] isKindOfClass:NSNumber.class] ? rgba[i].doubleValue : fallback;
    return isfinite(v) ? MIN(MAX(v, 0.0), 1.0) : fallback;
}

// Apple's recipe edited for `mode`. Version-2 recipes keep the backdrop
// filter in baseMaterial.materialFiltering and a tint next to it in
// baseMaterial.tinting; materialSettingsVersion stays (it names the format).
//  - Disabled: no blur and no tint, an identity, so CoreMaterial switches the
//    backdrop off.
//  - Color: the blur radius, and the tint as part of the filter (a color
//    matrix: each channel becomes (1 - a) * itself + a * color), which is
//    drawn with the material's rounding everywhere -- or, plainTint, as a
//    plain tint (Control Center's background: with the color matrix its
//    fade made dismissing Control Center slow).
//  - Visible: Apple's filter.
// On the lock screen, iOS draws notifications as one shared blur cut into
// rounded shapes; one with a changed material drops out of it and is drawn
// square (lara's recipe files do the same). nil when the system has no such
// recipe.
static NSData *sbmat_edited_recipe(NSString *name, SBMatMode mode, NSArray<NSNumber *> *rgba, double blur,
                                   bool plainTint)
{
    NSURL *url = sbmat_system_recipe_url(name);
    NSData *data = url ? [NSData dataWithContentsOfURL:url] : nil;
    NSDictionary *plist = data ? [NSPropertyListSerialization propertyListWithData:data options:0 format:NULL error:nil] : nil;
    if (![plist isKindOfClass:NSDictionary.class]) return nil;
    NSMutableDictionary *changed = [plist mutableCopy];
    NSMutableDictionary *base = [plist[@"baseMaterial"] isKindOfClass:NSDictionary.class] ? [plist[@"baseMaterial"] mutableCopy]
                                                                                       : [NSMutableDictionary dictionary];
    if (mode == SBMatModeDisabled) {
        base[@"materialFiltering"] = @{ @"blurRadius": @0 };
        [base removeObjectForKey:@"tinting"];
    } else if (mode == SBMatModeColor) {
        NSMutableDictionary *filtering = [base[@"materialFiltering"] isKindOfClass:NSDictionary.class]
            ? [base[@"materialFiltering"] mutableCopy] : [NSMutableDictionary dictionary];
        filtering[@"blurRadius"] = @(isfinite(blur) ? MIN(MAX(blur, 0), 100) : 0);
        double r = sbmat_unit(rgba, 0, 0), g = sbmat_unit(rgba, 1, 0), b = sbmat_unit(rgba, 2, 0), a = sbmat_unit(rgba, 3, 0.5);
        double k = 1.0 - a;
        if (plainTint) {
            base[@"materialFiltering"] = filtering;
            base[@"tinting"] = @{ @"tintAlpha": @(a),
                                  @"tintColor": @{ @"alpha": @1.0, @"red": @(r), @"green": @(g), @"blue": @(b) } };
        } else {
            filtering[@"colorMatrix"] = @{
                @"m11": @(k), @"m12": @0, @"m13": @0, @"m14": @0, @"m15": @(a * r),
                @"m21": @0, @"m22": @(k), @"m23": @0, @"m24": @0, @"m25": @(a * g),
                @"m31": @0, @"m32": @0, @"m33": @(k), @"m34": @0, @"m35": @(a * b),
                @"m41": @0, @"m42": @0, @"m43": @0, @"m44": @1, @"m45": @0 };
            base[@"materialFiltering"] = filtering;
            [base removeObjectForKey:@"tinting"];
        }
    }
    changed[@"baseMaterial"] = base;
    return [NSPropertyListSerialization dataWithPropertyList:changed format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
}

#pragma mark - SpringBoard

static void sbmat_cfrelease(uint64_t cf)
{
    if (cf) r_dlsym_call(R_TIMEOUT, "CFRelease", cf, 0, 0, 0, 0, 0, 0, 0);
}

// Writes `files` (name -> data) into a new folder in SpringBoard's temp
// directory and returns its path (a remote NSString, retained), or 0. A new
// folder each time: NSBundle caches a folder's contents.
static uint64_t sbmat_write_folder(NSDictionary<NSString *, NSData *> *files)
{
    uint64_t tmp = r_dlsym_call(R_TIMEOUT, "NSTemporaryDirectory", 0, 0, 0, 0, 0, 0, 0, 0);
    if (!r_is_objc_ptr(tmp)) return 0;
    NSString *leaf = [@"CyanideMaterials-" stringByAppendingString:[NSUUID.UUID.UUIDString substringToIndex:8]];
    uint64_t leafStr = r_cfstr(leaf.UTF8String);
    uint64_t dir = r_msg2(tmp, "stringByAppendingPathComponent:", leafStr, 0, 0, 0);
    sbmat_cfrelease(leafStr);
    if (!r_is_objc_ptr(dir)) return 0;
    r_msg2(dir, "retain", 0, 0, 0, 0);
    uint64_t fm = r_msg2(r_class("NSFileManager"), "defaultManager", 0, 0, 0, 0);
    if (!r_msg2(fm, "createDirectoryAtPath:withIntermediateDirectories:attributes:error:", dir, 1, 0, 0)) {
        printf("[SBMAT] SpringBoard couldn't create its recipe folder\n");
        r_release(dir);
        return 0;
    }
    __block BOOL ok = YES;
    [files enumerateKeysAndObjectsUsingBlock:^(NSString *file, NSData *data, BOOL *stop) {
        uint64_t buf = r_dlsym_call(R_TIMEOUT, "malloc", data.length, 0, 0, 0, 0, 0, 0, 0);
        uint64_t name = r_cfstr(file.UTF8String);
        uint64_t path = name ? r_msg2(dir, "stringByAppendingPathComponent:", name, 0, 0, 0) : 0;
        uint64_t nsdata = (buf && remote_write(buf, data.bytes, data.length))
            ? r_msg2(r_class("NSData"), "dataWithBytes:length:", buf, data.length, 0, 0) : 0;
        BOOL wrote = r_is_objc_ptr(nsdata) && r_is_objc_ptr(path) && r_msg2(nsdata, "writeToFile:atomically:", path, 1, 0, 0);
        if (buf) r_free(buf);
        sbmat_cfrelease(name);
        printf("[SBMAT] wrote %s (%lu bytes): %s\n", file.UTF8String, (unsigned long)data.length, wrote ? "ok" : "failed");
        if (!wrote) { ok = NO; *stop = YES; }
    }];
    if (!ok) { r_release(dir); return 0; }
    return dir;
}

static NSString *sbmat_recipe_name(uint64_t layer)
{
    uint64_t rn = r_is_objc_ptr(layer) && r_responds_main(layer, "recipeName")
        ? r_msg2_main(layer, "recipeName", 0, 0, 0, 0) : 0;
    char buf[128] = {0};
    return r_is_objc_ptr(rn) && r_read_nsstring(rn, buf, sizeof(buf)) ? @(buf) : nil;
}

// The Home Screen's root folder view (pages and dock). 0 when not found.
static uint64_t sbmat_root_folder_view(void)
{
    uint64_t ctrl = r_msg2_main(r_class("SBIconController"), "sharedInstance", 0, 0, 0, 0);
    uint64_t mgr = r_is_objc_ptr(ctrl) ? r_msg2_main(ctrl, "iconManager", 0, 0, 0, 0) : 0;
    uint64_t root = r_is_objc_ptr(mgr) ? r_msg2_main(mgr, "rootFolderController", 0, 0, 0, 0) : 0;
    return r_is_objc_ptr(root) ? r_msg2_main(root, "rootFolderView", 0, 0, 0, 0) : 0;
}

// The dock's material view, straight from the home screen's view
// controllers (a view walk is too slow). 0 when not found.
static uint64_t sbmat_dock_material_view(void)
{
    uint64_t rootView = sbmat_root_folder_view();
    uint64_t dock = r_is_objc_ptr(rootView) && r_responds_main(rootView, "dockView")
        ? r_msg2_main(rootView, "dockView", 0, 0, 0, 0) : 0;
    uint64_t bg = r_is_objc_ptr(dock) && r_responds_main(dock, "backgroundView")
        ? r_msg2_main(dock, "backgroundView", 0, 0, 0, 0) : 0;
    return r_is_objc_ptr(bg) && r_msg2_main(bg, "isKindOfClass:", r_class("MTMaterialView"), 0, 0, 0) ? bg : 0;
}

// Recipes of items set to Disabled, during an apply.
static NSSet<NSString *> *g_sbmat_disabled;

// Makes an existing material view load its recipe again (from the cache,
// which now holds ours or Apple's) and show it fully. Disabled hides it: an
// existing layer keeps its old filters when the new settings are an identity
// (CoreMaterial's preservingFiltersIfIdentity), so its blur would stay.
// setWeighting: false for views whose owner animates the weighting itself
// (Control Center on every open and dismiss): forcing it there left the
// background behind for a moment when dismissing.
static bool sbmat_reload_view(uint64_t view, bool setWeighting)
{
    uint64_t layer = r_is_objc_ptr(view) ? r_msg2_main(view, "layer", 0, 0, 0, 0) : 0;
    NSString *recipe = r_is_objc_ptr(layer) && r_responds_main(layer, "setRecipeName:") ? sbmat_recipe_name(layer) : nil;
    if (!recipe) return false;
    uint64_t str = r_cfstr(recipe.UTF8String);
    uint64_t before = r_msg2_main(layer, "_recipeSettings", 0, 0, 0, 0);
    r_msg2_main(layer, "setRecipeName:", str, 0, 0, 0);
    uint64_t after = r_msg2_main(layer, "_recipeSettings", 0, 0, 0, 0);
    sbmat_cfrelease(str);
    if (r_responds_main(layer, "_updateForChangeInRecipeAndConfiguration"))
        r_msg2_main(layer, "_updateForChangeInRecipeAndConfiguration", 0, 0, 0, 0);
    // Weighting 0 shows the previous settings, 1 the new ones; the material
    // view manages it, the layer follows.
    double one = 1.0;
    if (setWeighting && r_responds_main(view, "setWeighting:"))
        r_msg2_main_raw(view, "setWeighting:", &one, sizeof(one), NULL, 0, NULL, 0, NULL, 0);
    if (setWeighting && r_responds_main(layer, "setWeighting:"))
        r_msg2_main_raw(layer, "setWeighting:", &one, sizeof(one), NULL, 0, NULL, 0, NULL, 0);
    // The filters are rebuilt in -layoutSublayers only while _needsConfiguring is set.
    if (r_responds_main(layer, "_setNeedsConfiguring"))
        r_msg2_main(layer, "_setNeedsConfiguring", 0, 0, 0, 0);
    r_msg2_main(layer, "layoutIfNeeded", 0, 0, 0, 0);
    bool hide = [g_sbmat_disabled containsObject:recipe];
    r_msg2_main(view, "setHidden:", hide, 0, 0, 0);
    printf("[SBMAT] %s reloaded (%s)%s\n", recipe.UTF8String, before != after ? "new settings" : "same settings",
           hide ? ", hidden (Disabled)" : "");
    return before != after;
}

// Existing material views under `root` whose recipe is one of `names`,
// reloaded (main-thread walk: only for small subtrees).
static int sbmat_reload_views_under(uint64_t root, NSSet<NSString *> *names, const char *what, bool setWeighting)
{
    if (!r_is_objc_ptr(root)) { printf("[SBMAT] %s: not loaded, nothing to reload\n", what); return 0; }
    static uint64_t views[256];
    int n = sb_collect_views_main(root, r_class("MTMaterialView"), views, 256);
    int reloaded = 0;
    NSCountedSet *seen = [NSCountedSet set];
    for (int i = 0; i < n; i++) {
        uint64_t layer = r_msg2_main(views[i], "layer", 0, 0, 0, 0);
        NSString *recipe = sbmat_recipe_name(layer);
        [seen addObject:recipe ?: @"?"];
        if (recipe && [names containsObject:recipe] && sbmat_reload_view(views[i], setWeighting)) reloaded++;
    }
    NSMutableArray *list = [NSMutableArray array];
    for (NSString *r in seen) [list addObject:[NSString stringWithFormat:@"%@x%lu", r, (unsigned long)[seen countForObject:r]]];
    printf("[SBMAT] %s: %d material view(s) [%s], %d reloaded\n", what, n,
           [list componentsJoinedByString:@", "].UTF8String, reloaded);
    return reloaded;
}

// Folder icons on the Home Screen and in the dock each have a material view
// of their own (SBFolderIconImageView._backgroundView), kept as long as the
// icon is: without a reload they keep whatever they were last built with.
static void sbmat_reload_folder_icons(NSSet<NSString *> *names)
{
    uint64_t rootView = sbmat_root_folder_view();
    if (!r_is_objc_ptr(rootView)) { printf("[SBMAT] folder icons: Home Screen not found\n"); return; }
    uint64_t lists[48];
    int nLists = 0;
    uint64_t pages = r_responds_main(rootView, "iconListViews") ? r_msg2_main_retained(rootView, "iconListViews") : 0;
    if (r_is_objc_ptr(pages)) {
        nLists = r_array_items_of_class(pages, r_class("SBIconListView"), lists, 47);
        r_release(pages);
    }
    uint64_t dockList = r_responds_main(rootView, "dockListView") ? r_msg2_main(rootView, "dockListView", 0, 0, 0, 0) : 0;
    if (r_is_objc_ptr(dockList)) lists[nLists++] = dockList;
    uint64_t iconViewCls = r_class("SBIconView"), folderImageCls = r_class("SBFolderIconImageView");
    uint64_t materialCls = r_class("MTMaterialView");
    static uint64_t icons[128];
    int folders = 0, reloaded = 0;
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    for (int l = 0; l < nLists; l++) {
        int n = sb_collect_views_main(lists[l], iconViewCls, icons, 128);
        for (int i = 0; i < n; i++) {
            uint64_t image = r_ivar_value(icons[i], "_iconImageView");
            if (!r_is_objc_ptr(image) || !r_msg2_main(image, "isKindOfClass:", folderImageCls, 0, 0, 0)) continue;
            folders++;
            uint64_t bg = r_ivar_value(image, "_backgroundView");
            if (!r_is_objc_ptr(bg) || !r_msg2_main(bg, "isKindOfClass:", materialCls, 0, 0, 0)) continue;
            NSString *recipe = sbmat_recipe_name(r_msg2_main(bg, "layer", 0, 0, 0, 0));
            [seen addObject:recipe ?: @"?"];
            if (recipe && [names containsObject:recipe] && sbmat_reload_view(bg, true)) reloaded++;
        }
    }
    printf("[SBMAT] folder icons: %d page(s), %d folder(s) [%s], %d reloaded\n", nLists, folders,
           [seen.allObjects componentsJoinedByString:@", "].UTF8String, reloaded);
}

// Control Center keeps its views once it has been opened: reach them
// through its view controller, or else its window.
static void sbmat_reload_control_center(NSSet<NSString *> *names)
{
    // iOS 18: one per window scene (the shared instance is nil).
    uint64_t app = r_msg2_main(r_class("UIApplication"), "sharedApplication", 0, 0, 0, 0);
    uint64_t manager = r_is_objc_ptr(app) && r_responds_main(app, "windowSceneManager") ? r_msg2_main(app, "windowSceneManager", 0, 0, 0, 0) : 0;
    uint64_t scene = r_is_objc_ptr(manager) && r_responds_main(manager, "embeddedDisplayWindowScene")
        ? r_msg2_main(manager, "embeddedDisplayWindowScene", 0, 0, 0, 0) : 0;
    uint64_t cc = r_is_objc_ptr(scene) && r_responds_main(scene, "controlCenterController")
        ? r_msg2_main(scene, "controlCenterController", 0, 0, 0, 0) : 0;
    if (!r_is_objc_ptr(cc)) cc = r_msg2_main(r_class("SBControlCenterController"), "sharedInstanceIfExists", 0, 0, 0, 0);
    uint64_t vc = r_is_objc_ptr(cc) && r_responds_main(cc, "viewController") ? r_msg2_main(cc, "viewController", 0, 0, 0, 0) : 0;
    if (!r_is_objc_ptr(vc) && r_is_objc_ptr(cc)) vc = r_ivar_value(cc, "_viewController");
    bool loaded = r_is_objc_ptr(vc) && r_msg2_main(vc, "isViewLoaded", 0, 0, 0, 0);
    uint64_t window = r_is_objc_ptr(cc) ? r_ivar_value(cc, "_window") : 0;
    printf("[SBMAT] Control Center: controller=%d viewController=%d viewLoaded=%d window=%d\n",
           r_is_objc_ptr(cc), r_is_objc_ptr(vc), loaded, r_is_objc_ptr(window));
    int n = sbmat_reload_views_under(loaded ? r_msg2_main(vc, "view", 0, 0, 0, 0) : 0, names, "Control Center view", false);
    if (!n && r_is_objc_ptr(window)) sbmat_reload_views_under(window, names, "Control Center window", false);
}

// The blur behind the app switcher (and over the Home Screen): one
// long-lived SBHomeScreenBackdropView with its own material view and a
// blurred snapshot it reuses.
static void sbmat_reload_home_backdrop(NSSet<NSString *> *names)
{
    uint64_t ui = r_msg2_main(r_class("SBUIController"), "sharedInstance", 0, 0, 0, 0);
    uint64_t backdrop = r_is_objc_ptr(ui) ? r_ivar_value(ui, "_homeScreenBackdropView") : 0;
    uint64_t material = r_is_objc_ptr(backdrop) ? r_ivar_value(backdrop, "_materialView") : 0;
    NSString *recipe = r_is_objc_ptr(material) ? sbmat_recipe_name(r_msg2_main(material, "layer", 0, 0, 0, 0)) : nil;
    bool reloaded = recipe && [names containsObject:recipe] && sbmat_reload_view(material, true);
    if (r_is_objc_ptr(backdrop) && r_responds_main(backdrop, "_invalidateBackdropSnapshot"))
        r_msg2_main(backdrop, "_invalidateBackdropSnapshot", 0, 0, 0, 0);
    printf("[SBMAT] home screen backdrop: %s, material %s (%s)\n", r_is_objc_ptr(backdrop) ? "found" : "not found",
           reloaded ? "reloaded" : "not reloaded", (recipe ?: @"none yet").UTF8String);
}

#pragma mark - Items and apply

NSString * const kSBMatConfigKey = @"CYSpringBoardToolsConfig";

static const SBMatItem kSBMatItems[] = {
    { "dock",         "Dock",                   "dock.rectangle",              "dockDark,dockLight", 30, false },
    { "folder",       "Folder Background",      "folder",                      "folderDark,folderLight,folderDarkSimplified,folderLightSimplified", 30, false },
    { "folderBlur",   "Folder Blur",            "folder.circle",               "folderExpandedBackgroundHome,folderExpandedBackgroundHomeSimplified,homeScreenOverlay", 9, false },
    { "ccModules",    "Control Center Modules", "switch.2",                    "modulesSheer", 15, false },
    { "ccBackground", "Control Center Blur",    "square.on.square",            "modulesBackground", 25, true },
    { "switcher",     "App Switcher Blur",      "apps.iphone",                 "homeScreenBackdrop-application", 20, false },
    { "notifications","Notification Banners",   "platter.filled.top.iphone",   "platters,plattersDark", 30, false },
    { NULL, NULL, NULL, NULL, 0, false },
};

const SBMatItem *sbmat_items(void) { return kSBMatItems; }

static NSArray<NSString *> *sbmat_item_recipes(const SBMatItem *item)
{
    return [@(item->recipes) componentsSeparatedByString:@","];
}

bool sbmat_apply_in_session(NSDictionary<NSString *, NSDictionary *> *config, NSString **why)
{
    __autoreleasing NSString *dummy = nil;
    if (!why) why = &dummy;

    // Our recipes, and every name we manage (Visible ones get Apple's back).
    NSMutableArray<NSString *> *allNames = [NSMutableArray array];
    NSMutableSet<NSString *> *disabled = [NSMutableSet set];
    NSMutableDictionary<NSString *, NSData *> *files = [NSMutableDictionary dictionary];
    for (const SBMatItem *item = kSBMatItems; item->key; item++) {
        NSDictionary *c = [config[@(item->key)] isKindOfClass:NSDictionary.class] ? config[@(item->key)] : nil;
        SBMatMode mode = (SBMatMode)[c[@"mode"] integerValue];
        NSArray *rgba = [c[@"color"] isKindOfClass:NSArray.class] ? c[@"color"] : nil;
        double blur = c[@"blur"] ? [c[@"blur"] doubleValue] : item->defaultBlur;
        printf("[SBMAT] %s: %s%s\n", item->key, mode == SBMatModeColor ? "Color" : mode == SBMatModeDisabled ? "Disabled" : "Visible",
               mode == SBMatModeColor ? [[NSString stringWithFormat:@" blur=%.0f tint=%@", blur,
                                          [rgba componentsJoinedByString:@","] ?: @"default"] UTF8String] : "");

        if (mode == SBMatModeDisabled) [disabled addObjectsFromArray:sbmat_item_recipes(item)];
        for (NSString *name in sbmat_item_recipes(item)) {
            [allNames addObject:name];
            if (mode == SBMatModeVisible) continue;
            NSData *data = sbmat_edited_recipe(name, mode, rgba, blur, item->plainTint);
            if (data) { files[[name stringByAppendingPathExtension:@"materialrecipe"]] = data; continue; }
            // A descendant recipe: ours points at an edited copy of its
            // ancestor (under our own name) and keeps Apple's changes --
            // for Control Center's modulesSheer those make 25 module blurs
            // cheap (backdropScale 0.05, low quality); without them
            // dismissing Control Center got slow. Only the blur radius is ours.
            NSDictionary *desc = sbmat_system_descendant(name);
            NSString *ancestor = [desc[@"ancestorRecipe"] isKindOfClass:NSString.class] ? desc[@"ancestorRecipe"] : nil;
            NSData *base = ancestor ? sbmat_edited_recipe(ancestor, mode, rgba, blur, item->plainTint) : nil;
            if (!base) { printf("[SBMAT] %s: not on this iOS version, skipped\n", name.UTF8String); continue; }
            printf("[SBMAT] %s: descendant of %s, original: %s\n", name.UTF8String, ancestor.UTF8String,
                   [[desc.description componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet] componentsJoinedByString:@" "].UTF8String);
            NSString *ours = [@"cyanide-" stringByAppendingString:name];
            files[[ours stringByAppendingPathExtension:@"materialrecipe"]] = base;
            NSMutableDictionary *changes = [desc[@"descendantDescription"] isKindOfClass:NSDictionary.class]
                ? [desc[@"descendantDescription"] mutableCopy] : [NSMutableDictionary dictionary];
            NSMutableDictionary *dBase = [changes[@"baseMaterial"] isKindOfClass:NSDictionary.class]
                ? [changes[@"baseMaterial"] mutableCopy] : [NSMutableDictionary dictionary];
            NSMutableDictionary *dFilter = [dBase[@"materialFiltering"] isKindOfClass:NSDictionary.class]
                ? [dBase[@"materialFiltering"] mutableCopy] : [NSMutableDictionary dictionary];
            dFilter[@"blurRadius"] = mode == SBMatModeDisabled ? @0 : @(isfinite(blur) ? MIN(MAX(blur, 0), 100) : 0);
            if (mode == SBMatModeDisabled) [dFilter removeObjectForKey:@"backdropScale"];
            dBase[@"materialFiltering"] = dFilter;
            [dBase removeObjectForKey:@"tinting"];
            changes[@"baseMaterial"] = dBase;
            files[[name stringByAppendingPathExtension:@"descendantrecipe"]] =
                [NSPropertyListSerialization dataWithPropertyList:@{ @"ancestorRecipe": ours, @"descendantDescription": changes }
                                                           format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
        }
    }

    uint64_t slot = sbmat_cache_slot(@"dockDark");
    uint64_t cache = slot ? remote_read64(slot) : 0;
    if (!r_is_objc_ptr(cache) || !r_msg2(cache, "isKindOfClass:", r_class("NSDictionary"), 0, 0, 0)) {
        printf("[SBMAT] recipe cache: %s\n", slot ? "not a dictionary in SpringBoard" : "not found");
        *why = @"CoreMaterial's recipe cache wasn't found. Check the log.";
        return false;
    }
    uint64_t bundleCls = r_class("NSBundle");
    if (!r_responds(bundleCls, "_setCoreMaterialOverrideRecipeBundleURL:")) {
        *why = @"This iOS version has no CoreMaterial override.";
        return false;
    }
    // Which recipes SpringBoard has used so far (open Control Center etc.
    // first to see theirs).
    uint64_t keys = r_msg2_main(cache, "allKeys", 0, 0, 0, 0);
    uint64_t sep = r_cfstr(", ");
    uint64_t joined = r_is_objc_ptr(keys) ? r_msg2_main(keys, "componentsJoinedByString:", sep, 0, 0, 0) : 0;
    sbmat_cfrelease(sep);
    char list[1600] = {0};
    if (r_is_objc_ptr(joined)) r_read_nsstring(joined, list, sizeof(list));
    printf("[SBMAT] recipes SpringBoard has used: %s\n", list);

    // 1. The override folder (a new one each time: NSBundle caches a
    //    folder's contents), or none.
    static char previousDir[256];
    uint64_t url = 0, dir = 0;
    if (files.count) {
        dir = sbmat_write_folder(files);
        url = dir ? r_msg2(r_class("NSURL"), "fileURLWithPath:", dir, 0, 0, 0) : 0;
        if (!r_is_objc_ptr(url)) {
            if (dir) r_release(dir);
            *why = @"The recipes couldn't be written for SpringBoard.";
            return false;
        }
    }
    r_msg2_main(bundleCls, "_setCoreMaterialOverrideRecipeBundleURL:", url, 0, 0, 0);
    uint64_t fm = r_msg2(r_class("NSFileManager"), "defaultManager", 0, 0, 0, 0);
    if (previousDir[0]) {
        uint64_t old = r_cfstr(previousDir);
        r_msg2(fm, "removeItemAtPath:error:", old, 0, 0, 0);
        sbmat_cfrelease(old);
        previousDir[0] = 0;
    }
    if (dir) {
        r_read_nsstring(dir, previousDir, sizeof(previousDir));
        r_release(dir);
    }

    // 2. Forget every managed recipe, 3. load ours into the cache through a
    //    layer without a bundle (so the override folder is found).
    for (NSString *name in allNames) {
        uint64_t key = r_cfstr(name.UTF8String);
        r_msg2_main(cache, "removeObjectForKey:", key, 0, 0, 0);
        sbmat_cfrelease(key);
    }
    if (files.count) {
        uint64_t layerCls = r_class("MTMaterialLayer");
        uint64_t probe = r_is_objc_ptr(layerCls) ? r_msg2_main(r_msg2_main(layerCls, "alloc", 0, 0, 0, 0), "init", 0, 0, 0, 0) : 0;
        if (!r_is_objc_ptr(probe)) { *why = @"CoreMaterial couldn't load the recipes."; return false; }
        for (NSString *file in files) {
            uint64_t key = r_cfstr(file.stringByDeletingPathExtension.UTF8String);
            r_msg2_main(probe, "setRecipeName:", key, 0, 0, 0);
            bool loaded = r_msg2_main(cache, "objectForKey:", key, 0, 0, 0) != 0;
            sbmat_cfrelease(key);
            printf("[SBMAT] %s: %s\n", file.stringByDeletingPathExtension.UTF8String, loaded ? "ours" : "not loaded");
        }
        r_release(probe);
    }

    // 4. Views that already exist: the dock, Control Center (once opened)
    //    and the Home Screen backdrop behind the app switcher. Folders and
    //    banners are made when needed and get the new recipes from the cache.
    g_sbmat_disabled = [disabled copy];
    uint64_t dockView = sbmat_dock_material_view();
    bool dockOK = dockView && sbmat_reload_view(dockView, true);
    NSSet<NSString *> *managed = [NSSet setWithArray:allNames];
    sbmat_reload_folder_icons(managed);
    sbmat_reload_control_center(managed);
    sbmat_reload_home_backdrop(managed);
    printf("[SBMAT] applied: %lu recipe(s) changed, dock %s\n", (unsigned long)files.count,
           dockOK ? "reloaded" : dockView ? "not reloaded" : "not found");
    return true;
}
