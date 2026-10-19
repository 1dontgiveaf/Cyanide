#!/usr/bin/env python3
"""Compile actual cleaner helpers with Foundation; never touch real app data.

Only the allowed app-data prefix is redirected to a temporary fake filesystem.
Requires macOS + Xcode command line tools. All fixtures belong to this test.
"""
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "Cyanide/CleanerViewController.m"

PREAMBLE = r'''
#import <Foundation/Foundation.h>
#import <sys/stat.h>
#import <errno.h>
#import <unistd.h>
#import <fcntl.h>
#import <dirent.h>
#import <string.h>
#import <time.h>
NSString *fb_canonical_path(NSString *path) {
    NSString *p = path.stringByStandardizingPath;
    if ([p isEqualToString:@"/var"] || [p hasPrefix:@"/var/"])
        p = [@"/private" stringByAppendingString:p];
    return p;
}
'''
FIXTURES = r'''
static void check(BOOL value, const char *message) {
    if (!value) { fprintf(stderr, "FAIL: %s\n", message); exit(1); }
}
static void mkdirp(NSString *path) {
    check([NSFileManager.defaultManager createDirectoryAtPath:path
        withIntermediateDirectories:YES attributes:nil error:nil], "create fixture");
}
static void put(NSString *path, NSUInteger bytes) {
    mkdirp(path.stringByDeletingLastPathComponent);
    check([[NSMutableData dataWithLength:bytes] writeToFile:path atomically:NO], "write fixture");
}
static NSString *app(void) {
    NSString *path = [kCleanerAppDataPrefix stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    mkdirp(path);
    return path;
}
static BOOL exists(NSString *path) { return [NSFileManager.defaultManager fileExistsAtPath:path]; }
'''
SCENARIOS = r'''
// An intermediate Library symlink must be refused by scan AND clear.
NSString *a = app();
NSString *document = [a stringByAppendingPathComponent:@"Documents/Caches/valuable.txt"];
put(document, 4096);
check(symlink("Documents", [a stringByAppendingPathComponent:@"Library"].fileSystemRepresentation) == 0, "library link");
NSString *cache = [a stringByAppendingPathComponent:@"Library/Caches"];
BOOL complete = YES;
NSUInteger removed = 0, failed = 0;
check(cleaner_tree_bytes(cache, NULL, &complete) == 0 && !complete, "ancestor scan refused");
check(cleaner_clear_directory(cache, &removed, &failed, NULL) == 0 && failed > 0, "ancestor clear refused");
check(exists(document), "document survives Library symlink");

// An otherwise valid UUID container may itself be a symlink.
NSString *outside = [kCleanerAppDataPrefix.stringByDeletingLastPathComponent stringByAppendingPathComponent:@"outside"];
put([outside stringByAppendingPathComponent:@"tmp/keep.txt"], 512);
NSString *linkedContainer = [kCleanerAppDataPrefix stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
check(symlink(outside.fileSystemRepresentation, linkedContainer.fileSystemRepresentation) == 0, "container link");
check(cleaner_clear_directory([linkedContainer stringByAppendingPathComponent:@"tmp"], &removed, &failed, NULL) == 0 && failed > 0, "container link refused");
check(exists([outside stringByAppendingPathComponent:@"tmp/keep.txt"]), "external target survives");

// Even within a valid container, arbitrary nested tmp/Caches roots are forbidden.
NSString *nested = [a stringByAppendingPathComponent:@"Documents/tmp"];
put([nested stringByAppendingPathComponent:@"keep.txt"], 256);
check(!cleaner_is_disposable_root(nested), "nested root guard");
cleaner_clear_directory(nested, &removed, &failed, NULL);
check(exists([nested stringByAppendingPathComponent:@"keep.txt"]), "nested document survives");

// A link INSIDE the disposable root is unlinked; its target is never followed.
a = app(); cache = [a stringByAppendingPathComponent:@"Library/Caches"];
mkdirp(cache); document = [a stringByAppendingPathComponent:@"Documents/keep.txt"]; put(document, 128);
NSString *link = [cache stringByAppendingPathComponent:@"link"];
check(symlink(document.fileSystemRepresentation, link.fileSystemRepresentation) == 0, "child link");
cleaner_clear_directory(cache, &removed, &failed, NULL);
struct stat st;
check(lstat(link.fileSystemRepresentation, &st) != 0 && exists(document), "child link removed without target deletion");
check(exists(cache), "cache root preserved");

// Normal nested files remain cleanable using the descriptor walk.
put([cache stringByAppendingPathComponent:@"nested/file.bin"], 1024);
check(cleaner_tree_bytes(cache, NULL, &complete) == 1024 && complete, "normal scan");
removed = failed = 0;
check(cleaner_clear_directory(cache, &removed, &failed, NULL) == 1024 && removed == 1 && failed == 0, "normal clear");
check(exists(cache) && !exists([cache stringByAppendingPathComponent:@"nested"]), "only root contents removed");

// tmp must not erase results from an earlier cache operation.
a = app(); cache = [a stringByAppendingPathComponent:@"Library/Caches"];
NSString *tmp = [a stringByAppendingPathComponent:@"tmp"]; mkdirp(tmp);
put([cache stringByAppendingPathComponent:@"cache.bin"], 2048);
removed = failed = 0;
unsigned long long bytes = cleaner_clear_directory(cache, &removed, &failed, NULL);
bytes += cleaner_clear_directory(tmp, &removed, &failed, NULL);
check(bytes == 2048 && removed == 1 && failed == 0, "cache-only counters survive empty tmp");

// Errors from either root must likewise survive the next call.
check([NSFileManager.defaultManager removeItemAtPath:cache error:nil], "remove empty cache fixture");
check(symlink("../tmp", cache.fileSystemRepresentation) == 0, "rejected cache root fixture");
removed = failed = 0;
cleaner_clear_directory(cache, &removed, &failed, NULL);
NSUInteger cacheFailures = failed;
cleaner_clear_directory(tmp, &removed, &failed, NULL);
check(cacheFailures > 0 && failed == cacheFailures, "cache error survives empty tmp");

// One failed child must not discard bytes already deleted from its parent.
if (geteuid() != 0) {
    a = app(); cache = [a stringByAppendingPathComponent:@"Library/Caches"];
    NSString *blocked = [cache stringByAppendingPathComponent:@"sub/blocked"];
    NSString *deletable = [cache stringByAppendingPathComponent:@"sub/delete.bin"];
    mkdirp(blocked); put(deletable, 1024);
    check(chmod(blocked.fileSystemRepresentation, 0000) == 0, "make blocked fixture");
    removed = failed = 0;
    bytes = cleaner_clear_directory(cache, &removed, &failed, NULL);
    // Restore permissions BEFORE asserting so temporary-directory cleanup is safe.
    chmod(blocked.fileSystemRepresentation, 0700);
    check(bytes == 1024 && removed == 1 && failed > 0 && !exists(deletable), "partial child bytes preserved");
}

// A removed cache link is logical data removed, not guaranteed storage freed.
a = app(); cache = [a stringByAppendingPathComponent:@"Library/Caches"]; mkdirp(cache);
document = [a stringByAppendingPathComponent:@"Documents/original.bin"]; put(document, 8192);
check(linkat(AT_FDCWD, document.fileSystemRepresentation, AT_FDCWD,
    [cache stringByAppendingPathComponent:@"alias.bin"].fileSystemRepresentation, 0) == 0, "hard-link fixture");
struct stat before, after;
check(lstat(document.fileSystemRepresentation, &before) == 0, "stat original");
removed = failed = 0;
bytes = cleaner_clear_directory(cache, &removed, &failed, NULL);
check(lstat(document.fileSystemRepresentation, &after) == 0, "original survives cache unlink");
check(bytes == 8192 && before.st_blocks == after.st_blocks && after.st_nlink == 1, "logical bytes differ from recovered space");

// Empty directories count toward the entry cap, not just regular files.
a = app(); cache = [a stringByAppendingPathComponent:@"Library/Caches"];
mkdirp([cache stringByAppendingPathComponent:@"one"]);
mkdirp([cache stringByAppendingPathComponent:@"two"]);
CYCleanerTraversal walk = cleaner_traversal(10, NULL);
walk.entries = kCleanerMaxScanEntries - 1;
int scanFD = cleaner_open_root(cache); struct stat rootStat;
check(scanFD >= 0 && fstat(scanFD, &rootStat) == 0, "open bounded scan");
complete = YES;
cleaner_scan_directory_fd(scanFD, rootStat.st_dev, 0, &walk, &complete);
check(walk.stopped && !complete && walk.entries == kCleanerMaxScanEntries, "directory-only scan cap");
walk = cleaner_traversal(10, NULL); walk.entries = kCleanerMaxScanEntries - 1;
cleaner_clear_directory(cache, &removed, &failed, &walk);
check(walk.stopped && (exists([cache stringByAppendingPathComponent:@"one"]) ||
    exists([cache stringByAppendingPathComponent:@"two"])), "directory-only removal cap");

// A bounded stack refuses a very deep cache rather than exhausting descriptors.
a = app(); cache = [a stringByAppendingPathComponent:@"Library/Caches"];
NSString *deep = cache;
for (NSUInteger i = 0; i < kCleanerMaxTraversalDepth + 2; i++) deep = [deep stringByAppendingPathComponent:@"d"];
NSString *deepFile = [deep stringByAppendingPathComponent:@"keep.bin"]; put(deepFile, 32);
complete = YES; cleaner_tree_bytes(cache, NULL, &complete);
check(!complete, "depth-limited scan");
walk = cleaner_traversal(10, NULL);
cleaner_clear_directory(cache, &removed, &failed, &walk);
check(walk.stopped && exists(deepFile), "depth-limited removal");

// Expiration/cancellation gates both deletes and post-clean scans.
a = app(); cache = [a stringByAppendingPathComponent:@"Library/Caches"];
NSString *cancelFile = [cache stringByAppendingPathComponent:@"keep.bin"]; put(cancelFile, 64);
int cancelled = 1;
walk = cleaner_traversal(10, &cancelled); removed = failed = 0;
cleaner_clear_directory(cache, &removed, &failed, &walk);
check(walk.stopped && removed == 0 && exists(cancelFile), "cancelled clean leaves data intact");
complete = YES;
cleaner_tree_bytes_cancellable(cache, NULL, &complete, &cancelled);
check(!complete && exists(cancelFile), "cancelled rescan is incomplete");
walk = cleaner_traversal(10, NULL); walk.deadline = 0;
cleaner_clear_directory(cache, &removed, &failed, &walk);
check(walk.stopped && exists(cancelFile), "expired deadline leaves data intact");

// The second root must observe activation after the first root was cleared.
a = app(); cache = [a stringByAppendingPathComponent:@"Library/Caches"];
tmp = [a stringByAppendingPathComponent:@"tmp"];
put([cache stringByAppendingPathComponent:@"first.bin"], 32);
NSString *tempFile = [tmp stringByAppendingPathComponent:@"keep.bin"]; put(tempFile, 64);
__block NSUInteger reads = 0;
NSSet<NSString *> *(^provider)(void) = ^{
    return ++reads == 1 ? [NSSet set] : [NSSet setWithObject:@"ExampleApp"];
};
BOOL available = NO;
check(!cleaner_should_skip_now(@"ExampleApp", provider, &available) && available, "first root inactive");
cleaner_clear_directory(cache, &removed, &failed, NULL);
check(cleaner_should_skip_now(@"ExampleApp", provider, &available) && available && reads == 2,
    "second root refresh observes activation");
check(exists(tempFile), "activated app tmp survives");
check(cleaner_should_skip_now(@"ExampleApp", ^{ return (NSSet<NSString *> *)nil; }, &available) && !available,
    "unavailable detection fails closed");
check(cleaner_should_skip_now(@"", ^{ return [NSSet set]; }, &available) && !available,
    "unknown executable fails closed");
'''

