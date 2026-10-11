//
//  daemon_catalog.h
//
//  The launchd daemons Cyanide offers to disable through disabled.plist.
//  Only labels listed here are ever written. The groups follow Nugget's
//  daemon list (leminlimez/Nugget, src/tweaks/daemons_tweak.py), which is
//  widely used on stock iOS 17/18, minus com.apple.homed (HomeKit), which
//  Nugget folds into Screen Time.
//

#import <Foundation/Foundation.h>

@interface CYDaemonGroup : NSObject
@property (nonatomic, readonly, copy) NSString *identifier;
@property (nonatomic, readonly, copy) NSString *title;
@property (nonatomic, readonly, copy) NSString *summary;   // what stops when disabled
@property (nonatomic, readonly, copy) NSString *symbol;    // SF Symbol
@property (nonatomic, readonly, copy) NSArray<NSString *> *labels;
// Set for groups whose loss is easy to notice (Wallet, Siri, Location, …):
// shown in the list and confirmed before disabling.
@property (nonatomic, readonly, copy) NSString *caution;
// Services other parts of iOS rely on: hidden unless the user turns on
// "Show Advanced" (the riskier ones to disable).
@property (nonatomic, readonly) BOOL advanced;
@end

NSArray<CYDaemonGroup *> *daemon_catalog_groups(void);
BOOL daemon_catalog_contains_label(NSString *label);
// The executable name a label most likely runs, when launchd's job cache
// can't be read: the label's last component, with known exceptions.
NSString *daemon_catalog_executable_guess(NSString *label);
