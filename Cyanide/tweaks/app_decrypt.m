//
//  app_decrypt.m
//  Cyanide
//
//  Decrypted IPAs of installed App Store apps. Idea from lara by rooootdev
//  (kexploit/decrypt.m); implemented differently: lara launches the app and
//  walks its vm_map with kernel reads, and leaves app extensions encrypted.
//  Here every Mach-O is decrypted by mapping it into Cyanide and asking the
//  kernel's FairPlay pager to decrypt that mapping (mremap_encrypted, as
//  flexdecrypt does). A range that isn't 16 KB aligned cannot use mremap;
//  that executable is started suspended, its decrypted pages are read from
//  the task, and it is killed before it can run its UI.
//

#import "app_decrypt.h"
#import "../FBAppContainers.h"
#import "../LogTextView.h"
#import "remote_objc.h"
#import "../TaskRop/RemoteCall.h"
#import <UIKit/UIKit.h>
#import <mach-o/loader.h>
#import <mach-o/fat.h>
#import <dlfcn.h>
#import <fcntl.h>
#import <spawn.h>
#import <sys/wait.h>
#import <mach/mach.h>
#import <mach/task_info.h>
#import <mach/thread_act.h>
#import <mach/arm/thread_status.h>
#import <sys/mman.h>
#import <sys/stat.h>
#import <unistd.h>
#import <zlib.h>

#pragma mark - App list

NSArray<NSDictionary *> *app_decrypt_store_apps(void)
{
    NSString *root = @"/var/containers/Bundle/Application";
    NSFileManager *fm = NSFileManager.defaultManager;
    NSMutableArray *apps = [NSMutableArray array];
    for (NSString *uuid in [fm contentsOfDirectoryAtPath:root error:nil]) {
        NSString *container = [root stringByAppendingPathComponent:uuid];
        for (NSString *item in [fm contentsOfDirectoryAtPath:container error:nil]) {
            if (![item.pathExtension isEqualToString:@"app"]) continue;
            NSString *appPath = [container stringByAppendingPathComponent:item];
            // App Store installs carry FairPlay info; sideloaded ones a profile.
            BOOL isDir = NO;
            if (![fm fileExistsAtPath:[appPath stringByAppendingPathComponent:@"SC_Info"] isDirectory:&isDir] || !isDir) continue;
            if ([fm fileExistsAtPath:[appPath stringByAppendingPathComponent:@"embedded.mobileprovision"]]) continue;
            NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:[appPath stringByAppendingPathComponent:@"Info.plist"]];
            NSString *bid = [info[@"CFBundleIdentifier"] isKindOfClass:NSString.class] ? info[@"CFBundleIdentifier"] : @"";
            NSString *version = [info[@"CFBundleShortVersionString"] isKindOfClass:NSString.class] ? info[@"CFBundleShortVersionString"] : @"";
            FBAppContainer *c = fb_container_for_path(container, NO);
            NSString *name = c.displayName.length ? c.displayName
                           : ([info[@"CFBundleDisplayName"] isKindOfClass:NSString.class] ? info[@"CFBundleDisplayName"]
                           : item.stringByDeletingPathExtension);
            NSMutableDictionary *app = [@{ @"name": name, @"bundleID": bid, @"version": version, @"path": appPath } mutableCopy];
            if (c.icon) app[@"icon"] = c.icon;
            [apps addObject:app];
        }
    }
    [apps sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [a[@"name"] localizedCaseInsensitiveCompare:b[@"name"]];
    }];
    return apps;
}

