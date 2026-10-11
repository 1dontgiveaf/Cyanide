//
//  respring.m
//  Cyanide
//

#import "respring.h"
#import "remote_objc.h"
#import "../LogTextView.h"   // mirror printf into the chain log

#import <Foundation/Foundation.h>
#import <stdio.h>

// No-argument relaunch selectors on SpringBoard's application object, newest
// first. Only selectors without arguments: performSelector:withObject:
// afterDelay: passes an object, not a BOOL.
static const char *const kRelaunchSelectors[] = {
    "_relaunchSpringBoardNow",
    "relaunchSpringBoard",
};

ASRemovalResult respring_schedule_in_session(double delaySeconds)
{
    uint64_t appClass = r_class("UIApplication");
    if (!r_is_objc_ptr(appClass)) return ASRemovalNotScheduled;
    uint64_t app = r_msg2_main(appClass, "sharedApplication", 0, 0, 0, 0);
    if (!r_is_objc_ptr(app)) {
        printf("[RESPRING] SpringBoard's application object not found\n");
        return ASRemovalNotScheduled;
    }
    const char *relaunch = NULL;
    for (size_t i = 0; i < sizeof(kRelaunchSelectors) / sizeof(kRelaunchSelectors[0]); i++) {
        if (r_responds(app, kRelaunchSelectors[i])) { relaunch = kRelaunchSelectors[i]; break; }
    }
    if (!relaunch) {
        printf("[RESPRING] no relaunch selector on SpringBoard\n");
        return ASRemovalNotScheduled;
    }
    uint64_t sel = r_sel(relaunch);
    if (!sel) return ASRemovalNotScheduled;
    // On SpringBoard's main thread: afterDelay: uses the calling thread's run
    // loop, and our synthetic call thread has none.
    uint64_t nilArg = 0;
    double delay = delaySeconds;
    r_msg2_main_raw(app, "performSelector:withObject:afterDelay:",
                    &sel, sizeof(sel), &nilArg, sizeof(nilArg), &delay, sizeof(delay), NULL, 0);
    ASRemovalResult r = r_last_main_ok() ? ASRemovalScheduled : ASRemovalUnknown;
    printf("[RESPRING] -[SpringBoard %s] %s (in %.2fs)\n", relaunch,
           r == ASRemovalScheduled ? "scheduled" : "result UNKNOWN (treated as scheduled)", delaySeconds);
    return r;
}
