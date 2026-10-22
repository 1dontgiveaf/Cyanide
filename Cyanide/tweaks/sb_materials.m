//
//  sb_materials.m
//  Cyanide
//
//  See sb_materials.h. How CoreMaterial finds a recipe (iOS 18):
//  _SharedMaterialSettingsForRecipeWithNameFromBundle looks the name up in a
//  private cache (static NSMutableDictionary, name -> MTRecipeMaterialSettings),
//  and only on a miss loads <name>.materialrecipe -- from the override bundle
//  first, then the system bundle, per file. So the override folder only needs
//  the recipes we change, but recipes SpringBoard already loaded (the dock,
//  folders) stay cached until their entries are removed.
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

// The system's <name>.materialrecipe, as CoreMaterial itself finds it.
static NSURL *sbmat_system_recipe_url(NSString *name)
{
    if (!sbmat_load_corematerial()) return nil;
    SEL bundleSel = sel_registerName("coreMaterialRecipeBundle"), urlSel = sel_registerName("URLForMaterialRecipe:");
    if (![NSBundle respondsToSelector:bundleSel]) return nil;
    NSBundle *bundle = ((id (*)(id, SEL))objc_msgSend)(NSBundle.class, bundleSel);
    if (![bundle respondsToSelector:urlSel]) return nil;
    return ((id (*)(id, SEL, id))objc_msgSend)(bundle, urlSel, name);
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

// The recipe with its materialFiltering replaced: no blur, and either no
// tint (off, the backdrop shows through) or a strong red tint (test: makes it
// obvious whether our recipe is used at all). materialSettingsVersion stays:
// it tells CoreMaterial which format the file is in.
static NSData *sbmat_edited_recipe(NSString *name, int mode, NSString **why)
{
    NSURL *url = sbmat_system_recipe_url(name);
    NSData *data = url ? [NSData dataWithContentsOfURL:url] : nil;
    NSDictionary *plist = data ? [NSPropertyListSerialization propertyListWithData:data options:0 format:NULL error:nil] : nil;
    if (![plist isKindOfClass:NSDictionary.class]) {
        *why = [NSString stringWithFormat:@"%@.materialrecipe wasn't found", name];
        return nil;
    }
    printf("[SBMAT] %s original: %s\n", name.UTF8String,
           [[plist.description stringByReplacingOccurrencesOfString:@"\n" withString:@" "] UTF8String]);
    NSMutableDictionary *changed = [plist mutableCopy];
    NSMutableDictionary *base = [plist[@"baseMaterial"] isKindOfClass:NSDictionary.class] ? [plist[@"baseMaterial"] mutableCopy]
                                                                                       : [NSMutableDictionary dictionary];
    NSMutableDictionary *filtering = [NSMutableDictionary dictionaryWithDictionary:@{ @"blurRadius": @0 }];
    if (mode == 2) {
        filtering[@"tinting"] = @{ @"tintAlpha": @0.8,
                                   @"tintColor": @{ @"alpha": @1.0, @"red": @1.0, @"green": @0.0, @"blue": @0.0 } };
    }
    base[@"materialFiltering"] = filtering;
    changed[@"baseMaterial"] = base;
    printf("[SBMAT] %s edited: %s\n", name.UTF8String,
           [[changed.description stringByReplacingOccurrencesOfString:@"\n" withString:@" "] UTF8String]);
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

static NSString *sbmat_class_name(uint64_t obj)
{
    uint64_t name = r_is_objc_ptr(obj) ? r_dlsym_call(R_TIMEOUT, "object_getClassName", obj, 0, 0, 0, 0, 0, 0, 0) : 0;
    char buf[96] = {0};
    return name && remote_read(name, buf, sizeof(buf) - 1) ? @(buf) : @"?";
}

static NSString *sbmat_recipe_name(uint64_t layer)
{
    uint64_t rn = r_is_objc_ptr(layer) && r_responds_main(layer, "recipeName")
        ? r_msg2_main(layer, "recipeName", 0, 0, 0, 0) : 0;
    char buf[128] = {0};
    return r_is_objc_ptr(rn) && r_read_nsstring(rn, buf, sizeof(buf)) ? @(buf) : nil;
}

// The dock's material layer, straight from the home screen's view
// controllers (no view walk). 0 when not found.
static uint64_t sbmat_dock_material_layer(void)
{
    uint64_t ctrl = r_msg2_main(r_class("SBIconController"), "sharedInstance", 0, 0, 0, 0);
    uint64_t mgr = r_is_objc_ptr(ctrl) ? r_msg2_main(ctrl, "iconManager", 0, 0, 0, 0) : 0;
    uint64_t root = r_is_objc_ptr(mgr) ? r_msg2_main(mgr, "rootFolderController", 0, 0, 0, 0) : 0;
    uint64_t rootView = r_is_objc_ptr(root) ? r_msg2_main(root, "rootFolderView", 0, 0, 0, 0) : 0;
    uint64_t dock = r_is_objc_ptr(rootView) && r_responds_main(rootView, "dockView")
        ? r_msg2_main(rootView, "dockView", 0, 0, 0, 0) : 0;
    uint64_t bg = r_is_objc_ptr(dock) && r_responds_main(dock, "backgroundView")
        ? r_msg2_main(dock, "backgroundView", 0, 0, 0, 0) : 0;
    uint64_t layer = r_is_objc_ptr(bg) ? r_msg2_main(bg, "layer", 0, 0, 0, 0) : 0;
    printf("[SBMAT] dock: controller=%d manager=%d root=%d rootView=%d dockView=%s background=%s layer=%s recipe=%s\n",
           r_is_objc_ptr(ctrl), r_is_objc_ptr(mgr), r_is_objc_ptr(root), r_is_objc_ptr(rootView),
           sbmat_class_name(dock).UTF8String, sbmat_class_name(bg).UTF8String, sbmat_class_name(layer).UTF8String,
           (sbmat_recipe_name(layer) ?: @"-").UTF8String);
    return r_is_objc_ptr(layer) && r_responds_main(layer, "setRecipeName:") ? layer : 0;
}

bool sbmat_dock_test_in_session(int mode, NSString **why)
{
    __autoreleasing NSString *dummy = nil;
    if (!why) why = &dummy;
    NSArray<NSString *> *names = @[ @"dockDark", @"dockLight" ];

    uint64_t slot = sbmat_cache_slot(names[0]);
    if (!slot) { *why = @"CoreMaterial's recipe cache wasn't found."; return false; }
    uint64_t cache = remote_read64(slot);
    BOOL cacheOK = r_is_objc_ptr(cache) && r_msg2(cache, "isKindOfClass:", r_class("NSDictionary"), 0, 0, 0);
    uint64_t count = cacheOK ? r_msg2(cache, "count", 0, 0, 0, 0) : 0;
    printf("[SBMAT] SpringBoard recipe cache 0x%llx: %s, %llu recipes\n", cache, cacheOK ? "ok" : "not a dictionary", count);
    if (!cacheOK) { *why = @"SpringBoard's recipe cache wasn't found."; return false; }

    bool disable = mode != 0;
    uint64_t url = 0, dir = 0;
    if (disable) {
        NSMutableDictionary<NSString *, NSData *> *files = [NSMutableDictionary dictionary];
        for (NSString *name in names) {
            NSData *data = sbmat_edited_recipe(name, mode, why);
            if (!data) return false;
            files[[name stringByAppendingPathExtension:@"materialrecipe"]] = data;
        }
        dir = sbmat_write_folder(files);
        if (!dir) { *why = @"The edited recipes couldn't be written for SpringBoard."; return false; }
        url = r_msg2(r_class("NSURL"), "fileURLWithPath:", dir, 0, 0, 0);
        if (!r_is_objc_ptr(url)) { r_release(dir); *why = @"No URL for the recipe folder."; return false; }
    }
    uint64_t bundleCls = r_class("NSBundle");
    if (!r_responds(bundleCls, "_setCoreMaterialOverrideRecipeBundleURL:")) {
        if (dir) r_release(dir);
        *why = @"This iOS version has no CoreMaterial override.";
        return false;
    }
    r_msg2_main(bundleCls, "_setCoreMaterialOverrideRecipeBundleURL:", url, 0, 0, 0);
    uint64_t now = r_msg2_main(bundleCls, "coreMaterialOverrideRecipeBundleURL", 0, 0, 0, 0);
    printf("[SBMAT] override folder %s\n", r_is_objc_ptr(now) ? "set" : "cleared");
    if (dir) r_release(dir);

    for (NSString *name in names) {
        uint64_t key = r_cfstr(name.UTF8String);
        uint64_t had = r_msg2_main(cache, "objectForKey:", key, 0, 0, 0);
        r_msg2_main(cache, "removeObjectForKey:", key, 0, 0, 0);
        printf("[SBMAT] cache entry %s: %s\n", name.UTF8String, had ? "removed" : "wasn't loaded");
        sbmat_cfrelease(key);
    }
    // Load the recipe again: the cache misses now and finds ours first.
    uint64_t layer = sbmat_dock_material_layer();
    NSString *recipe = layer ? sbmat_recipe_name(layer) : nil;
    if (!recipe) { *why = @"The dock's background wasn't found. Check the log."; return false; }
    uint64_t str = r_cfstr(recipe.UTF8String);
    uint64_t before = r_msg2_main(layer, "_recipeSettings", 0, 0, 0, 0);
    r_msg2_main(layer, "setRecipeName:", str, 0, 0, 0);
    uint64_t after = r_msg2_main(layer, "_recipeSettings", 0, 0, 0, 0);
    uint64_t cached = r_msg2_main(cache, "objectForKey:", str, 0, 0, 0);
    sbmat_cfrelease(str);
    // What the layer now uses, and a forced reconfigure in case it waits for one.
    uint64_t desc = r_is_objc_ptr(after) ? r_msg2_main(after, "description", 0, 0, 0, 0) : 0;
    char text[700] = {0};
    if (r_is_objc_ptr(desc) && r_read_nsstring(desc, text, sizeof(text))) {
        for (char *c = text; *c; c++) if (*c == '\n') *c = ' ';
        printf("[SBMAT] dock settings now: %s\n", text);
    }
    if (r_responds_main(layer, "_updateForChangeInRecipeAndConfiguration"))
        r_msg2_main(layer, "_updateForChangeInRecipeAndConfiguration", 0, 0, 0, 0);
    r_msg2_main(layer, "setNeedsLayout", 0, 0, 0, 0);
    r_msg2_main(layer, "setNeedsDisplay", 0, 0, 0, 0);
    printf("[SBMAT] dock mode %d: recipe %s reloaded, settings %s (cache %s)\n", mode,
           recipe.UTF8String, before != after ? "replaced" : "unchanged", cached ? "refilled" : "empty");
    if (before == after) *why = @"The recipe was replaced, but the dock didn't reload it. Check the log.";
    return before != after;
}
