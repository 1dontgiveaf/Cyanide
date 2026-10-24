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

    // Match the v1.3.6 arm count for this daemon without changing the
    // launchd-oriented default or the shared RemoteCall safety checks.
    remote_call_set_next_init_target_threads("thermalmonitord", 2);
    if (init_remote_call("thermalmonitord", false) != 0) {
        printf("[POWERCUFF] init_remote_call(thermalmonitord) failed\n");
        return false;
    }

    bool ok = false;
    int daemonPid = remote_call_current_pid();
    long thermalBefore = (long)NSProcessInfo.processInfo.thermalState;
    long thermalAttached = -1;
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
        // r_alloc_str doesn't check its remote write: read the string back
        // before it reaches the mutating call.
        char echo[32] = {0};
        if (!r_read_nsstring(modeStr, echo, sizeof(echo)) || strcmp(echo, level) != 0) {
            printf("[POWERCUFF] mode string read back as '%s', expected '%s' - not sending it\n", echo, level);
            break;
        }

        printf("[POWERCUFF] -[CommonProduct putDeviceInThermalSimulationMode:'%s']\n", level);
        r_msg2(product, "putDeviceInThermalSimulationMode:", modeStr, 0, 0, 0);
        // Applied only when the call verifiably completed. A lost reply may
        // or may not have run: report failure rather than "applied" (a
        // re-apply sets the same mode, so retrying it is harmless).
        ok = r_last_call_ok();
        // Observation window while still attached: compared with the state
        // after teardown, it tells "never took effect" from "lost when Cyanide
        // detached" (e.g. thermalmonitord restarting). Not a settle: 1.3.6
        // settled before each message, as r_msg2 still does.
        usleep(1000000);
        thermalAttached = (long)NSProcessInfo.processInfo.thermalState;
        // modeStr is not released, as in 1.3.6: whether this private method
        // retains its argument is unknown. One small string per apply.
        printf("[POWERCUFF] %s: %s\n", ok ? "call completed" : "result unknown (reply lost)", level);
    } while (0);

    destroy_remote_call();

    // Check that it took. A restarted thermalmonitord has forgotten the
    // simulated level: that is a failure. An unchanged public thermal state is
    // not conclusive on its own (it may lag or already match), so it's
    // reported, not counted against the result.
    if (ok) {
        usleep(1500000);
        int alive = daemonPid > 0 ? kill(daemonPid, 0) : -1;
        bool running = alive == 0 || errno == EPERM;
        long thermalAfter = (long)NSProcessInfo.processInfo.thermalState;
        static const char *names[] = { "nominal", "fair", "serious", "critical" };
        #define PC_NAME(v) ((v) >= 0 && (v) < 4 ? names[(v)] : "?")
        const char *outcome = !running ? "thermalmonitord GONE after detaching - the level is lost"
            : thermalAfter != thermalBefore ? "effect observed"
            : thermalAttached != thermalBefore ? "effect seen while attached, LOST after detaching"
            : "call completed, effect not confirmed (thermal state unchanged)";
        printf("[POWERCUFF] check: pid %d %s; thermal state before %s, attached %s, after detach %s -> %s\n",
               daemonPid, running ? "running" : "gone", PC_NAME(thermalBefore), PC_NAME(thermalAttached),
               PC_NAME(thermalAfter), outcome);
        log_user("[POWERCUFF] %s: %s (system thermal state %s).\n", level, outcome, PC_NAME(thermalAfter));
        #undef PC_NAME
        if (!running) ok = false;
    }
    return ok;
}
