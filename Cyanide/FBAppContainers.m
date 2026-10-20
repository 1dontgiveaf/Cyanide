//
//  FBAppContainers.m
//  Cyanide
//

#import "FBAppContainers.h"
#import "SettingsViewController.h"

static NSString * const kBundleParent      = @"/private/var/containers/Bundle/Application";
static NSString * const kDataParent        = @"/private/var/mobile/Containers/Data/Application";
static NSString * const kAppGroupParent    = @"/private/var/mobile/Containers/Shared/AppGroup";
static NSString * const kPluginParent      = @"/private/var/mobile/Containers/Data/PluginKitPlugin";
static NSString * const kSystemGroupParent = @"/private/var/containers/Shared/SystemGroup";
static NSString * const kMetadataName      = @".com.apple.mobile_container_manager.metadata.plist";

@interface FBAppContainer ()
@property (nonatomic) FBContainerKind kind;
@property (nonatomic, copy) NSString *path;
@property (nonatomic, copy) NSString *identifier;
@property (nonatomic, copy) NSString *displayName;
@property (nonatomic, strong) UIImage *icon;
@property (nonatomic) BOOL viaRoot;   // metadata was read through launchd root
@property (nonatomic, copy) NSString *executableName;
@property (nonatomic) BOOL systemApp;
@end

@implementation FBAppContainer
@end

// One installed app: where its .app is, its name and icon.
@interface FBAppRecord : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *appPath;        // the .app bundle
@property (nonatomic, copy) NSString *bundleContainer;  // nil for system apps in /Applications
@property (nonatomic, copy) NSString *executable;       // CFBundleExecutable
@property (nonatomic, strong) UIImage *icon;           // loaded on first use
@property (nonatomic) BOOL iconLoaded;
@end
@implementation FBAppRecord
@end

static NSMutableDictionary<NSString *, FBAppContainer *> *g_containers;   // canonical path -> container
static NSDictionary<NSString *, FBAppRecord *> *g_apps;                   // bundle id -> app
static NSMutableDictionary<NSString *, NSString *> *g_dataByBundleID;      // bundle id -> data container
static BOOL g_dataIndexed;
static NSUInteger g_cacheGeneration;

static NSObject *fb_containers_lock(void)
{
    static NSObject *lock;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ lock = [NSObject new]; });
    return lock;
}

NSString *fb_canonical_path(NSString *path)
{
    NSString *p = path.stringByStandardizingPath;
    if ([p isEqualToString:@"/var"] || [p hasPrefix:@"/var/"]) p = [@"/private" stringByAppendingString:p];
    return p;
}

static NSArray<NSString *> *fb_container_parents(void)
{
    return @[ kBundleParent, kDataParent, kAppGroupParent, kPluginParent, kSystemGroupParent ];
}

BOOL fb_is_container_parent(NSString *dir)
{
    return [fb_container_parents() containsObject:fb_canonical_path(dir)];
}

static NSDictionary *fb_read_plist(NSString *path, BOOL viaRoot)
{
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data && viaRoot && settings_filesystem_access_available())
        data = settings_root_read_file(path, 256 * 1024, NULL, NULL);
    if (!data) return nil;
    id plist = [NSPropertyListSerialization propertyListWithData:data options:0 format:NULL error:nil];
    return [plist isKindOfClass:NSDictionary.class] ? plist : nil;
}

// The home screen icon at row size: the largest AppIcon/Icon PNG in the
// bundle (most apps still ship them besides the asset catalog), else what
// iOS hands out for the bundle ID.
static UIImage *fb_app_icon(NSString *appPath, NSString *bundleID)
{
    NSDictionary *info = fb_read_plist([appPath stringByAppendingPathComponent:@"Info.plist"], NO);
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    // Any level can be malformed in a third-party Info.plist: check each type.
    NSDictionary *icons = [info[@"CFBundleIcons"] isKindOfClass:NSDictionary.class] ? info[@"CFBundleIcons"] : nil;
    NSDictionary *primary = [icons[@"CFBundlePrimaryIcon"] isKindOfClass:NSDictionary.class] ? icons[@"CFBundlePrimaryIcon"] : nil;
    NSArray *files = primary[@"CFBundleIconFiles"];
    if ([files isKindOfClass:NSArray.class]) [names addObjectsFromArray:files];
    NSString *iconName = primary[@"CFBundleIconName"];
    if ([iconName isKindOfClass:NSString.class]) [names addObject:iconName];
    UIImage *best = nil;
    for (NSString *file in [NSFileManager.defaultManager contentsOfDirectoryAtPath:appPath error:nil]) {
        if (![file.pathExtension.lowercaseString isEqualToString:@"png"]) continue;
        BOOL match = [file hasPrefix:@"AppIcon"] || [file hasPrefix:@"Icon"];
        for (NSString *n in names) if ([n isKindOfClass:NSString.class] && [file hasPrefix:n]) match = YES;
        if (!match) continue;
        UIImage *img = [UIImage imageWithContentsOfFile:[appPath stringByAppendingPathComponent:file]];
        if (img && img.size.width * img.scale > best.size.width * best.scale) best = img;
    }
    if (!best && bundleID) {
        SEL sel = NSSelectorFromString(@"_applicationIconImageForBundleIdentifier:format:scale:");
        if ([UIImage respondsToSelector:sel]) {
            UIImage *(*fn)(id, SEL, NSString *, int, CGFloat) = (void *)[UIImage methodForSelector:sel];
            best = fn(UIImage.class, sel, bundleID, 2, UIScreen.mainScreen.scale);
        }
    }
    if (!best) return nil;
    CGFloat side = 29;
    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(side, side)];
    return [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(0, 0, side, side) cornerRadius:side * 0.225] addClip];
        [best drawInRect:CGRectMake(0, 0, side, side)];
    }];
}

