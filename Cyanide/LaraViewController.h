//
//  LaraViewController.h
//  Cyanide
//
//  Settings → Lara: tools ported from lara by rooootdev
//  (https://github.com/rooootdev/lara), with his permission.
//

#import <UIKit/UIKit.h>

typedef NS_ENUM(NSInteger, LaraTool) {
    LaraToolPerformanceHUD,
    LaraToolDebugOverlay,
    LaraToolUpsideDown,
    LaraToolHiddenSettings,
    LaraToolJIT,
};

@interface LaraViewController : UITableViewController
- (instancetype)initWithTool:(LaraTool)tool;
@end
