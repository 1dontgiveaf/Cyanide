//
//  font_overwrite.m
//  Cyanide
//
//  See font_overwrite.h.
//

#import "font_overwrite.h"
#import "../LogTextView.h"
#import "../TaskRop/RemoteCall.h"
#import "../TaskRop/VM.h"
#import "../kexploit/kutils.h"
#import "../kexploit/kexploit_opa334.h"
#import "../utils/process.h"
#import <fcntl.h>
#import <sys/mman.h>
#import <sys/stat.h>
#import <unistd.h>

// Cyanide's own VM map, through the kernel.
static uint64_t fontow_own_vm_map(void)
{
    char comm[64] = {0};
    uint64_t kproc = 0;
    if (procmgr_identity_for_pid(getpid(), comm, sizeof(comm), &kproc) != 0 || !kproc) return 0;
    uint64_t task = proc_task(kproc);
    return task ? task_get_vm_map(task) : 0;
}

// The VM map entry of ours that contains `address`.
static bool fontow_entry_for(uint64_t map, uint64_t address, struct VMEntryInfo *out)
{
    __block bool found = false;
    vm_map_iterate_entries(map, ^(uint64_t start, uint64_t end, uint64_t entry, BOOL *stop) {
        if (address < start || address >= end) return;
        found = vm_map_entry_info(entry, out);
        *stop = YES;
    });
    return found;
}

// A rarely used font to test on: one from CoreAddition (scripts most people
// never display), not emoji and not San Francisco.
static NSString *fontow_test_file(void)
{
    NSString *dir = @"/System/Library/Fonts/CoreAddition";
    NSArray *names = [[NSFileManager.defaultManager contentsOfDirectoryAtPath:dir error:nil]
                      sortedArrayUsingSelector:@selector(compare:)];
    for (NSString *name in names) {
        NSString *ext = name.pathExtension.lowercaseString;
        if (![ext isEqualToString:@"ttc"] && ![ext isEqualToString:@"ttf"]) continue;
        if ([name containsString:@"Emoji"] || [name hasPrefix:@"SF"]) continue;
        return [dir stringByAppendingPathComponent:name];
    }
    return nil;
}

// The byte at `offset` as a fresh descriptor sees it (the file cache).
static int fontow_read_byte(const char *path, off_t offset)
{
    int fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0) return -1;
    uint8_t b = 0;
    ssize_t n = pread(fd, &b, 1, offset);
    close(fd);
    return n == 1 ? b : -1;
}

bool fontow_selftest(NSString **result)
{
    __autoreleasing NSString *dummy = nil;
    if (!result) result = &dummy;
    if (!kexploit_krw_ready()) { *result = @"Kernel access isn't active."; return false; }
    NSString *file = fontow_test_file();
    if (!file) { *result = @"No test font found in /System/Library/Fonts/CoreAddition."; return false; }
    const char *path = file.fileSystemRepresentation;

    int fd = open(path, O_RDONLY | O_CLOEXEC);
    struct stat st;
    if (fd < 0 || fstat(fd, &st) != 0 || st.st_size < 1) {
        if (fd >= 0) close(fd);
        *result = [NSString stringWithFormat:@"%@ can't be read.", file.lastPathComponent];
        return false;
    }
    size_t page = (size_t)getpagesize();
    off_t target = st.st_size - 1;                         // the last byte
    off_t pageOff = target & ~(off_t)(page - 1);
    uint8_t *map = mmap(NULL, (size_t)st.st_size, PROT_READ, MAP_SHARED, fd, 0);
    close(fd);
    if (map == MAP_FAILED) { *result = @"The test font couldn't be mapped."; return false; }
    uint8_t original = map[target];                        // also faults the page in
    printf("[FONTOW] test file %s, %lld bytes, last byte 0x%02x\n", path, (long long)st.st_size, original);

    bool ok = false;
    NSString *why = nil;
    struct VMShmem w = {0};
    do {
        uint64_t vmMap = fontow_own_vm_map();
        struct VMEntryInfo e;
        uint64_t pageAddr = (uint64_t)(uintptr_t)(map + pageOff);
        if (!vmMap || !fontow_entry_for(vmMap, pageAddr, &e) || !e.object) {
            why = @"The mapping's file object wasn't found.";
            break;
        }
        printf("[FONTOW] entry 0x%llx-0x%llx prot=%x object=0x%llx offset=0x%llx\n",
               e.start, e.end, e.protection, e.object, e.offset);
        w = vm_map_object_range(e.object, e.offset + (pageAddr - e.start), page);
        if (!w.used) { why = @"The file's page couldn't be mapped writable."; break; }
        uint8_t *dst = (uint8_t *)(uintptr_t)w.localAddress + (target - pageOff);
        if (*dst != original) {
            why = [NSString stringWithFormat:@"The writable mapping shows 0x%02x, the file 0x%02x: not the same page.", *dst, original];
            break;
        }
        // The write, the check through a new descriptor, and the restore.
        *dst = original ^ 0xFF;
        int seen = fontow_read_byte(path, target);
        *dst = original;
        int restored = fontow_read_byte(path, target);
        printf("[FONTOW] wrote 0x%02x, file read back 0x%02x, restored -> 0x%02x\n",
               original ^ 0xFF, seen & 0xFF, restored & 0xFF);
        if (seen != (original ^ 0xFF)) { why = @"The write didn't reach the file cache (other processes would still see the original)."; break; }
        if (restored != original) { why = @"The write worked, but the restore didn't. A reboot brings the original back."; break; }
        ok = true;
    } while (0);
    if (w.used) vm_shmem_release(&w, page);
    munmap(map, (size_t)st.st_size);

    *result = ok ? [NSString stringWithFormat:@"Write test passed on %@: changed in the file cache, seen by a new reader, and restored.",
                    file.lastPathComponent]
                 : why;
    log_user("[FONTOW] Write test: %s\n", (*result).UTF8String);
    return ok;
}
