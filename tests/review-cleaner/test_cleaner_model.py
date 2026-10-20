#!/usr/bin/env python3
"""Native Cleaner model/state checks plus narrow publication contracts."""
from pathlib import Path
import subprocess
import tempfile
import unittest

SOURCE = Path(__file__).resolve().parents[2] / "Cyanide/CleanerViewController.m"

class CleanerModelTests(unittest.TestCase):
    def test_native_model_lifecycle_and_logs(self):
        source = SOURCE.read_text()
        model = source[source.index("@interface CYCleanerItem"):source.index("@interface CYCleanerFoldersViewController")]
        scan_state = source[source.index("static BOOL cleaner_scan_should_restart"):source.index("static void cleaner_suppress_popup_bar")]
        code = r'''
#import <Foundation/Foundation.h>
@interface FBAppContainer : NSObject
@property (nonatomic, copy) NSString *path;
@end
@implementation FBAppContainer @end
@interface UIImage : NSObject @end
@implementation UIImage @end
''' + scan_state + model + r'''
int main(void) { @autoreleasepool {
    CYCleanerItem *displayed = [CYCleanerItem new];
    FBAppContainer *container = [FBAppContainer new];
    container.path = @"/private/var/mobile/Containers/Data/Application/example";
    displayed.container = container;
    displayed.name = @"Example";
    displayed.cacheBytes = 4096;
    displayed.tempBytes = 1024;
    displayed.selected = YES;
    CYCleanerItem *work = [displayed copy];
    if (work == displayed || work.container != displayed.container ||
        work.totalBytes != 5120 || !work.selected || ![work.name isEqual:displayed.name]) return 1;
    work.active = YES; work.selected = NO; work.cacheBytes = 0;
    work.tempBytes = 0; work.incomplete = YES;
    if (displayed.active || !displayed.selected || displayed.totalBytes != 5120 ||
        displayed.incomplete) return 2;

    CYCleanerItem *existingLogs = [CYCleanerItem new];
    existingLogs.name = @"Crash Logs";
    existingLogs.logRoots = @[ @"/private/var/logs/CrashReporter" ];
    existingLogs.cacheBytes = 4096;
    if (cleaner_published_crash_logs(existingLogs, nil) != existingLogs ||
        cleaner_published_crash_logs(existingLogs, nil).totalBytes != 4096) return 3;

    CYCleanerItem *remainingLogs = [existingLogs copy];
    remainingLogs.cacheBytes = 512;
    if (cleaner_published_crash_logs(existingLogs, remainingLogs) != remainingLogs) return 4;

    CYCleanerItem *emptyLogs = [existingLogs copy];
    emptyLogs.cacheBytes = 0;
    emptyLogs.incomplete = NO;
    if (cleaner_published_crash_logs(existingLogs, emptyLogs) != nil) return 5;

    CYCleanerItem *incompleteLogs = [existingLogs copy];
    incompleteLogs.cacheBytes = 0;
    incompleteLogs.incomplete = YES;
    if (cleaner_published_crash_logs(existingLogs, incompleteLogs) != incompleteLogs) return 6;

    if (!cleaner_scan_should_restart(YES, NO, NO, YES, YES, YES)) return 7;
    if (cleaner_scan_should_restart(YES, YES, NO, YES, YES, YES) ||
        cleaner_scan_should_restart(YES, NO, NO, NO, YES, YES) ||
        cleaner_scan_should_restart(YES, NO, NO, YES, NO, YES) ||
        cleaner_scan_should_restart(YES, NO, NO, YES, YES, NO) ||
        cleaner_scan_should_restart(NO, NO, NO, YES, YES, YES)) return 8;
    puts("cleaner detached-model/lifecycle/log regressions: PASS");
} return 0; }
'''
        with tempfile.TemporaryDirectory(prefix="cyanide-model-test-") as temporary:
            base = Path(temporary)
            harness = base / "model.m"
            executable = base / "model"
            harness.write_text(code)
            subprocess.run(["xcrun", "clang", "-fobjc-arc", "-framework", "Foundation", str(harness), "-o", str(executable)], check=True)
            subprocess.run([str(executable)], check=True)

    def test_publication_source_contract(self):
        source = SOURCE.read_text()
        body = source[source.index("- (void)performClean"):source.index("#pragma mark Table")]
        self.assertIn("[work addObject:[item copy]]", body)
        self.assertNotIn("[work addObject:item]", body)
        publication = body[body.rindex("dispatch_async(dispatch_get_main_queue()") :]
        self.assertIn("results[oldItem.key] ?: oldItem", publication)
        self.assertIn("self.items = published", publication)
        self.assertIn("self.crashLogs = cleaner_published_crash_logs(self.crashLogs, logsResult);", publication)
        self.assertNotIn("self.crashLogs = (logsResult &&", publication)
        self.assertLess(publication.index("self.items = published"), publication.index("[self.tableView reloadData]"))

    def test_scan_lifecycle_source_contract(self):
        source = SOURCE.read_text()
        scan = source[source.index("- (void)reloadData"):source.index("#pragma mark Actions")]
        self.assertIn("NSUInteger scanGeneration = ++self.scanGeneration;", scan)
        self.assertIn("self.scanGeneration != scanGeneration", scan)
        self.assertIn("self.scanStale = YES", scan)
        self.assertIn("[self cleaner_scheduleStaleScanIfNeeded]", scan)
        self.assertIn("if (!__atomic_load_n(&scanCancelled, __ATOMIC_RELAXED))", scan)
        lifecycle = source[source.index("- (void)viewDidLoad"):source.index("- (void)viewWillAppear")]
        self.assertIn("UIApplicationDidBecomeActiveNotification", lifecycle)

if __name__ == "__main__":
    unittest.main()
