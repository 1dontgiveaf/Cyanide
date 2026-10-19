//
//  respring.m
//  Cyanide
//

#import "respring.h"
#import "remote_objc.h"
#import "../LogTextView.h"   // mirror printf into the chain log

#import <Foundation/Foundation.h>
#import <stdio.h>

// Older no-argument relaunch selectors on SpringBoard's application object
// (gone on iOS 18.5, kept as a fallback).
static const char *const kAppRelaunchSelectors[] = {
    "_relaunchSpringBoardNow",
    "relaunchSpringBoard",
};

static ASRemovalResult respring_result(int r)
{
    return r == R_DELAY_SCHEDULED ? ASRemovalScheduled
         : r == R_DELAY_UNKNOWN   ? ASRemovalUnknown
                                  : ASRemovalNotScheduled;
}

ASRemovalResult respring_schedule_in_session(double delaySeconds)
{
    // FrontBoard's own restart: -[FBSystemService exitAndRelaunch:YES], as
    // SpringBoard does for a settings change that needs a respring.
    uint64_t fbs = r_class("FBSystemService");
    if (r_is_objc_ptr(fbs) && r_responds(fbs, "sharedInstance")) {
        uint64_t service = r_msg2_main(fbs, "sharedInstance", 0, 0, 0, 0);
        if (r_is_objc_ptr(service) && r_responds(service, "exitAndRelaunch:")) {
            BOOL relaunch = YES;
            int r = r_invoke_after_delay(service, "exitAndRelaunch:", &relaunch, sizeof(relaunch), delaySeconds);
            printf("[RESPRING] -[FBSystemService exitAndRelaunch:YES] %s (in %.2fs)\n",
                   r == R_DELAY_SCHEDULED ? "scheduled" :
                   r == R_DELAY_UNKNOWN ? "result UNKNOWN (treated as scheduled)" : "could not be scheduled",
                   delaySeconds);
            if (r != R_DELAY_NOT_SCHEDULED) return respring_result(r);
        } else {
            printf("[RESPRING] FBSystemService has no usable exitAndRelaunch:\n");
        }
    } else {
        printf("[RESPRING] FBSystemService not found\n");
    }

    uint64_t appClass = r_class("UIApplication");
    uint64_t app = r_is_objc_ptr(appClass) ? r_msg2_main(appClass, "sharedApplication", 0, 0, 0, 0) : 0;
    if (!r_is_objc_ptr(app)) {
        printf("[RESPRING] SpringBoard's application object not found\n");
        return ASRemovalNotScheduled;
    }
    for (size_t i = 0; i < sizeof(kAppRelaunchSelectors) / sizeof(kAppRelaunchSelectors[0]); i++) {
        if (!r_responds(app, kAppRelaunchSelectors[i])) continue;
        int r = r_invoke_after_delay(app, kAppRelaunchSelectors[i], NULL, 0, delaySeconds);
        printf("[RESPRING] -[SpringBoard %s] %s (in %.2fs)\n", kAppRelaunchSelectors[i],
               r == R_DELAY_SCHEDULED ? "scheduled" :
               r == R_DELAY_UNKNOWN ? "result UNKNOWN (treated as scheduled)" : "could not be scheduled",
               delaySeconds);
        if (r != R_DELAY_NOT_SCHEDULED) return respring_result(r);
    }
    printf("[RESPRING] no relaunch method found in SpringBoard\n");
    return ASRemovalNotScheduled;
}

ASRemovalResult reboot_schedule_in_session(double delaySeconds)
{
    uint64_t fbs = r_class("FBSystemService");
    if (!r_is_objc_ptr(fbs) || !r_responds(fbs, "sharedInstance")) {
        printf("[REBOOT] FBSystemService not found\n");
        return ASRemovalNotScheduled;
    }
    uint64_t service = r_msg2_main(fbs, "sharedInstance", 0, 0, 0, 0);
    if (!r_is_objc_ptr(service) || !r_responds(service, "shutdownAndReboot:")) {
        printf("[REBOOT] FBSystemService has no usable shutdownAndReboot:\n");
        return ASRemovalNotScheduled;
    }
    BOOL reboot = YES;
    int r = r_invoke_after_delay(service, "shutdownAndReboot:", &reboot, sizeof(reboot), delaySeconds);
    printf("[REBOOT] -[FBSystemService shutdownAndReboot:YES] %s (in %.2fs)\n",
           r == R_DELAY_SCHEDULED ? "scheduled" :
           r == R_DELAY_UNKNOWN ? "result UNKNOWN (treated as scheduled)" : "could not be scheduled",
           delaySeconds);
    return respring_result(r);
}
