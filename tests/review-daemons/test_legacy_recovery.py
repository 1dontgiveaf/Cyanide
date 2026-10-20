#!/usr/bin/env python3
"""Legacy daemon recovery tests; no device or launchd access is performed."""
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
CATALOG = ROOT / "Cyanide/tweaks/daemon_catalog.m"
CATALOG_H = ROOT / "Cyanide/tweaks/daemon_catalog.h"
VIEW = ROOT / "Cyanide/DaemonsViewController.m"
OTA = ROOT / "Cyanide/tweaks/darksword_ota.m"


class LegacyRecoveryTests(unittest.TestCase):
    def test_native_fake_plist_and_jobs(self):
        harness = r'''
#import <Foundation/Foundation.h>
#import "daemon_catalog.h"

static void require_condition(BOOL condition, NSString *message)
{
    if (condition) return;
    fprintf(stderr, "legacy recovery test failed: %s\n", message.UTF8String);
    exit(1);
}

int main(void)
{
    @autoreleasepool {
        NSString *legacy = @"com.apple.ReportCrash.Jetsam";
        NSString *legacyAbsent = @"com.apple.printd";
        NSString *current = @"com.apple.tipsd";
        NSDictionary *fakeDisabled = @{
            legacy: @YES,
            legacyAbsent: @YES,
            current: @YES,
            @"com.apple.not-a-cyanide-label": @YES,
            @"com.apple.atc.atwakeup": @NO,
        };
        // A fake current job cache deliberately has no legacy rows. Legacy
        // recovery must not turn that cache absence into a normal group.
        NSDictionary *fakeJobs = @{ current: @"tipsd" };
        require_condition(fakeJobs[legacy] == nil && fakeJobs[legacyAbsent] == nil,
                          @"fixture must model absent legacy jobs");

        CYDaemonGroup *recovery = daemon_catalog_legacy_recovery_group(fakeDisabled);
        require_condition(recovery != nil, @"persisted legacy rows need a recovery group");
        require_condition(recovery.labels.count == 2, @"only true legacy disabled entries are shown");
        require_condition([recovery.labels containsObject:legacy] &&
                          [recovery.labels containsObject:legacyAbsent],
                          @"recovery group has the expected labels");
        require_condition(!daemon_catalog_contains_label(legacy),
                          @"legacy label must stay outside current catalog");
        for (CYDaemonGroup *group in daemon_catalog_groups()) {
            require_condition(![group.labels containsObject:legacy] &&
                              ![group.labels containsObject:legacyAbsent],
                              @"legacy label must not return to a normal group");
        }
        require_condition(!daemon_catalog_change_is_allowed(legacy, YES),
                          @"legacy disable must remain refused");
        require_condition(daemon_catalog_change_is_allowed(legacy, NO),
                          @"legacy enable/removal must be allowed");
        require_condition(daemon_catalog_change_is_allowed(current, YES) &&
                          daemon_catalog_change_is_allowed(current, NO),
                          @"current labels keep both directions");
        require_condition(!daemon_catalog_change_is_allowed(@"com.apple.not-a-cyanide-label", NO),
                          @"arbitrary labels must remain refused");
        require_condition(daemon_catalog_legacy_recovery_group(@{ legacy: @NO }) == nil,
                          @"already enabled legacy entries need no recovery row");
        puts("daemon legacy recovery: PASS");
    }
    return 0;
}
'''
        with tempfile.TemporaryDirectory(prefix="cyanide-daemon-legacy-") as temporary:
            base = Path(temporary)
            source = base / "legacy.m"
            executable = base / "legacy"
            source.write_text(harness)
            subprocess.run(
                ["xcrun", "clang", "-fobjc-arc", "-framework", "Foundation",
                 str(source), str(CATALOG), "-I", str(CATALOG_H.parent), "-o", str(executable)],
                check=True,
            )
            subprocess.run([str(executable)], check=True)

    def test_source_contracts_keep_recovery_bounded(self):
        catalog = CATALOG.read_text()
        view = VIEW.read_text()
        ota = OTA.read_text()
        header = CATALOG_H.read_text()
        self.assertIn("daemon_catalog_is_legacy_label", header)
        self.assertIn("daemon_catalog_legacy_recovery_group", view)
        self.assertIn("job presence not checked", view)
        self.assertIn("daemon_catalog_change_is_allowed(label, value.boolValue)", ota)
        self.assertIn("return !disable && daemon_catalog_is_legacy_label(label);", catalog)
        self.assertNotIn("daemon_catalog_is_legacy_label(label) || daemon_catalog_contains_label(label)", ota)


if __name__ == "__main__":
    unittest.main()