static FBAppRecord *fb_app_record_for_app(NSString *appPath, NSString *container, NSString **bundleIDOut)
{
    NSDictionary *info = fb_read_plist([appPath stringByAppendingPathComponent:@"Info.plist"], NO);
    NSString *bid = info[@"CFBundleIdentifier"];
    if (![bid isKindOfClass:NSString.class] || !bid.length) return nil;
    FBAppRecord *app = [FBAppRecord new];
    NSString *name = info[@"CFBundleDisplayName"];
    if (![name isKindOfClass:NSString.class] || !name.length) name = info[@"CFBundleName"];
    app.name = [name isKindOfClass:NSString.class] && name.length ? name
                                                                  : appPath.lastPathComponent.stringByDeletingPathExtension;
    app.appPath = appPath;
    app.bundleContainer = container;
    NSString *exe = info[@"CFBundleExecutable"];
    app.executable = [exe isKindOfClass:NSString.class] && exe.length ? exe : nil;
    *bundleIDOut = bid;
    return app;
}

// Safety callers must not use a cached executable or accept an Info.plist
// from a different bundle. This deliberately does not load an icon: Cleaner
// already has the display icon from its ordinary container cache.
static BOOL fb_current_bundle_metadata_matches(NSString *expectedIdentifier,
                                                NSDictionary *info,
                                                NSString **executableOut)
{
    NSString *identifier = info[@"CFBundleIdentifier"];
    NSString *executable = info[@"CFBundleExecutable"];
    if (![expectedIdentifier isKindOfClass:NSString.class] || !expectedIdentifier.length ||
        ![identifier isKindOfClass:NSString.class] || ![identifier isEqualToString:expectedIdentifier] ||
        ![executable isKindOfClass:NSString.class] || !executable.length) return NO;
    if (executableOut) *executableOut = executable;
    return YES;
}

static NSString *fb_app_in_container(NSString *container)
{
    for (NSString *item in [NSFileManager.defaultManager contentsOfDirectoryAtPath:container error:nil])
        if ([item.pathExtension isEqualToString:@"app"]) return [container stringByAppendingPathComponent:item];
    return nil;
}

// Installed apps (bundle containers) and system apps (/Applications), by
// bundle identifier. Round 53: built OUTSIDE the lock (pure file I/O — every
// /Applications and bundle-container Info.plist) with a double-checked
// publish, so the one-time index build no longer stalls the File Browser
// behind fb_containers_lock. Self-locking; callers hold nothing.
static NSDictionary<NSString *, FBAppRecord *> *fb_apps_index(void)
{
    for (;;) {
        NSUInteger generation;
        @synchronized (fb_containers_lock()) {
            if (g_apps) return g_apps;
            generation = g_cacheGeneration;
        }

        NSMutableDictionary *apps = [NSMutableDictionary dictionary];
        NSFileManager *fm = NSFileManager.defaultManager;
        for (NSString *item in [fm contentsOfDirectoryAtPath:@"/Applications" error:nil]) {
            if (![item.pathExtension isEqualToString:@".app"]) continue;
            NSString *bid = nil;
            FBAppRecord *app = fb_app_record_for_app([@"/Applications" stringByAppendingPathComponent:item], nil, &bid);
            if (app) apps[bid] = app;
        }
        for (NSString *uuid in [fm contentsOfDirectoryAtPath:kBundleParent error:nil]) {
            NSString *container = [kBundleParent stringByAppendingPathComponent:uuid];
            NSString *appPath = fb_app_in_container(container);
            NSString *bid = nil;
            FBAppRecord *app = appPath ? fb_app_record_for_app(appPath, container, &bid) : nil;
            if (app) apps[bid] = app;   // an installed copy wins over /Applications
        }
        @synchronized (fb_containers_lock()) {
            if (generation != g_cacheGeneration) continue;
            if (!g_apps) g_apps = apps;   // a concurrent build for this generation won; both are valid
            return g_apps;
        }
    }
}

