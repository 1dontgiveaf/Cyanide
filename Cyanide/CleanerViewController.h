//
//  CleanerViewController.h
//  Cyanide
//
//  App cache/temp cleaner. Lists installed app data containers, shows how much
//  is reclaimable, and removes only Library/Caches and tmp contents. Running
//  apps are never touched; system apps are opt-in.
//

#import <UIKit/UIKit.h>

@interface CleanerViewController : UITableViewController

- (instancetype)init;

@end