NSString *app_decrypt_output_dir(void)
{
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSString *dir = [docs stringByAppendingPathComponent:@"Decrypted"];
    [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return dir;
}

#pragma mark - Mach-O

typedef struct {
    uint64_t sliceOffset;
    uint32_t cputype, cpusubtype;
    uint32_t cryptoff, cryptsize, cryptid;
    uint64_t cryptidFileOffset;   // where to write cryptid = 0
    uint32_t filetype;            // MH_EXECUTE for apps/extensions
} ADEncryptedSlice;

static BOOL ad_pread_all(int fd, void *buf, size_t len, off_t off)
{
    uint8_t *p = buf;
    while (len) {
        ssize_t n = pread(fd, p, len, off);
        if (n <= 0) return NO;
        p += n; len -= (size_t)n; off += n;
    }
    return YES;
}

static BOOL ad_pwrite_all(int fd, const void *buf, size_t len, off_t off)
{
    const uint8_t *p = buf;
    while (len) {
        ssize_t n = pwrite(fd, p, len, off);
        if (n <= 0) return NO;
        p += n; len -= (size_t)n; off += n;
    }
    return YES;
}

// The encrypted 64-bit slice at `off`, if any (cryptid != 0).
static BOOL ad_parse_slice(int fd, uint64_t off, uint64_t fileSize, ADEncryptedSlice *out)
{
    struct mach_header_64 mh;
    if (off + sizeof(mh) > fileSize || !ad_pread_all(fd, &mh, sizeof(mh), (off_t)off)) return NO;
    if (mh.magic != MH_MAGIC_64 || mh.sizeofcmds > 16 * 1024 * 1024) return NO;
    NSMutableData *cmds = [NSMutableData dataWithLength:mh.sizeofcmds];
    uint64_t cmdsOff = off + sizeof(mh);
    if (cmdsOff + mh.sizeofcmds > fileSize || !ad_pread_all(fd, cmds.mutableBytes, mh.sizeofcmds, (off_t)cmdsOff)) return NO;
    const uint8_t *p = cmds.bytes, *end = p + cmds.length;
    for (uint32_t i = 0; i < mh.ncmds && p + sizeof(struct load_command) <= end; i++) {
        const struct load_command *lc = (const void *)p;
        if (lc->cmdsize < sizeof(struct load_command) || p + lc->cmdsize > end) return NO;
        if (lc->cmd == LC_ENCRYPTION_INFO_64 && lc->cmdsize >= sizeof(struct encryption_info_command_64)) {
            const struct encryption_info_command_64 *e = (const void *)p;
            if (e->cryptid == 0) return NO;
            out->sliceOffset = off;
            out->cputype = (uint32_t)mh.cputype;
            out->cpusubtype = (uint32_t)mh.cpusubtype;
            out->filetype = (uint32_t)mh.filetype;
            out->cryptoff = e->cryptoff;
            out->cryptsize = e->cryptsize;
            out->cryptid = e->cryptid;
            out->cryptidFileOffset = cmdsOff + (uint64_t)(p - (const uint8_t *)cmds.bytes)
                                   + offsetof(struct encryption_info_command_64, cryptid);
            return YES;
        }
        p += lc->cmdsize;
    }
    return NO;
}

// Every encrypted slice of the file (thin or fat). NO when it isn't a Mach-O.
static BOOL ad_encrypted_slices(int fd, uint64_t fileSize, NSMutableArray<NSValue *> *slices)
{
    uint32_t magic = 0;
    if (fileSize < 4 || !ad_pread_all(fd, &magic, 4, 0)) return NO;
    ADEncryptedSlice s;
    if (magic == MH_MAGIC_64) {
        if (ad_parse_slice(fd, 0, fileSize, &s)) [slices addObject:[NSValue valueWithBytes:&s objCType:@encode(ADEncryptedSlice)]];
        return YES;
    }
    if (magic == FAT_CIGAM || magic == FAT_CIGAM_64) {
        BOOL is64 = magic == FAT_CIGAM_64;
        struct fat_header fh;
        if (!ad_pread_all(fd, &fh, sizeof(fh), 0)) return NO;
        uint32_t n = OSSwapBigToHostInt32(fh.nfat_arch);
        if (n > 32) return NO;
        uint64_t at = sizeof(fh);
        for (uint32_t i = 0; i < n; i++) {
            uint64_t sliceOff;
            if (is64) {
                struct fat_arch_64 fa;
                if (!ad_pread_all(fd, &fa, sizeof(fa), (off_t)at)) return NO;
                sliceOff = OSSwapBigToHostInt64(fa.offset);
                at += sizeof(fa);
            } else {
                struct fat_arch fa;
                if (!ad_pread_all(fd, &fa, sizeof(fa), (off_t)at)) return NO;
                sliceOff = OSSwapBigToHostInt32(fa.offset);
                at += sizeof(fa);
            }
            if (ad_parse_slice(fd, sliceOff, fileSize, &s))
                [slices addObject:[NSValue valueWithBytes:&s objCType:@encode(ADEncryptedSlice)]];
        }
        return YES;
    }
    return magic == MH_MAGIC || magic == FAT_MAGIC;   // 32-bit / other-endian: a Mach-O, never encrypted here
}

typedef int (*ADMremapEncrypted)(void *addr, size_t len, uint32_t cryptid, uint32_t cputype, uint32_t cpusubtype);

// errno inside SpringBoard after a failed call.
static int ad_sb_errno(void)
{
    uint64_t p = r_dlsym_call(R_TIMEOUT, "__error", 0, 0, 0, 0, 0, 0, 0, 0);
    int e = 0;
    if (p && !remote_read(p, &e, sizeof(e))) e = 0;
    return e;
}

// The same decryption done by SpringBoard (unsandboxed; a crash there is only
// a respring): it maps `src`, has the kernel decrypt the range and writes the
// plaintext into `dst` (Cyanide's working copy) at the same offset. Needs an
// open SpringBoard session.
static BOOL ad_decrypt_range_in_springboard(NSString *src, NSString *dst, uint64_t aligned, size_t mapLen,
                                            size_t delta, uint64_t start, const void *slicePtr, NSString **why)
{
    const ADEncryptedSlice *s = slicePtr;
    uint64_t rsrc = r_alloc_str(src.fileSystemRepresentation), rdst = r_alloc_str(dst.fileSystemRepresentation);
    int fdIn = -1, fdOut = -1;
    uint64_t map = 0;
    BOOL ok = NO;
    do {
        if (!rsrc || !rdst) { *why = @"SpringBoard: no memory for the paths"; break; }
        fdIn = (int)r_dlsym_call(R_TIMEOUT, "open", rsrc, O_RDONLY | O_CLOEXEC, 0, 0, 0, 0, 0, 0);
        if (fdIn < 0) { *why = [NSString stringWithFormat:@"SpringBoard: open failed (%s)", strerror(ad_sb_errno())]; break; }
        map = r_dlsym_call(R_TIMEOUT, "mmap", 0, mapLen, PROT_READ, MAP_PRIVATE, (uint64_t)fdIn, aligned, 0, 0);
        if (!map || map == (uint64_t)-1) {
            map = 0;
            *why = [NSString stringWithFormat:@"SpringBoard: mmap failed (%s)", strerror(ad_sb_errno())];
            break;
        }
        // Same variants as in Cyanide: subtype as in the header, then without
        // its capability bits.
        uint32_t subtypes[2] = { s->cpusubtype, s->cpusubtype & ~(uint32_t)CPU_SUBTYPE_MASK };
        int r = -1, e = 0;
        for (int v = 0; v < 2 && r != 0; v++) {
            if (v == 1 && subtypes[1] == subtypes[0]) break;
            r = (int)r_dlsym_call(R_TIMEOUT, "mremap_encrypted", map, mapLen, s->cryptid, s->cputype, subtypes[v], 0, 0, 0);
            if (r != 0) e = ad_sb_errno();
            printf("[DECRYPT]   springboard variant %d (subtype 0x%x): %s\n", v, subtypes[v], r == 0 ? "ok" : strerror(e));
        }
        if (r != 0) { *why = [NSString stringWithFormat:@"SpringBoard: mremap_encrypted failed (%s)", strerror(e)]; break; }
        fdOut = (int)r_dlsym_call(R_TIMEOUT, "open", rdst, O_WRONLY | O_CLOEXEC, 0, 0, 0, 0, 0, 0);
        if (fdOut < 0) { *why = [NSString stringWithFormat:@"SpringBoard: can't write the copy (%s)", strerror(ad_sb_errno())]; break; }
        uint64_t done = 0, size = s->cryptsize;
        ok = YES;
        while (done < size) {
            uint64_t chunk = MIN(size - done, 8ULL * 1024 * 1024);   // keeps each call short
            int64_t n = (int64_t)r_dlsym_call(R_TIMEOUT, "pwrite", (uint64_t)fdOut, map + delta + done, chunk, start + done, 0, 0, 0, 0);
            if (n <= 0 || !r_last_call_ok()) { *why = @"SpringBoard: writing the decrypted bytes failed"; ok = NO; break; }
            done += (uint64_t)n;
        }
    } while (0);
    if (map) r_dlsym_call(R_TIMEOUT, "munmap", map, mapLen, 0, 0, 0, 0, 0, 0);
    if (fdIn >= 0) r_dlsym_call(R_TIMEOUT, "close", (uint64_t)fdIn, 0, 0, 0, 0, 0, 0, 0);
    if (fdOut >= 0) r_dlsym_call(R_TIMEOUT, "close", (uint64_t)fdOut, 0, 0, 0, 0, 0, 0, 0);
    if (rsrc) r_free(rsrc);
    if (rdst) r_free(rdst);
    return ok;
}

// Read a range from a freshly spawned (suspended) task.
static BOOL ad_task_read(task_t task, uint64_t addr, void *buf, size_t len)
{
    vm_size_t got = 0;
    kern_return_t kr = vm_read_overwrite(task, (vm_address_t)addr,
        (vm_size_t)len, (vm_address_t)(uintptr_t)buf, &got);
    return kr == KERN_SUCCESS && got == (vm_size_t)len;
}

// The main executable's Mach-O header in a suspended task. dyld's
// all_image_infos is available once the process is mapped; the stack slot is
// the fallback flexdecrypt uses.
static uint64_t ad_task_main_header(task_t task)
{
    struct task_dyld_info tdi;
    mach_msg_type_number_t tdiCount = TASK_DYLD_INFO_COUNT;
    if (task_info(task, TASK_DYLD_INFO, (task_info_t)&tdi, &tdiCount) == KERN_SUCCESS &&
        tdi.all_image_info_addr) {
        struct {
            uint32_t version;
            uint32_t count;
            uint64_t infoArray;
        } ai = {0};
        if (ad_task_read(task, tdi.all_image_info_addr, &ai, sizeof(ai)) &&
            ai.infoArray && ai.count) {
            uint64_t firstImage = 0;
            if (ad_task_read(task, ai.infoArray, &firstImage, sizeof(firstImage)) &&
                firstImage) return firstImage;
        }
    }
    thread_act_array_t threads = NULL;
    mach_msg_type_number_t threadCount = 0;
    if (task_threads(task, &threads, &threadCount) != KERN_SUCCESS) return 0;
    uint64_t header = 0;
    if (threads && threadCount) {
        arm_thread_state64_t state;
        mach_msg_type_number_t stateCount = ARM_THREAD_STATE64_COUNT;
        if (thread_get_state(threads[0], ARM_THREAD_STATE64,
                             (thread_state_t)&state, &stateCount) == KERN_SUCCESS) {
            uint64_t sp = (uint64_t)arm_thread_state64_get_sp(state);
            uint64_t slots[4] = {0};
            if (ad_task_read(task, sp, slots, sizeof(slots))) {
                for (int i = 0; i < 4 && !header; i++) {
                    uint32_t magic = 0;
                    if (slots[i] && ad_task_read(task, slots[i], &magic, sizeof(magic)) &&
                        (magic == MH_MAGIC_64 || magic == MH_MAGIC ||
                         magic == FAT_MAGIC || magic == FAT_CIGAM ||
                         magic == FAT_MAGIC_64 || magic == FAT_CIGAM_64))
                        header = slots[i];
                }
            }
        }
    }
    if (threads) {
        for (mach_msg_type_number_t i = 0; i < threadCount; i++)
            mach_port_deallocate(mach_task_self(), threads[i]);
        vm_deallocate(mach_task_self(), (vm_address_t)threads,
                      (vm_size_t)threadCount * sizeof(thread_act_t));
    }
    return header;
}

// For an executable whose encrypted range starts off a 16 KB boundary,
// mremap_encrypted cannot work: mmap and mremap both require 16 KB alignment.
// Flexdecrypt handles this case by launching the app suspended, letting the
// kernel decrypt its pages, and reading the encrypted range back from the
// task. We do the same locally; if the sandbox refuses task_for_pid, the
// caller falls back to the existing SpringBoard path.
static BOOL ad_decrypt_range_in_spawned_process(NSString *src, int out, uint64_t start,
                                                const ADEncryptedSlice *s, NSString **why)
{
    if (s->filetype != MH_EXECUTE) {
        *why = @"not a spawned executable";
        return NO;
    }
    if (!s->cryptsize || s->cryptsize > 256u * 1024u * 1024u) {
        *why = @"implausible encrypted size";
        return NO;
    }
    const char *path = src.fileSystemRepresentation;
    posix_spawnattr_t attr;
    if (posix_spawnattr_init(&attr) != 0) { *why = @"posix_spawnattr_init failed"; return NO; }
    sigset_t empty;
    sigemptyset(&empty);
    posix_spawnattr_setsigmask(&attr, &empty);
    posix_spawnattr_setflags(&attr, POSIX_SPAWN_START_SUSPENDED | POSIX_SPAWN_SETPGROUP);
    extern char **environ;
    char *argv[] = { (char *)path, NULL };
    pid_t pid = 0;
    int rc = posix_spawn(&pid, path, NULL, &attr, argv, environ);
    posix_spawnattr_destroy(&attr);
    if (rc != 0 || pid <= 0) {
        // Some app executables refuse the suspended flag but can still be
        // started normally; kill it immediately after the read.
        printf("[DECRYPT]   spawn with STOPPED: %s; retrying without the attribute\n", strerror(rc));
        pid = 0;
        rc = posix_spawn(&pid, path, NULL, NULL, argv, environ);
        if (rc != 0 || pid <= 0) {
            *why = [NSString stringWithFormat:@"posix_spawn: %s", strerror(rc)];
            return NO;
        }
    }
    mach_port_t task = MACH_PORT_NULL;
    kern_return_t kr = task_for_pid(mach_task_self(), pid, &task);
    if (kr != KERN_SUCCESS || task == MACH_PORT_NULL) {
        kill(pid, SIGKILL);
        waitpid(pid, NULL, 0);
        *why = [NSString stringWithFormat:@"task_for_pid: 0x%x", kr];
        return NO;
    }
    uint64_t header = ad_task_main_header(task);
    BOOL ok = NO;
    void *buf = NULL;
    if (!header) {
        *why = @"no Mach-O header in the spawned task";
    } else {
        struct mach_header_64 mh;
        if (!ad_task_read(task, header, &mh, sizeof(mh)) ||
            mh.magic != MH_MAGIC_64) {
            *why = @"spawned task header is not a thin 64-bit Mach-O";
        } else if ((uint32_t)mh.cputype != s->cputype) {
            *why = @"spawned task runs a different CPU slice";
        } else {
            buf = malloc(s->cryptsize);
            if (!buf) {
                *why = @"no memory for the decrypted range";
            } else if (!ad_task_read(task, header + s->cryptoff, buf, s->cryptsize)) {
                *why = @"reading the spawned task's encrypted range failed";
            } else if (!ad_pwrite_all(out, buf, s->cryptsize, (off_t)start)) {
                *why = @"writing the spawned task's plaintext failed";
            } else {
                printf("[DECRYPT]   spawn pid %d header 0x%llx read 0x%x bytes at 0x%llx: ok\n",
                       pid, header, s->cryptsize, header + s->cryptoff);
                ok = YES;
            }
        }
    }
    free(buf);
    kill(pid, SIGKILL);
    waitpid(pid, NULL, 0);
    mach_port_deallocate(mach_task_self(), task);
    return ok;
}

// --- SpringBoard spawn fallback --------------------------------------------
// If Cyanide's sandbox refuses task_for_pid, SpringBoard is the next process
// that can spawn the executable and read its task. The helpers below use the
// existing RemoteCall session; no kernel read is involved.

static uint64_t ad_sb_alloc(size_t n)
{
    uint64_t p = r_dlsym_call(R_TIMEOUT, "malloc", (uint64_t)n, 0, 0, 0, 0, 0, 0, 0);
    return r_last_call_ok() ? p : 0;
}

static void ad_sb_free(uint64_t p)
{
    if (p) r_dlsym_call(R_TIMEOUT, "free", p, 0, 0, 0, 0, 0, 0, 0);
}

static uint64_t ad_sb_dlsym(const char *name)
{
    uint64_t s = r_alloc_str(name);
    if (!s) return 0;
    uint64_t p = r_dlsym_call(R_TIMEOUT, "dlsym", (uint64_t)(intptr_t)RTLD_DEFAULT, s, 0, 0, 0, 0, 0, 0);
    r_free(s);
    return r_last_call_ok() ? p : 0;
}

static uint64_t ad_sb_task_self(void)
{
    uint64_t sym = ad_sb_dlsym("mach_task_self_");
    uint32_t port = 0;
    if (!sym || !remote_read(sym, &port, sizeof(port))) return 0;
    return port;
}

static uint64_t ad_sb_env(void)
{
    uint64_t sym = ad_sb_dlsym("environ");
    uint64_t envp = 0;
    if (sym) remote_read(sym, &envp, sizeof(envp));
    return envp;
}

static BOOL ad_sb_vm_read(uint64_t task, uint64_t addr, uint64_t scratch, uint64_t gotp, size_t len)
{
    remote_write64(gotp, 0);
    uint64_t kr = r_dlsym_call(R_TIMEOUT, "vm_read_overwrite", task, addr, len, scratch, gotp, 0, 0, 0);
    uint64_t got = 0;
    remote_read(gotp, &got, sizeof(got));
    return (int)kr == 0 && got == len && r_last_call_ok();
}

static uint64_t ad_sb_main_header(uint64_t task, uint64_t self)
{
    uint64_t tdi = ad_sb_alloc(64), tdiCount = ad_sb_alloc(4);
    uint64_t allImage = 0;
    if (!tdi || !tdiCount) { ad_sb_free(tdi); ad_sb_free(tdiCount); return 0; }
    uint32_t tdiC = TASK_DYLD_INFO_COUNT;
    remote_write(tdiCount, &tdiC, sizeof(tdiC));
    uint64_t tiRc = r_dlsym_call(R_TIMEOUT, "task_info", task, TASK_DYLD_INFO, tdi, tdiCount, 0, 0, 0, 0);
    if ((int)tiRc == 0 && r_last_call_ok())
        remote_read(tdi, &allImage, sizeof(allImage));
    ad_sb_free(tdi); ad_sb_free(tdiCount);
    if (allImage) {
        uint64_t ai = ad_sb_alloc(24), gotp = ad_sb_alloc(8);
        uint64_t infoArray = 0, header = 0;
        if (ai && gotp && ad_sb_vm_read(task, allImage, ai, gotp, 24)) {
            remote_read(ai + 8, &infoArray, sizeof(infoArray));
            if (infoArray) {
                uint64_t first = ad_sb_alloc(8);
                if (first && ad_sb_vm_read(task, infoArray, first, gotp, 8))
                    remote_read(first, &header, sizeof(header));
                ad_sb_free(first);
            }
        }
        ad_sb_free(ai); ad_sb_free(gotp);
        if (header) return header;
    }
    // dyld may not have published all_image_infos yet: read the first
    // suspended thread's stack slots, exactly as the local helper does.
    uint64_t threadsPtr = ad_sb_alloc(8), countPtr = ad_sb_alloc(4);
    uint64_t header = 0;
    if (!threadsPtr || !countPtr) { ad_sb_free(threadsPtr); ad_sb_free(countPtr); return 0; }
    uint64_t zeroThreads = 0;
    remote_write(threadsPtr, &zeroThreads, sizeof(zeroThreads));
    uint32_t zeroCount = 0;
    remote_write(countPtr, &zeroCount, sizeof(zeroCount));
    r_dlsym_call(R_TIMEOUT, "task_threads", task, threadsPtr, countPtr, 0, 0, 0, 0, 0);
    uint64_t threads = 0; uint32_t count = 0;
    remote_read(threadsPtr, &threads, sizeof(threads));
    remote_read(countPtr, &count, sizeof(count));
    if (threads && count) {
        uint32_t thread = 0;
        remote_read(threads, &thread, sizeof(thread));
        uint64_t statep = ad_sb_alloc(512), stateCountp = ad_sb_alloc(4);
        if (thread && statep && stateCountp) {
            uint32_t stateCount = ARM_THREAD_STATE64_COUNT;
            remote_write(stateCountp, &stateCount, sizeof(stateCount));
            r_dlsym_call(R_TIMEOUT, "thread_get_state", thread, ARM_THREAD_STATE64, statep, stateCountp, 0, 0, 0, 0);
            arm_thread_state64_t state;
            if (remote_read(statep, &state, sizeof(state))) {
                uint64_t sp = (uint64_t)arm_thread_state64_get_sp(state);
                uint64_t scratch = ad_sb_alloc(32), gotp = ad_sb_alloc(8);
                if (sp && scratch && gotp && ad_sb_vm_read(task, sp, scratch, gotp, 32)) {
                    uint64_t slots[4] = {0};
                    remote_read(scratch, slots, sizeof(slots));
                    for (int i = 0; i < 4 && !header; i++) {
                        if (!slots[i]) continue;
                        uint32_t magic = 0;
                        if (ad_sb_vm_read(task, slots[i], scratch, gotp, sizeof(magic))) {
                            remote_read(scratch, &magic, sizeof(magic));
                            if (magic == MH_MAGIC_64 || magic == MH_MAGIC ||
                                magic == FAT_MAGIC || magic == FAT_CIGAM ||
                                magic == FAT_MAGIC_64 || magic == FAT_CIGAM_64)
                                header = slots[i];
                        }
                    }
                }
                ad_sb_free(scratch); ad_sb_free(gotp);
            }
        }
        ad_sb_free(statep); ad_sb_free(stateCountp);
    }
    ad_sb_free(threadsPtr); ad_sb_free(countPtr);
    (void)self;
    return header;
}

static BOOL ad_decrypt_range_in_springboard_spawn(NSString *src, NSString *dst, uint64_t start,
                                                  const ADEncryptedSlice *s, NSString **why)
{
    if (s->filetype != MH_EXECUTE) { *why = @"SpringBoard: not a spawned executable"; return NO; }
    if (!s->cryptsize || s->cryptsize > 256u * 1024u * 1024u) {
        *why = @"SpringBoard: implausible encrypted size";
        return NO;
    }
    uint64_t self = ad_sb_task_self();
    uint64_t rsrc = r_alloc_str(src.fileSystemRepresentation);
    uint64_t rdst = r_alloc_str(dst.fileSystemRepresentation);
    uint64_t argv = ad_sb_alloc(16), pidp = ad_sb_alloc(4), attrp = ad_sb_alloc(64), taskp = ad_sb_alloc(4);
    uint64_t envp = ad_sb_env();
    BOOL ok = NO;
    uint64_t task = 0, scratch = 0, gotp = 0;
    int fdOut = -1;
    pid_t pid = 0;
    do {
        if (!self || !rsrc || !rdst || !argv || !pidp || !attrp || !taskp) {
            *why = @"SpringBoard: allocation failed"; break;
        }
        remote_write64(argv, rsrc);
        remote_write64(argv + 8, 0);
        uint32_t zeroPid = 0;
        remote_write(pidp, &zeroPid, sizeof(zeroPid));
        if ((int)r_dlsym_call(R_TIMEOUT, "posix_spawnattr_init", attrp, 0, 0, 0, 0, 0, 0, 0) != 0) {
            *why = @"SpringBoard: posix_spawnattr_init failed"; break;
        }
        r_dlsym_call(R_TIMEOUT, "posix_spawnattr_setflags", attrp, POSIX_SPAWN_START_SUSPENDED, 0, 0, 0, 0, 0, 0);
        uint64_t rc = r_dlsym_call(R_TIMEOUT, "posix_spawn", pidp, rsrc, 0, attrp, argv, envp, 0, 0);
        if (!r_last_call_ok() || (int)rc != 0) {
            printf("[DECRYPT]   SpringBoard spawn with STOPPED: %d; retrying without it\n", (int)rc);
            rc = r_dlsym_call(R_TIMEOUT, "posix_spawn", pidp, rsrc, 0, 0, argv, envp, 0, 0);
        }
        if (!r_last_call_ok() || (int)rc != 0) {
            *why = [NSString stringWithFormat:@"SpringBoard: posix_spawn failed (%d)", (int)rc]; break;
        }
        uint32_t p32 = 0;
        remote_read(pidp, &p32, sizeof(p32));
        pid = (pid_t)p32;
        if (!pid) { *why = @"SpringBoard: posix_spawn returned no pid"; break; }
        uint32_t zeroTask = 0;
        remote_write(taskp, &zeroTask, sizeof(zeroTask));
        uint64_t tfp = r_dlsym_call(R_TIMEOUT, "task_for_pid", self, pid, taskp, 0, 0, 0, 0, 0);
        uint32_t t32 = 0;
        remote_read(taskp, &t32, sizeof(t32));
        task = t32;
        if (!r_last_call_ok() || (int)tfp != 0 || !task) {
            *why = [NSString stringWithFormat:@"SpringBoard: task_for_pid failed (%d)", (int)tfp]; break;
        }
        uint64_t header = ad_sb_main_header(task, self);
        if (!header) { *why = @"SpringBoard: no Mach-O header"; break; }
        scratch = ad_sb_alloc(s->cryptsize);
        gotp = ad_sb_alloc(8);
        if (!scratch || !gotp) { *why = @"SpringBoard: no read buffer"; break; }
        if (!ad_sb_vm_read(task, header + s->cryptoff, scratch, gotp, s->cryptsize)) {
            *why = @"SpringBoard: reading the task range failed"; break;
        }
        fdOut = (int)r_dlsym_call(R_TIMEOUT, "open", rdst, O_WRONLY | O_CLOEXEC, 0, 0, 0, 0, 0, 0);
        if (fdOut < 0) { *why = @"SpringBoard: opening the working copy failed"; break; }
        uint64_t done = 0;
        while (done < s->cryptsize) {
            size_t chunk = (size_t)MIN((uint64_t)s->cryptsize - done, 1024ULL * 1024ULL);
            int64_t n = (int64_t)r_dlsym_call(R_TIMEOUT, "pwrite", (uint64_t)fdOut,
                                              scratch + done, chunk, start + done, 0, 0, 0, 0);
            if (n <= 0 || !r_last_call_ok()) { *why = @"SpringBoard: writing the range failed"; break; }
            done += (uint64_t)n;
        }
        if (done != s->cryptsize) break;
        printf("[DECRYPT]   springboard spawn pid %d header 0x%llx read 0x%x bytes: ok\n",
               pid, header, s->cryptsize);
        ok = YES;
    } while (0);
    if (fdOut >= 0) r_dlsym_call(R_TIMEOUT, "close", (uint64_t)fdOut, 0, 0, 0, 0, 0, 0, 0);
    if (pid) {
        r_dlsym_call(R_TIMEOUT, "kill", (uint64_t)pid, SIGKILL, 0, 0, 0, 0, 0, 0);
        r_dlsym_call(R_TIMEOUT, "waitpid", (uint64_t)pid, 0, 0, 0, 0, 0, 0, 0);
    }
    if (task) r_dlsym_call(R_TIMEOUT, "mach_port_deallocate", self, task, 0, 0, 0, 0, 0, 0);
    ad_sb_free(scratch); ad_sb_free(gotp);
    ad_sb_free(argv); ad_sb_free(pidp); ad_sb_free(attrp); ad_sb_free(taskp);
    if (rsrc) r_free(rsrc);
    if (rdst) r_free(rdst);
    return ok;
}

// Writes a copy of `src` with every encrypted slice decrypted and its cryptid
// cleared to `dst`. *decrypted is NO when the file had nothing encrypted.
static BOOL ad_decrypt_file(NSString *src, NSString *dst, BOOL useSpringBoard, BOOL *decrypted, NSString **errorOut)
{
    static dispatch_once_t adBuildOnce;
    dispatch_once(&adBuildOnce, ^{
        printf("[DECRYPT] spawn fallback active (compiled %s %s)\n", __DATE__, __TIME__);
    });
    *decrypted = NO;
    static ADMremapEncrypted mremapEncrypted;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ mremapEncrypted = (ADMremapEncrypted)dlsym(RTLD_DEFAULT, "mremap_encrypted"); });

    int fd = open(src.fileSystemRepresentation, O_RDONLY | O_CLOEXEC);
    if (fd < 0) { *errorOut = [NSString stringWithFormat:@"%@: can't be read (%s)", src.lastPathComponent, strerror(errno)]; return NO; }
    struct stat st;
    fstat(fd, &st);
    NSMutableArray<NSValue *> *slices = [NSMutableArray array];
    ad_encrypted_slices(fd, (uint64_t)st.st_size, slices);
    if (!slices.count) { close(fd); return YES; }
    if (!mremapEncrypted && !useSpringBoard) { close(fd); *errorOut = @"This iOS version has no mremap_encrypted."; return NO; }

    NSError *err = nil;
    [NSFileManager.defaultManager removeItemAtPath:dst error:nil];
    if (![NSFileManager.defaultManager copyItemAtPath:src toPath:dst error:&err]) {
        close(fd);
        *errorOut = [NSString stringWithFormat:@"%@: copy failed (%@)", src.lastPathComponent, err.localizedDescription];
        return NO;
    }
    int out = open(dst.fileSystemRepresentation, O_RDWR | O_CLOEXEC);
    if (out < 0) { close(fd); *errorOut = @"The working copy can't be written."; return NO; }

    size_t page = (size_t)getpagesize();
    BOOL ok = YES;
    for (NSValue *v in slices) {
        ADEncryptedSlice s;
        [v getValue:&s];
        uint64_t start = s.sliceOffset + s.cryptoff;
        // mmap needs a page-aligned offset, and pages are 16 KB on arm64
        // while encrypted ranges are only 4 KB aligned (extensions often):
        // map from the page boundary below and skip `delta` bytes. The pager
        // decrypts by absolute file offset, so the range itself comes out right.
        uint64_t aligned = start & ~((uint64_t)page - 1);
        size_t delta = (size_t)(start - aligned);
        // Whole pages: on a 16 KB system the kernel rejects a partial last
        // page (a 4 KB range in an app extension failed with ENOMEM).
        size_t mapLen = ((delta + s.cryptsize) + page - 1) & ~(page - 1);
        // 1) Here, in Cyanide. If the range is not 16 KB aligned, mmap and
        // mremap_encrypted cannot both be satisfied; for an executable, launch
        // it suspended and read the decrypted range from its task instead
        // (the fallback flexdecrypt uses for applications).
        NSString *localWhy = nil;
        BOOL localOK = NO;
        if ((start % page) && s.filetype == MH_EXECUTE) {
            NSString *spawnWhy = nil;
            localOK = ad_decrypt_range_in_spawned_process(src, out, start, &s, &spawnWhy);
            if (!localOK) localWhy = [@"spawn: " stringByAppendingString:spawnWhy ?: @"failed"];
            if (!localOK && useSpringBoard) {
                NSString *sbSpawnWhy = nil;
                localOK = ad_decrypt_range_in_springboard_spawn(src, dst, start, &s, &sbSpawnWhy);
                if (!localOK)
                    localWhy = [NSString stringWithFormat:@"%@; SpringBoard spawn: %@",
                                localWhy ?: @"spawn failed", sbSpawnWhy ?: @"failed"];
            }
        }
        void *map = NULL;
        if (!localOK) {
            map = mmap(NULL, mapLen, PROT_READ | PROT_EXEC, MAP_PRIVATE, fd, (off_t)aligned);
            if (map == MAP_FAILED) map = mmap(NULL, mapLen, PROT_READ, MAP_PRIVATE, fd, (off_t)aligned);
            if (map == MAP_FAILED) {
                NSString *why = [NSString stringWithFormat:@"mmap: %s", strerror(errno)];
                localWhy = localWhy ? [localWhy stringByAppendingFormat:@"; %@", why] : why;
                map = NULL;
            } else if (!mremapEncrypted) {
                localWhy = localWhy ? [localWhy stringByAppendingString:@"; no mremap_encrypted"] : @"no mremap_encrypted";
            } else {
                // Diagnostics for the device log: what the kernel is being asked.
                printf("[DECRYPT] %s: cpu=0x%x/0x%x cryptid=%u slice=0x%llx cryptoff=0x%x (16K-aligned=%d) map=0x%llx+0x%zx\n",
                       src.lastPathComponent.UTF8String, s.cputype, s.cpusubtype, s.cryptid, s.sliceOffset, s.cryptoff,
                       (int)((start % page) == 0), aligned, mapLen);
                uint32_t subtypes[2] = { s.cpusubtype, s.cpusubtype & ~(uint32_t)CPU_SUBTYPE_MASK };
                int r = -1, e = 0;
                for (int v = 0; v < 2 && r != 0; v++) {
                    if (v == 1 && subtypes[1] == subtypes[0]) break;
                    r = mremapEncrypted(map, mapLen, s.cryptid, s.cputype, subtypes[v]);
                    if (r != 0) e = errno;
                    printf("[DECRYPT]   local variant %d (subtype 0x%x): %s\n", v, subtypes[v], r == 0 ? "ok" : strerror(e));
                }
                if (r != 0) {
                    NSString *why = [NSString stringWithFormat:@"mremap_encrypted: %s", strerror(e)];
                    localWhy = localWhy ? [localWhy stringByAppendingFormat:@"; %@", why] : why;
                } else {
                    localOK = ad_pwrite_all(out, (const uint8_t *)map + delta, s.cryptsize, (off_t)start);
                    if (!localOK) localWhy = localWhy ? [localWhy stringByAppendingString:@"; writing the copy failed"]
                                                       : @"writing the copy failed";
                }
            }
        }
        if (map) munmap(map, mapLen);
        printf("[DECRYPT] %s: off=0x%llx size=0x%x delta=0x%zx local=%s\n", src.lastPathComponent.UTF8String,
               start, s.cryptsize, delta, localOK ? "ok" : localWhy.UTF8String);
        // 2) In SpringBoard, when Cyanide may not decrypt itself.
        if (!localOK) {
            NSString *sbWhy = nil;
            BOOL sbOK = useSpringBoard &&
                ad_decrypt_range_in_springboard(src, dst, aligned, mapLen, delta, start, &s, &sbWhy);
            printf("[DECRYPT] %s: springboard=%s\n", src.lastPathComponent.UTF8String,
                   !useSpringBoard ? "not available" : sbOK ? "ok" : sbWhy.UTF8String);
            if (!sbOK) {
                *errorOut = [NSString stringWithFormat:@"%@: iOS refused to decrypt it (Cyanide: %@%@)", src.lastPathComponent,
                             localWhy, useSpringBoard ? [@"; " stringByAppendingString:sbWhy ?: @"SpringBoard failed"] : @""];
                ok = NO; break;
            }
        }
        // Proof it really decrypted: the copy must differ from the original here.
        uint8_t enc[64], dec[64];
        size_t probe = MIN(sizeof(enc), (size_t)s.cryptsize);
        if (ad_pread_all(fd, enc, probe, (off_t)start) && pread(out, dec, probe, (off_t)start) == (ssize_t)probe &&
            memcmp(enc, dec, probe) == 0) {
            *errorOut = [NSString stringWithFormat:@"%@: the kernel returned still-encrypted data", src.lastPathComponent];
            ok = NO; break;
        }
        uint32_t zero = 0;
        ok = ad_pwrite_all(out, &zero, sizeof(zero), (off_t)s.cryptidFileOffset);
        if (!ok) { *errorOut = @"Writing the decrypted copy failed."; break; }
        printf("[DECRYPT] %s: slice cpu=0x%x off=0x%llx size=0x%x decrypted\n",
               src.lastPathComponent.UTF8String, s.cputype, start, s.cryptsize);
    }
    close(out);
    close(fd);
    if (!ok) [NSFileManager.defaultManager removeItemAtPath:dst error:nil];
    *decrypted = ok;
    return ok;
}

