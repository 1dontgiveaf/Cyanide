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
@end

@implementation FBAppContainer
@end

// One installed app: where its .app is, its name and icon.
@interface FBAppRecord : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *appPath;        // the .app bundle
@property (nonatomic, copy) NSString *bundleContainer;  // nil for system apps in /Applications
@property (nonatomic, strong) UIImage *icon;           // loaded on first use
@property (nonatomic) BOOL iconLoaded;
@end
@implementation FBAppRecord
@end

static NSMutableDictionary<NSString *, FBAppContainer *> *g_containers;   // canonical path -> container
static NSDictionary<NSString *, FBAppRecord *> *g_apps;                   // bundle id -> app
static NSMutableDictionary<NSString *, NSString *> *g_dataByBundleID;      // bundle id -> data container
static BOOL g_dataIndexed;

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
    NSArray *files = info[@"CFBundleIcons"][@"CFBundlePrimaryIcon"][@"CFBundleIconFiles"];
    if ([files isKindOfClass:NSArray.class]) [names addObjectsFromArray:files];
    NSString *iconName = info[@"CFBundleIcons"][@"CFBundlePrimaryIcon"][@"CFBundleIconName"];
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
    *bundleIDOut = bid;
    return app;
}

static NSString *fb_app_in_container(NSString *container)
{
    for (NSString *item in [NSFileManager.defaultManager contentsOfDirectoryAtPath:container error:nil])
        if ([item.pathExtension isEqualToString:@"app"]) return [container stringByAppendingPathComponent:item];
    return nil;
}

// Installed apps (bundle containers) and system apps (/Applications), by
// bundle identifier. Built once; caller holds the lock.
static NSDictionary<NSString *, FBAppRecord *> *fb_apps_locked(void)
{
    if (g_apps) return g_apps;
    NSMutableDictionary *apps = [NSMutableDictionary dictionary];
    NSFileManager *fm = NSFileManager.defaultManager;
    for (NSString *item in [fm contentsOfDirectoryAtPath:@"/Applications" error:nil]) {
        if (![item.pathExtension isEqualToString:@"app"]) continue;
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
    g_apps = apps;
    return g_apps;
}

static UIImage *fb_icon_for_app_locked(FBAppRecord *app, NSString *bundleID)
{
    if (!app.iconLoaded) {
        app.icon = fb_app_icon(app.appPath, bundleID);
        app.iconLoaded = YES;
    }
    return app.icon;
}

// An extension's app: the installed app whose identifier is the longest
// prefix of the extension's ("com.foo.app.widget" -> "com.foo.app").
static NSString *fb_owner_app_id_locked(NSString *identifier)
{
    NSString *best = nil;
    for (NSString *bid in fb_apps_locked())
        if ([identifier hasPrefix:[bid stringByAppendingString:@"."]] && bid.length > best.length) best = bid;
    return best;
}

static FBAppContainer *fb_make_container_locked(NSString *dir, FBContainerKind kind, BOOL viaRoot)
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
    NSDictionary<NSString *, FBAppRecord *> *apps = fb_apps_locked();
    FBAppRecord *app = apps[identifier];
    if (kind == FBContainerKindPlugin && !app) {
        NSString *owner = fb_owner_app_id_locked(identifier);
        FBAppRecord *ownerApp = owner ? apps[owner] : nil;
        if (ownerApp) {
            c.displayName = [NSString stringWithFormat:@"%@ (%@)", ownerApp.name,
                             [identifier substringFromIndex:owner.length + 1]];
            c.icon = fb_icon_for_app_locked(ownerApp, owner);
            return c;
        }
    }
    if (app && (kind == FBContainerKindBundle || kind == FBContainerKindData || kind == FBContainerKindPlugin)) {
        c.displayName = app.name;
        c.icon = fb_icon_for_app_locked(app, identifier);
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
        @synchronized (fb_containers_lock()) {
            if (!g_containers) g_containers = [NSMutableDictionary dictionary];
            FBAppContainer *c = g_containers[dir];
            if (!c) {
                c = fb_make_container_locked(dir, (FBContainerKind)i, viaRoot);
                if (c) g_containers[dir] = c;
            }
            return c;
        }
    }
    return nil;
}

// Data containers by bundle identifier, read once on first use.
static NSString *fb_data_container_for_id_locked(NSString *bundleID)
{
    if (!g_dataIndexed) {
        g_dataByBundleID = [NSMutableDictionary dictionary];
        for (NSString *uuid in [NSFileManager.defaultManager contentsOfDirectoryAtPath:kDataParent error:nil]) {
            NSString *dir = [kDataParent stringByAppendingPathComponent:uuid];
            NSDictionary *meta = fb_read_plist([dir stringByAppendingPathComponent:kMetadataName], NO);
            NSString *bid = meta[@"MCMMetadataIdentifier"];
            if ([bid isKindOfClass:NSString.class]) g_dataByBundleID[bid] = dir;
        }
        g_dataIndexed = YES;
    }
    return g_dataByBundleID[bundleID];
}

FBAppContainer *fb_related_container(FBAppContainer *container)
{
    NSString *target = nil;
    @synchronized (fb_containers_lock()) {
        switch (container.kind) {
            case FBContainerKindBundle:
                target = fb_data_container_for_id_locked(container.identifier);
                break;
            case FBContainerKindData:
                target = fb_apps_locked()[container.identifier].bundleContainer;
                break;
            case FBContainerKindPlugin: {
                NSString *owner = fb_owner_app_id_locked(container.identifier);
                target = owner ? fb_data_container_for_id_locked(owner) : nil;
                break;
            }
            default:
                break;
        }
    }
    return target ? fb_container_for_path(target, NO) : nil;
}

void fb_containers_reset(void)
{
    @synchronized (fb_containers_lock()) {
        g_containers = nil;
        g_apps = nil;
        g_dataByBundleID = nil;
        g_dataIndexed = NO;
    }
}
