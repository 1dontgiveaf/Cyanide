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
check(cleaner_clear_directory(cache, &removed, &failed) == 0 && failed > 0, "ancestor clear refused");
check(exists(document), "document survives Library symlink");

// An otherwise valid UUID container may itself be a symlink.
NSString *outside = [kCleanerAppDataPrefix.stringByDeletingLastPathComponent stringByAppendingPathComponent:@"outside"];
put([outside stringByAppendingPathComponent:@"tmp/keep.txt"], 512);
NSString *linkedContainer = [kCleanerAppDataPrefix stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
check(symlink(outside.fileSystemRepresentation, linkedContainer.fileSystemRepresentation) == 0, "container link");
check(cleaner_clear_directory([linkedContainer stringByAppendingPathComponent:@"tmp"], &removed, &failed) == 0 && failed > 0, "container link refused");
check(exists([outside stringByAppendingPathComponent:@"tmp/keep.txt"]), "external target survives");

// Even within a valid container, arbitrary nested tmp/Caches roots are forbidden.
NSString *nested = [a stringByAppendingPathComponent:@"Documents/tmp"];
put([nested stringByAppendingPathComponent:@"keep.txt"], 256);
check(!cleaner_is_disposable_root(nested), "nested root guard");
cleaner_clear_directory(nested, &removed, &failed);
check(exists([nested stringByAppendingPathComponent:@"keep.txt"]), "nested document survives");

// A link INSIDE the disposable root is unlinked; its target is never followed.
a = app(); cache = [a stringByAppendingPathComponent:@"Library/Caches"];
mkdirp(cache); document = [a stringByAppendingPathComponent:@"Documents/keep.txt"]; put(document, 128);
NSString *link = [cache stringByAppendingPathComponent:@"link"];
check(symlink(document.fileSystemRepresentation, link.fileSystemRepresentation) == 0, "child link");
cleaner_clear_directory(cache, &removed, &failed);
struct stat st;
check(lstat(link.fileSystemRepresentation, &st) != 0 && exists(document), "child link removed without target deletion");
check(exists(cache), "cache root preserved");

// Normal nested files remain cleanable using the descriptor walk.
put([cache stringByAppendingPathComponent:@"nested/file.bin"], 1024);
check(cleaner_tree_bytes(cache, NULL, &complete) == 1024 && complete, "normal scan");
check(cleaner_clear_directory(cache, &removed, &failed) == 1024 && removed == 1 && failed == 0, "normal clear");
check(exists(cache) && !exists([cache stringByAppendingPathComponent:@"nested"]), "only root contents removed");
'''

class CleanerHelperTests(unittest.TestCase):
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