static FBAppRecord *fb_current_app_record_for_identifier(NSString *identifier)
{
    if (![identifier isKindOfClass:NSString.class] || !identifier.length) return nil;

    // The cached path is only a lookup hint. Re-read its Info.plist and
    // require the bundle identifier to still match before trusting it.
    FBAppRecord *cached = fb_apps_index()[identifier];
    if (cached) {
        NSString *freshIdentifier = nil;
        FBAppRecord *fresh = fb_app_record_for_app(cached.appPath, cached.bundleContainer, &freshIdentifier);
        if (fresh && [freshIdentifier isEqualToString:identifier]) return fresh;
    }

    // A newly installed/replaced app may not be represented by the old index.
    // This fallback reads metadata only; it intentionally does not decode any
    // icons while refreshing a Cleaner safety decision.
    NSFileManager *fm = NSFileManager.defaultManager;
    for (NSString *uuid in [fm contentsOfDirectoryAtPath:kBundleParent error:nil]) {
        NSString *container = [kBundleParent stringByAppendingPathComponent:uuid];
        NSString *appPath = fb_app_in_container(container);
        NSString *freshIdentifier = nil;
        FBAppRecord *fresh = appPath ? fb_app_record_for_app(appPath, container, &freshIdentifier) : nil;
        if (fresh && [freshIdentifier isEqualToString:identifier]) return fresh;
    }
    for (NSString *item in [fm contentsOfDirectoryAtPath:@"/Applications" error:nil]) {
        if (![item.pathExtension isEqualToString:@".app"]) continue;
        NSString *freshIdentifier = nil;
        FBAppRecord *fresh = fb_app_record_for_app([@"/Applications" stringByAppendingPathComponent:item], nil,
                                                    &freshIdentifier);
        if (fresh && [freshIdentifier isEqualToString:identifier]) return fresh;
    }
    return nil;
}

// Round 53: the decode/render runs OUTSIDE the lock; only the cache
// check/store is synchronized (double-checked — a concurrent load wastes
// one decode at most). Self-locking; callers hold nothing.
static UIImage *fb_icon_for_app(FBAppRecord *app, NSString *bundleID)
{
    @synchronized (fb_containers_lock()) {
        if (app.iconLoaded) return app.icon;
    }
    UIImage *img = fb_app_icon(app.appPath, bundleID);
    @synchronized (fb_containers_lock()) {
        if (!app.iconLoaded) { app.icon = img; app.iconLoaded = YES; }
        return app.icon;
    }
}

// An extension's app: the installed app whose identifier is the longest
// prefix of the extension's ("com.foo.app.widget" -> "com.foo.app").
static NSString *fb_owner_app_id(NSString *identifier)
{
    NSString *best = nil;
    for (NSString *bid in fb_apps_index())
        if ([identifier hasPrefix:[bid stringByAppendingString:@"."]] && bid.length > best.length) best = bid;
    return best;
}