class CleanerHelperTests(unittest.TestCase):
    def test_storage_labels(self):
        source = SOURCE.read_text()
        self.assertIn('@"Cache + Temp Size"', source)
        self.assertIn("(logical size) from", source)
        self.assertIn("not guaranteed recovered storage", source)
        self.assertNotIn('@"Freed %@', source)
        self.assertNotIn('@"Reclaimable"', source)

    def test_background_expiration_contract(self):
        source = SOURCE.read_text()
        body = source[source.index("- (void)performClean"):source.index("#pragma mark Table")]
        expiration = body[body.index("expirationHandler:^{"):body.index("if (bgTask == UIBackgroundTaskInvalid)")]
        self.assertIn("__atomic_store_n(&cancelled, 1", expiration)
        self.assertIn("endBackgroundTask:bgTask", expiration)
        self.assertNotIn("expirationHandler:^{}", body)
        self.assertIn("results are partial", body)
        self.assertIn("cleaner_tree_bytes_cancellable", body)

    def test_fresh_process_check_contract(self):
        source = SOURCE.read_text()
        body = source[source.index("- (void)performClean"):source.index("#pragma mark Table")]
        roots = body[body.index("for (NSString *relativeRoot"):body.index("freed += appFreed")]
        self.assertIn("cleaner_should_skip_now", roots)
        self.assertIn("settings_active_process_names()", roots)
        self.assertLess(roots.index("cleaner_should_skip_now"), roots.index("cleaner_clear_directory"))
        self.assertNotIn("NSSet<NSString *> *active", body)
        self.assertIn("processUnavailable = !available", roots)
        self.assertIn("Detection is best-effort", source)

    def test_native_helpers(self):
        source = SOURCE.read_text()
        with tempfile.TemporaryDirectory(prefix="cyanide-cleaner-test-") as temporary:
            base = Path(temporary).resolve()
            prefix = str(base / "Containers/Data/Application") + "/"
            constants = source[source.index("static NSString * const kCleanerAppDataPrefix"):source.index("static void cleaner_suppress_popup_bar")]
            constants = constants.replace("/private/var/mobile/Containers/Data/Application/", prefix)
            helpers = source[source.index("static BOOL cleaner_path_is_app_data"):source.index("@interface CYCleanerItem")]
            code = PREAMBLE + constants + helpers + FIXTURES
            code += 'int main(void) { @autoreleasepool { mkdirp(kCleanerAppDataPrefix);\n' + SCENARIOS
            code += '\nputs("cleaner helper regressions: PASS"); } return 0; }\n'
            harness = base / "harness.m"
            harness.write_text(code)
            executable = base / "harness"
            subprocess.run(["xcrun", "clang", "-fobjc-arc", "-fblocks", "-framework", "Foundation", str(harness), "-o", str(executable)], check=True)
            subprocess.run([str(executable)], check=True)

if __name__ == "__main__":
    unittest.main()
