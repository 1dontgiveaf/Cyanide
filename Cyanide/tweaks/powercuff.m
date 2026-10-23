//
//  powercuff.m
//

#import "powercuff.h"
#import "remote_objc.h"
#import "../TaskRop/RemoteCall.h"
#import <stdio.h>
#import <string.h>
#import <unistd.h>
#import "../LogTextView.h"
#import <Foundation/Foundation.h>
#import <errno.h>
#import <signal.h>

static bool valid_level(const char *level) {
    if (!level) return false;
    return (!strcmp(level, "off") || !strcmp(level, "nominal") ||
            !strcmp(level, "light") || !strcmp(level, "moderate") ||
            !strcmp(level, "heavy"));
}

bool powercuff_apply(const char *level)
{
    if (!valid_level(level)) {
        printf("[POWERCUFF] invalid level '%s', defaulting to nominal\n", level ? level : "(null)");
        level = "nominal";
    }
    printf("[POWERCUFF] === entry === target=%s\n", level);

    if (init_remote_call("thermalmonitord", false) != 0) {
        printf("[POWERCUFF] init_remote_call(thermalmonitord) failed\n");
        return false;
    }

    bool ok = false;
    int daemonPid = remote_call_current_pid();
    long thermalBefore = (long)NSProcessInfo.processInfo.thermalState;
    do {
        uint64_t cls = r_class("CPMSHelper");
        if (!cls) { printf("[POWERCUFF] CPMSHelper class missing - wrong process?\n"); break; }
        printf("[POWERCUFF] CPMSHelper=0x%llx\n", cls);
        usleep(50000);

        uint64_t helper = r_msg2(cls, "sharedInstance", 0, 0, 0, 0);
        if (!helper) { printf("[POWERCUFF] +sharedInstance returned nil\n"); break; }
        printf("[POWERCUFF] helper=0x%llx\n", helper);
        usleep(50000);

        uint64_t product = r_ivar_value(helper, "productObj");
        if (!product) { printf("[POWERCUFF] productObj ivar is nil - daemon not done with initProduct: yet\n"); break; }
        printf("[POWERCUFF] product=0x%llx\n", product);
        usleep(50000);

        if (!r_responds(product, "putDeviceInThermalSimulationMode:")) {
            printf("[POWERCUFF] product does not respond to putDeviceInThermalSimulationMode:\n");
            break;
        }
        usleep(50000);

        uint64_t modeStr = r_cfstr(level);
        if (!modeStr) { printf("[POWERCUFF] CFString create failed\n"); break; }

        printf("[POWERCUFF] -[CommonProduct putDeviceInThermalSimulationMode:'%s']\n", level);
        r_msg2(product, "putDeviceInThermalSimulationMode:", modeStr, 0, 0, 0);
        // Applied only when the call verifiably completed. A lost reply may
        // or may not have run: report failure rather than "applied" (a
        // re-apply sets the same mode, so retrying it is harmless).
        ok = r_last_call_ok();
        // modeStr is deliberately not released: thermalmonitord keeps using
        // the string after the call returns (1.3.6 never released it and
        // worked; releasing it here left Heavy reported as applied but not in
        // effect). One small string per apply.
        printf("[POWERCUFF] %s: %s\n", ok ? "applied" : "result unknown (reply lost)", level);
    } while (0);

    destroy_remote_call();

    // Check that it took: thermalmonitord must still be the same process
    // (a restart forgets the simulated level) and the system thermal state
    // should follow (Heavy reports Critical in apps like CPU X).
    if (ok) {
        usleep(1500000);
        int alive = daemonPid > 0 ? kill(daemonPid, 0) : -1;
        int aliveErr = alive == 0 ? 0 : errno;
        long thermalAfter = (long)NSProcessInfo.processInfo.thermalState;
        static const char *names[] = { "nominal", "fair", "serious", "critical" };
        printf("[POWERCUFF] check: thermalmonitord pid %d %s; thermal state %s -> %s\n", daemonPid,
               alive == 0 || aliveErr == EPERM ? "still running" : "GONE (restarted? the level is lost)",
               thermalBefore >= 0 && thermalBefore < 4 ? names[thermalBefore] : "?",
               thermalAfter >= 0 && thermalAfter < 4 ? names[thermalAfter] : "?");
        log_user("[POWERCUFF] %s: system thermal state now %s.\n", level,
                 thermalAfter >= 0 && thermalAfter < 4 ? names[thermalAfter] : "unknown");
    }
    return ok;
}
