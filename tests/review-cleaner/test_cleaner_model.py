#!/usr/bin/env python3
"""Native model copy checks plus a source contract for main-queue publication."""
from pathlib import Path
import subprocess
import tempfile
import unittest

SOURCE = Path(__file__).resolve().parents[2] / "Cyanide/CleanerViewController.m"

class CleanerModelTests(unittest.TestCase):
    def test_detached_worker_model(self):
        source = SOURCE.read_text()
        model = source[source.index("@interface CYCleanerItem"):source.index("@interface CYCleanerFoldersViewController")]
        code = r'''
#import <Foundation/Foundation.h>
@interface FBAppContainer : NSObject @end
@implementation FBAppContainer @end
@interface UIImage : NSObject @end
@implementation UIImage @end
''' + model + r'''
int main(void) { @autoreleasepool {
    CYCleanerItem *displayed = [CYCleanerItem new];
    displayed.container = [FBAppContainer new];
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
    puts("cleaner detached-model regression: PASS");
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
        self.assertIn("results[oldItem.container.path] ?: oldItem", publication)
        self.assertIn("self.items = published", publication)
        self.assertLess(publication.index("self.items = published"), publication.index("[self.tableView reloadData]"))

if __name__ == "__main__":
    unittest.main()
