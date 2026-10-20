//
//  FBAppContainers.h
//  Cyanide
//
//  Names the UUID folders iOS keeps apps in (bundle, data, app group and
//  extension containers) and links an app's bundle and data containers, as
//  Filza does. Built from each container's MobileContainerManager metadata
//  and the apps' Info.plists. Blocking calls: use them off the main thread.
//

#import <UIKit/UIKit.h>

typedef NS_ENUM(NSInteger, FBContainerKind) {
    FBContainerKindBundle,      // /var/containers/Bundle/Application/<UUID>
    FBContainerKindData,        // /var/mobile/Containers/Data/Application/<UUID>
    FBContainerKindAppGroup,    // /var/mobile/Containers/Shared/AppGroup/<UUID>
    FBContainerKindPlugin,      // /var/mobile/Containers/Data/PluginKitPlugin/<UUID>
    FBContainerKindSystemGroup, // /var/containers/Shared/SystemGroup/<UUID>
};

@interface FBAppContainer : NSObject
@property (nonatomic, readonly) FBContainerKind kind;
@property (nonatomic, readonly, copy) NSString *path;         // canonical (/private/var/…)
@property (nonatomic, readonly, copy) NSString *identifier;   // bundle or group identifier
@property (nonatomic, readonly, copy) NSString *displayName;  // app name, or the identifier
@property (nonatomic, readonly, strong) UIImage *icon;        // app icon, nil if none found
// Bundle and data containers of a known app: its executable (the process
// name it runs as) and whether it is a built-in app from /Applications.
@property (nonatomic, readonly, copy) NSString *executableName;
@property (nonatomic, readonly) BOOL systemApp;
@end

// /var/… and /private/var/… name the same place; this returns the latter.
NSString *fb_canonical_path(NSString *path);
// Whether `dir` is one of the folders holding UUID containers.
BOOL fb_is_container_parent(NSString *dir);
// The container `path` is or lies inside, nil if none. viaRoot: read its
// metadata through launchd when mobile can't. Cached; blocking.
FBAppContainer *fb_container_for_path(NSString *path, BOOL viaRoot);
// Re-read the container metadata and associated app Info.plist for a safety
// decision. This never decodes icons and returns nil on a missing/mismatched
// bundle association or executable.
FBAppContainer *fb_current_container_for_path(NSString *path, BOOL viaRoot);
// The app's other container: data for a bundle container and vice versa
// (also the app's data container for an extension). Blocking.
FBAppContainer *fb_related_container(FBAppContainer *container);
// Forget everything (pull to refresh in a container folder).
void fb_containers_reset(void);
// Every app data container (/var/mobile/Containers/Data/Application) that
// belongs to a known app, installed or built-in. Blocking.
NSArray<FBAppContainer *> *fb_app_data_containers(void);