// Round 53: called WITHOUT the lock (fb_container_for_path builds outside
// it). All shared-state access goes through the self-locking helpers above;
// the returned container is caller-private until published into g_containers.
static FBAppContainer *fb_make_container(NSString *dir, FBContainerKind kind, BOOL viaRoot)
{
    NSDictionary *meta = fb_read_plist([dir stringByAppendingPathComponent:kMetadataName], viaRoot);
    NSString *identifier = meta[@"MCMMetadataIdentifier"];
    if (![identifier isKindOfClass:NSString.class]) identifier = nil;
    NSString *appPath = nil;
    if (kind == FBContainerKindBundle) {
        appPath = fb_app_in_container(dir);
        if (!identifier && appPath) {
            NSDictionary *info = fb_read_plist([appPath stringByAppendingPathComponent:@"Info.plist"], viaRoot);
            identifier = [info[@"CFBundleIdentifier"] isKindOfClass:NSString.class] ? info[@"CFBundleIdentifier"] : nil;
        }
    }
    if (!identifier) return nil;

    FBAppContainer *c = [FBAppContainer new];
    c.kind = kind;
    c.path = dir;
    c.identifier = identifier;
    c.viaRoot = viaRoot;
    NSDictionary<NSString *, FBAppRecord *> *apps = fb_apps_index();
    FBAppRecord *app = apps[identifier];
    if (kind == FBContainerKindPlugin && !app) {
        NSString *owner = fb_owner_app_id(identifier);
        FBAppRecord *ownerApp = owner ? apps[owner] : nil;
        if (ownerApp) {
            c.displayName = [NSString stringWithFormat:@"%@ (%@)", ownerApp.name,
                             [identifier substringFromIndex:owner.length + 1]];
            c.icon = fb_icon_for_app(ownerApp, owner);
            return c;
        }
    }
    if (app && (kind == FBContainerKindBundle || kind == FBContainerKindData || kind == FBContainerKindPlugin)) {
        c.displayName = app.name;
        c.icon = fb_icon_for_app(app, identifier);
        if (kind != FBContainerKindPlugin) {
            c.executableName = app.executable;
            c.systemApp = app.bundleContainer == nil;
        }
    } else {
        c.displayName = identifier;   // app groups, system groups, unknown apps
    }
    return c;
}

FBAppContainer *fb_container_for_path(NSString *path, BOOL viaRoot)
{
    NSString *p = fb_canonical_path(path);
    NSArray<NSString *> *parents = fb_container_parents();
    for (NSUInteger i = 0; i < parents.count; i++) {
        NSString *parent = [parents[i] stringByAppendingString:@"/"];
        if (![p hasPrefix:parent]) continue;
        NSString *uuid = [p substringFromIndex:parent.length].pathComponents.firstObject;
        if (!uuid.length) return nil;
        NSString *dir = [parents[i] stringByAppendingPathComponent:uuid];
        for (;;) {
            NSUInteger generation;
            @synchronized (fb_containers_lock()) {
                FBAppContainer *c = g_containers[dir];
                if (c) {
                    // Cached from a mobile-readable earlier lookup; related lookups
                    // may still need the root path.
                    if (viaRoot) c.viaRoot = YES;
                    return c;
                }
                generation = g_cacheGeneration;
            }

            // Round 53: build OUTSIDE the lock — plist reads, directory listings
            // and icon decode no longer stall the File Browser behind
            // fb_containers_lock — then publish only for the generation that
            // was observed before the build began.
            FBAppContainer *c = fb_make_container(dir, (FBContainerKind)i, viaRoot);
            if (!c) return nil;
            @synchronized (fb_containers_lock()) {
                if (generation != g_cacheGeneration) continue;
                if (!g_containers) g_containers = [NSMutableDictionary dictionary];
                FBAppContainer *existing = g_containers[dir];
                if (existing) {
                    if (viaRoot) existing.viaRoot = YES;
                    return existing;   // concurrent build won; both are valid
                }
                g_containers[dir] = c;
                return c;
            }
        }
    }
    return nil;
}

static FBAppContainer *fb_make_current_container(NSString *dir, FBContainerKind kind, BOOL viaRoot)
{
    NSDictionary *meta = fb_read_plist([dir stringByAppendingPathComponent:kMetadataName], viaRoot);
    NSString *identifier = meta[@"MCMMetadataIdentifier"];
    if (![identifier isKindOfClass:NSString.class] || !identifier.length) return nil;

    FBAppRecord *app = nil;
    if (kind == FBContainerKindBundle) {
        NSString *appPath = fb_app_in_container(dir);
        if (!appPath) return nil;
        NSDictionary *info = fb_read_plist([appPath stringByAppendingPathComponent:@"Info.plist"], viaRoot);
        NSString *executable = nil;
        if (!fb_current_bundle_metadata_matches(identifier, info, &executable)) return nil;
        NSString *freshIdentifier = nil;
        app = fb_app_record_for_app(appPath, dir, &freshIdentifier);
        if (!app || ![freshIdentifier isEqualToString:identifier]) return nil;
    } else if (kind == FBContainerKindData) {
        app = fb_current_app_record_for_identifier(identifier);
        if (!app) return nil;
        NSDictionary *info = fb_read_plist([app.appPath stringByAppendingPathComponent:@"Info.plist"], viaRoot);
        NSString *executable = nil;
        if (!fb_current_bundle_metadata_matches(identifier, info, &executable)) return nil;
    } else if (kind == FBContainerKindPlugin) {
        NSString *owner = fb_owner_app_id(identifier);
        app = owner ? fb_current_app_record_for_identifier(owner) : nil;
    }

    FBAppContainer *c = [FBAppContainer new];
    c.kind = kind;
    c.path = dir;
    c.identifier = identifier;
    c.viaRoot = viaRoot;
    c.icon = nil; // callers retain the ordinary cached icon; no rescan here
    if (app && (kind == FBContainerKindBundle || kind == FBContainerKindData || kind == FBContainerKindPlugin)) {
        c.displayName = app.name;
        if (kind != FBContainerKindPlugin) {
            c.executableName = app.executable;
            c.systemApp = app.bundleContainer == nil;
        }
    } else {
        c.displayName = identifier;
    }
    return c;
}