#pragma mark - ZIP (stored, ZIP64 when needed)

@interface ADZipWriter : NSObject
@property (nonatomic) int fd;
@property (nonatomic) uint64_t offset;
@property (nonatomic, strong) NSMutableData *central;
@property (nonatomic) uint64_t entries;
@end

@implementation ADZipWriter

static void ad_put16(NSMutableData *d, uint16_t v) { [d appendBytes:&v length:2]; }
static void ad_put32(NSMutableData *d, uint32_t v) { [d appendBytes:&v length:4]; }
static void ad_put64(NSMutableData *d, uint64_t v) { [d appendBytes:&v length:8]; }

static void ad_dos_time(time_t t, uint16_t *dosTime, uint16_t *dosDate)
{
    struct tm tm;
    localtime_r(&t, &tm);
    if (tm.tm_year < 80) { *dosTime = 0; *dosDate = (1 << 5) | 1; return; }
    *dosTime = (uint16_t)((tm.tm_hour << 11) | (tm.tm_min << 5) | (tm.tm_sec / 2));
    *dosDate = (uint16_t)(((tm.tm_year - 80) << 9) | ((tm.tm_mon + 1) << 5) | tm.tm_mday);
}

- (BOOL)writeData:(NSData *)d
{
    const uint8_t *p = d.bytes;
    size_t left = d.length;
    while (left) {
        ssize_t n = write(self.fd, p, left);
        if (n <= 0) return NO;
        p += n; left -= (size_t)n;
    }
    self.offset += d.length;
    return YES;
}

