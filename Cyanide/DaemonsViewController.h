//
//  DaemonsViewController.h
//  Cyanide
//
//  Turns system daemons off and on through launchd's disabled.plist, from a
//  fixed list of daemons that are safe to disable (tweaks/daemon_catalog.h).
//

#import <UIKit/UIKit.h>

@interface DaemonsViewController : UITableViewController
- (instancetype)init;
@end