FBAppContainer *fb_current_container_for_path(NSString *path, BOOL viaRoot)
{
    NSString *p = fb_canonical_path(path);
    NSArray<NSString *> *parents = fb_container_parents();
    for (NSUInteger i = 0; i < parents.count; i++) {
        NSString *parent = [parents[i] stringByAppendingString:@"/"];
        if (![p hasPrefix:parent]) continue;
        NSString *uuid = [p substringFromIndex:parent.length].pathComponents.firstObject;
        if (!uuid.length) return nil;
        NSString *dir = [parents[i] stringByAppendingPathComponent:uuid];
        return fb_make_current_container(dir, (FBContainerKind)i, viaRoot);
    }
    return nil;
}

// Data containers by bundle identifier, read once on first use. viaRoot is
// passed through: a container whose metadata is only readable as root must not
// be permanently missing from the index. The index is marked complete only
// when the listing and every metadata read succeeded; an incomplete build is
// retried on the next lookup instead of caching the hole.
static NSString *fb_data_container_for_id(NSString *bundleID, BOOL viaRoot)
{
    for (;;) {
        NSUInteger generation;
        @synchronized (fb_containers_lock()) {
            if (g_dataIndexed) return g_dataByBundleID[bundleID];
            generation = g_cacheGeneration;
        }

        NSArray<NSString *> *uuids =
            [NSFileManager.defaultManager contentsOfDirectoryAtPath:kDataParent error:nil];
        if (!uuids) return nil;   // unavailable right now; do not cache an empty index
        NSMutableDictionary<NSString *, NSString *> *index = [NSMutableDictionary dictionary];
        BOOL complete = YES;
        for (NSString *uuid in uuids) {
            NSString *dir = [kDataParent stringByAppendingPathComponent:uuid];
            NSDictionary *meta = fb_read_plist([dir stringByAppendingPathComponent:kMetadataName], viaRoot);
            if (!meta) {
                complete = NO;
                continue;
            }
            NSString *bid = meta[@"MCMMetadataIdentifier"];
            if ([bid isKindOfClass:NSString.class]) index[bid] = dir;
        }
        @synchronized (fb_containers_lock()) {
            if (generation != g_cacheGeneration) continue;
            if (!g_dataIndexed) {
                g_dataByBundleID = index;
                g_dataIndexed = complete;
            }
            return g_dataByBundleID[bundleID];
        }
    }
}

FBAppContainer *fb_related_container(FBAppContainer *container)
{
    if (![container isKindOfClass:FBAppContainer.class]) return nil;
    NSString *target = nil;
    switch (container.kind) {
        case FBContainerKindBundle:
            target = fb_data_container_for_id(container.identifier, container.viaRoot);
            break;
        case FBContainerKindData:
            target = fb_apps_index()[container.identifier].bundleContainer;
            break;
        case FBContainerKindPlugin: {
            NSString *owner = fb_owner_app_id(container.identifier);
            target = owner ? fb_data_container_for_id(owner, container.viaRoot) : nil;
            break;
        }
        default:
            break;
    }
    return target ? fb_container_for_path(target, container.viaRoot) : nil;
}

NSArray<FBAppContainer *> *fb_app_data_containers(void)
{
    NSMutableArray<FBAppContainer *> *out = [NSMutableArray array];
    for (NSString *uuid in [NSFileManager.defaultManager contentsOfDirectoryAtPath:kDataParent error:nil]) {
        FBAppContainer *c = fb_container_for_path([kDataParent stringByAppendingPathComponent:uuid], NO);
        // Only containers of an app we can name (not leftovers or unknowns).
        if (c.kind == FBContainerKindData && c.executableName) [out addObject:c];
    }
    return out;
}

void fb_containers_reset(void)
{
    @synchronized (fb_containers_lock()) {
        g_cacheGeneration++;
        if (g_cacheGeneration == 0) g_cacheGeneration = 1;
        g_containers = nil;
        g_apps = nil;
        g_dataByBundleID = nil;
        g_dataIndexed = NO;
    }
}