- (BOOL)addEntry:(NSString *)name mode:(mode_t)mode mtime:(time_t)mtime
            size:(uint64_t)size crc:(uint32_t)crc body:(BOOL (^)(void))body
{
    NSData *nameData = [name dataUsingEncoding:NSUTF8StringEncoding];
    BOOL zip64 = size >= 0xFFFFFFFFULL || self.offset >= 0xFFFFFFFFULL;
    uint16_t t, dt;
    ad_dos_time(mtime, &t, &dt);
    uint64_t localOffset = self.offset;

    NSMutableData *h = [NSMutableData data];
    ad_put32(h, 0x04034b50);
    ad_put16(h, zip64 ? 45 : 20);
    ad_put16(h, 0x0800);                 // UTF-8 names
    ad_put16(h, 0);                      // stored
    ad_put16(h, t); ad_put16(h, dt);
    ad_put32(h, crc);
    ad_put32(h, zip64 ? 0xFFFFFFFF : (uint32_t)size);
    ad_put32(h, zip64 ? 0xFFFFFFFF : (uint32_t)size);
    ad_put16(h, (uint16_t)nameData.length);
    ad_put16(h, zip64 ? 20 : 0);
    [h appendData:nameData];
    if (zip64) { ad_put16(h, 0x0001); ad_put16(h, 16); ad_put64(h, size); ad_put64(h, size); }
    if (![self writeData:h]) return NO;
    if (body && !body()) return NO;

    NSMutableData *c = self.central;
    ad_put32(c, 0x02014b50);
    ad_put16(c, (3 << 8) | 45);         // made by Unix
    ad_put16(c, zip64 ? 45 : 20);
    ad_put16(c, 0x0800);
    ad_put16(c, 0);
    ad_put16(c, t); ad_put16(c, dt);
    ad_put32(c, crc);
    ad_put32(c, zip64 ? 0xFFFFFFFF : (uint32_t)size);
    ad_put32(c, zip64 ? 0xFFFFFFFF : (uint32_t)size);
    ad_put16(c, (uint16_t)nameData.length);
    ad_put16(c, zip64 ? 28 : 0);
    ad_put16(c, 0); ad_put16(c, 0); ad_put16(c, 0);
    ad_put32(c, ((uint32_t)mode << 16) | (S_ISDIR(mode) ? 0x10 : 0));
    ad_put32(c, zip64 ? 0xFFFFFFFF : (uint32_t)localOffset);
    [c appendData:nameData];
    if (zip64) { ad_put16(c, 0x0001); ad_put16(c, 24); ad_put64(c, size); ad_put64(c, size); ad_put64(c, localOffset); }
    self.entries++;
    return YES;
}

