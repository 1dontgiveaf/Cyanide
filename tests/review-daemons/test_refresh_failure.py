#!/usr/bin/env python3
"""Failed daemon refresh tests; all state is synthetic and in-memory."""
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "Cyanide/DaemonsViewController.m"


class RefreshFailureTests(unittest.TestCase):
    def test_native_fake_snapshot_is_invalidated(self):
        source = SOURCE.read_text()
        start = source.index("static void daemons_invalidate_snapshot")
        end = source.index("\n\n@class DaemonGroupViewController", start)
        helper = source[start:end]
        harness = f'''
#import <Foundation/Foundation.h>
{helper}

static void require_condition(BOOL condition, NSString *message)
{{
    if (condition) return;
    fprintf(stderr, "daemon refresh test failed: %s\\n", message.UTF8String);
    exit(1);
}}

int main(void)
{{
    @autoreleasepool {{
        NSDictionary *disabled = @{{ @"com.apple.tipsd": @YES }};
        NSDictionary *running = @{{ @"com.apple.tipsd": @{{ @"pid": @42 }} }};
        NSMutableDictionary *staged = [@{{ @"com.apple.tipsd": @NO }} mutableCopy];
        NSString *status = @"previous successful snapshot";
        daemons_invalidate_snapshot(&disabled, &running, staged, &status, @"synthetic read failure");
        require_condition(disabled == nil && running == nil, @"old dictionaries must be cleared");
        require_condition(staged.count == 0, @"staged edits must be discarded");
        require_condition([status isEqualToString:@"synthetic read failure"], @"useful error must be retained");

        disabled = @{{ @"com.apple.tipsd": @YES }};
        running = @{{ @"com.apple.tipsd": @{{ @"pid": @43 }} }};
        staged = [@{{ @"com.apple.tipsd": @YES }} mutableCopy];
        status = @"old";
        daemons_invalidate_snapshot(&disabled, &running, staged, &status, nil);
        require_condition(disabled == nil && running == nil && staged.count == 0,
                          @"nil-error failure must still invalidate all state");
        require_condition(status.length > 0, @"nil-error failure needs a useful fallback");
        puts("daemon refresh invalidation: PASS");
    }}
    return 0;
}}
'''
        with tempfile.TemporaryDirectory(prefix="cyanide-daemon-refresh-") as temporary:
            base = Path(temporary)
            source_path = base / "refresh.m"
            executable = base / "refresh"
            source_path.write_text(harness)
            subprocess.run(
                ["xcrun", "clang", "-fobjc-arc", "-framework", "Foundation",
                 str(source_path), "-o", str(executable)],
                check=True,
            )
            subprocess.run([str(executable)], check=True)

    def test_source_contracts_gate_controls_on_valid_snapshot(self):
        source = SOURCE.read_text()
        self.assertIn("@property (nonatomic, assign) BOOL snapshotValid;", source)
        self.assertIn("me.snapshotValid = YES;", source)
        self.assertIn("me.snapshotValid = NO;", source)
        self.assertIn("daemons_invalidate_snapshot(&failedDisabled, &failedRunning, me.staged, &failureStatus, message);", source)
        self.assertIn("self.snapshotValid && !self.busy && dirty", source)
        self.assertIn("self.busy || !self.snapshotValid || !self.disabled", source)
        self.assertNotIn("} else if (!me.disabled) {", source)


if __name__ == "__main__":
    unittest.main()