- (BOOL)finish
{
    uint64_t cdOffset = self.offset, cdSize = self.central.length;
    if (![self writeData:self.central]) return NO;
    BOOL zip64 = self.entries >= 0xFFFF || cdOffset >= 0xFFFFFFFFULL || cdSize >= 0xFFFFFFFFULL;
    NSMutableData *e = [NSMutableData data];
    if (zip64) {
        uint64_t z64Offset = self.offset;
        ad_put32(e, 0x06064b50); ad_put64(e, 44);
        ad_put16(e, (3 << 8) | 45); ad_put16(e, 45);
        ad_put32(e, 0); ad_put32(e, 0);
        ad_put64(e, self.entries); ad_put64(e, self.entries);
        ad_put64(e, cdSize); ad_put64(e, cdOffset);
        ad_put32(e, 0x07064b50); ad_put32(e, 0); ad_put64(e, z64Offset); ad_put32(e, 1);
    }
    ad_put32(e, 0x06054b50);
    ad_put16(e, 0); ad_put16(e, 0);
    ad_put16(e, zip64 ? 0xFFFF : (uint16_t)self.entries);
    ad_put16(e, zip64 ? 0xFFFF : (uint16_t)self.entries);
    ad_put32(e, zip64 ? 0xFFFFFFFF : (uint32_t)cdSize);
    ad_put32(e, zip64 ? 0xFFFFFFFF : (uint32_t)cdOffset);
    ad_put16(e, 0);
    return [self writeData:e];
}

@end

static BOOL ad_crc_file(NSString *path, uint32_t *crcOut)
{
    int fd = open(path.fileSystemRepresentation, O_RDONLY | O_CLOEXEC);
    if (fd < 0) return NO;
    uLong crc = crc32(0, NULL, 0);
    static const size_t kBuf = 1 << 20;
    uint8_t *buf = malloc(kBuf);
    ssize_t n;
    while ((n = read(fd, buf, kBuf)) > 0) crc = crc32(crc, buf, (uInt)n);
    free(buf);
    close(fd);
    if (n < 0) return NO;
    *crcOut = (uint32_t)crc;
    return YES;
}

static BOOL ad_copy_into(int out, NSString *path, uint64_t *written)
{
    int fd = open(path.fileSystemRepresentation, O_RDONLY | O_CLOEXEC);
    if (fd < 0) return NO;
    static const size_t kBuf = 1 << 20;
    uint8_t *buf = malloc(kBuf);
    ssize_t n;
    BOOL ok = YES;
    while (ok && (n = read(fd, buf, kBuf)) > 0) {
        uint8_t *p = buf;
        while (n > 0) {
            ssize_t w = write(out, p, (size_t)n);
            if (w <= 0) { ok = NO; break; }
            p += w; n -= w; *written += (uint64_t)w;
        }
    }
    if (n < 0) ok = NO;
    free(buf);
    close(fd);
    return ok;
}

#pragma mark - IPA

static NSString *ad_safe_name(NSString *s)
{
    NSCharacterSet *bad = [NSCharacterSet characterSetWithCharactersInString:@"/\\:?*\"<>|"];
    return [[s componentsSeparatedByCharactersInSet:bad] componentsJoinedByString:@"_"];
}

NSString *app_decrypt_make_ipa(NSDictionary *app, BOOL useSpringBoard,
                               void (^progress)(NSString *, double), NSString **errorOut)
{
    NSString *appPath = app[@"path"];
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *errorText = nil;
    if (!appPath.length || ![fm fileExistsAtPath:appPath]) { if (errorOut) *errorOut = @"The app is no longer installed."; return nil; }
    void (^report)(NSString *, double) = ^(NSString *step, double f) { if (progress) progress(step, f); };

    // 1. Everything in the bundle (no symlinked folders followed), minus the
    //    FairPlay keys, which have no place in a decrypted copy.
    NSMutableArray<NSString *> *files = [NSMutableArray array];   // relative paths
    uint64_t totalBytes = 0;
    NSDirectoryEnumerator *en = [fm enumeratorAtPath:appPath];
    for (NSString *rel in en) {
        if ([rel isEqualToString:@"SC_Info"] || [rel hasPrefix:@"SC_Info/"]) { [en skipDescendants]; continue; }
        [files addObject:rel];
        struct stat st;
        if (lstat([appPath stringByAppendingPathComponent:rel].fileSystemRepresentation, &st) == 0 && S_ISREG(st.st_mode))
            totalBytes += (uint64_t)st.st_size;
    }

    NSString *outDir = app_decrypt_output_dir();
    NSDictionary *attrs = [fm attributesOfFileSystemForPath:outDir error:nil];
    uint64_t freeBytes = [attrs[NSFileSystemFreeSize] unsignedLongLongValue];
    if (freeBytes && freeBytes < totalBytes + totalBytes / 5 + 50ULL * 1024 * 1024) {
        if (errorOut) *errorOut = [NSString stringWithFormat:@"Not enough free space: the IPA needs about %@.",
                                   [NSByteCountFormatter stringFromByteCount:(long long)totalBytes countStyle:NSByteCountFormatterCountStyleFile]];
        return nil;
    }

    // 2. Decrypt every encrypted Mach-O into a work folder.
    NSString *work = [NSTemporaryDirectory() stringByAppendingPathComponent:
                      [@"Decrypt-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    [fm createDirectoryAtPath:work withIntermediateDirectories:YES attributes:nil error:nil];
    NSMutableDictionary<NSString *, NSString *> *replaced = [NSMutableDictionary dictionary];
    // The app's own executable first (if that can't be decrypted, nothing
    // else matters), then frameworks, then extensions -- an extension that
    // can't be decrypted is left out of the IPA instead of failing it.
    NSString *mainExec = [NSDictionary dictionaryWithContentsOfFile:[appPath stringByAppendingPathComponent:@"Info.plist"]][@"CFBundleExecutable"];
    NSArray<NSString *> *ordered = [files sortedArrayUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        NSInteger (^rank)(NSString *) = ^NSInteger(NSString *r) {
            if ([mainExec isKindOfClass:NSString.class] && [r isEqualToString:mainExec]) return 0;
            if ([r containsString:@".appex/"] || [r hasPrefix:@"Watch/"]) return 2;
            return 1;
        };
        return [@(rank(a)) compare:@(rank(b))];
    }];
    NSMutableSet<NSString *> *droppedBundles = [NSMutableSet set];   // extension bundles left out
    NSUInteger index = 0;
    for (NSString *rel in ordered) {
        index++;
        NSString *src = [appPath stringByAppendingPathComponent:rel];
        struct stat st;
        if (lstat(src.fileSystemRepresentation, &st) != 0 || !S_ISREG(st.st_mode) || st.st_size < 4096) continue;
        NSString *dst = [work stringByAppendingPathComponent:[NSString stringWithFormat:@"%lu.bin", (unsigned long)index]];
        BOOL decrypted = NO;
        NSString *err = nil;
        report([@"Decrypting " stringByAppendingString:rel.lastPathComponent], 0.4 * index / MAX(ordered.count, 1u));
        if (!ad_decrypt_file(src, dst, useSpringBoard, &decrypted, &err)) {
            // Inside an .appex: drop that whole extension, keep going.
            NSRange appex = [rel rangeOfString:@".appex/"];
            if (appex.location != NSNotFound) {
                NSString *bundle = [rel substringToIndex:appex.location + 6];   // ".../Name.appex"
                [droppedBundles addObject:bundle];
                log_user("[DECRYPT] Leaving out %s: %s\n", bundle.UTF8String, err.UTF8String);
                continue;
            }
            errorText = err;
            break;
        }
        if (decrypted) replaced[rel] = dst;
    }
    if (!errorText && replaced.count == 0) errorText = @"Nothing in this app is encrypted, or it couldn't be read.";
    if (errorText) {
        [fm removeItemAtPath:work error:nil];
        log_user("[DECRYPT] Failed: %s\n", errorText.UTF8String);
        if (errorOut) *errorOut = errorText;
        return nil;
    }

    // 3. Pack Payload/<App>.app into the IPA (stored; IPAs don't need deflate).
    NSString *version = [app[@"version"] length] ? app[@"version"] : @"0";
    NSString *ipa = [outDir stringByAppendingPathComponent:
                     [NSString stringWithFormat:@"%@_%@_decrypted.ipa", ad_safe_name(app[@"name"] ?: @"App"), ad_safe_name(version)]];
    NSString *partial = [ipa stringByAppendingString:@".part"];
    int fd = open(partial.fileSystemRepresentation, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
    if (fd < 0) { [fm removeItemAtPath:work error:nil]; if (errorOut) *errorOut = @"The IPA can't be created."; return nil; }
    ADZipWriter *zip = [ADZipWriter new];
    zip.fd = fd;
    zip.central = [NSMutableData data];
    NSString *prefix = [@"Payload/" stringByAppendingString:appPath.lastPathComponent];
    __block uint64_t packed = 0;
    BOOL ok = [zip addEntry:@"Payload/" mode:S_IFDIR | 0755 mtime:time(NULL) size:0 crc:0 body:nil] &&
              [zip addEntry:[prefix stringByAppendingString:@"/"] mode:S_IFDIR | 0755 mtime:time(NULL) size:0 crc:0 body:nil];
    for (NSString *rel in files) {
        if (!ok) break;
        BOOL dropped = NO;
        for (NSString *bundle in droppedBundles)
            if ([rel isEqualToString:bundle] || [rel hasPrefix:[bundle stringByAppendingString:@"/"]]) { dropped = YES; break; }
        if (dropped) continue;
        NSString *src = [appPath stringByAppendingPathComponent:rel];
        NSString *name = [prefix stringByAppendingPathComponent:rel];
        struct stat st;
        if (lstat(src.fileSystemRepresentation, &st) != 0) continue;
        if (S_ISDIR(st.st_mode)) {
            ok = [zip addEntry:[name stringByAppendingString:@"/"] mode:st.st_mode mtime:st.st_mtime size:0 crc:0 body:nil];
        } else if (S_ISLNK(st.st_mode)) {
            char target[PATH_MAX];
            ssize_t n = readlink(src.fileSystemRepresentation, target, sizeof(target));
            if (n <= 0) continue;
            NSData *d = [NSData dataWithBytes:target length:(NSUInteger)n];
            uint32_t crc = (uint32_t)crc32(crc32(0, NULL, 0), d.bytes, (uInt)d.length);
            ok = [zip addEntry:name mode:st.st_mode mtime:st.st_mtime size:d.length crc:crc body:^BOOL{ return [zip writeData:d]; }];
        } else if (S_ISREG(st.st_mode)) {
            NSString *from = replaced[rel] ?: src;
            struct stat fs;
            uint32_t crc = 0;
            if (stat(from.fileSystemRepresentation, &fs) != 0 || !ad_crc_file(from, &crc)) {
                errorText = [NSString stringWithFormat:@"%@ can't be read.", rel];
                ok = NO; break;
            }
            report([@"Packing " stringByAppendingString:rel.lastPathComponent],
                   0.4 + 0.6 * (double)packed / (double)MAX(totalBytes, 1ULL));
            ok = [zip addEntry:name mode:st.st_mode mtime:st.st_mtime size:(uint64_t)fs.st_size crc:crc body:^BOOL{
                uint64_t written = 0;
                BOOL copied = ad_copy_into(zip.fd, from, &written) && written == (uint64_t)fs.st_size;
                zip.offset += written;
                packed += written;
                return copied;
            }];
        }
    }
    if (ok) ok = [zip finish];
    if (fsync(fd) != 0) ok = NO;
    close(fd);
    [fm removeItemAtPath:work error:nil];
    if (!ok) {
        [fm removeItemAtPath:partial error:nil];
        if (errorOut) *errorOut = errorText ?: @"Writing the IPA failed (disk full?).";
        return nil;
    }
    [fm removeItemAtPath:ipa error:nil];
    if (![fm moveItemAtPath:partial toPath:ipa error:nil]) {
        if (errorOut) *errorOut = @"The finished IPA couldn't be saved.";
        return nil;
    }
    report(@"Done", 1.0);
    if (droppedBundles.count && errorOut)   // not an error: tells the caller what was left out
        *errorOut = [NSString stringWithFormat:@"Left out (couldn't be decrypted): %@",
                     [[droppedBundles.allObjects valueForKey:@"lastPathComponent"] componentsJoinedByString:@", "]];
    log_user("[DECRYPT] %s: %lu binar%s decrypted -> %s\n", [app[@"name"] UTF8String],
             (unsigned long)replaced.count, replaced.count == 1 ? "y" : "ies", ipa.lastPathComponent.UTF8String);
    return ipa;
}
