//
//  vm.h
//  Cyanide
//
//  Created by seo on 3/29/26.
//

#include "RemoteCall.h"

struct VMObject {
    uint64_t vmAddress;
    uint64_t address;
    uint64_t objectOffset;
    uint64_t entryOffset;
};

struct VmPackingParams {
    uint64_t vmpp_base;
    uint8_t  vmpp_bits;
    uint8_t  vmpp_shift;
    uint8_t  vmpp_base_relative;
};

struct vm_map_links {
    uint64_t prev;
    uint64_t tnext;
    vm_map_offset_t start;
    vm_map_offset_t end;
};

struct vm_map_store {
    uint64_t rbe_left;
    uint64_t rbe_right;
    uint64_t rbe_parent;
};

struct vm_map_entry {
    struct vm_map_links links;
    struct vm_map_store store;
    union  {
        vm_offset_t vme_object_value;
        struct  {
            vm_offset_t vme_atomic : 1;
            vm_offset_t is_sub_map : 1;
            vm_offset_t vme_submap : 62;
        };
        struct  {
            uint32_t vme_ctx_atomic : 1;
            uint32_t vme_ctx_is_sub_map : 1;
            uint32_t vme_context : 30;
            union  {
                uint32_t vme_object_or_delta;
                uint32_t vme_tag_btref;
            };
        };
    };
    unsigned long long vme_alias : 12;
    unsigned long long vme_offset : 52;
    unsigned long long is_shared : 1;
    unsigned long long __unused1 : 1;
    unsigned long long in_transition : 1;
    unsigned long long needs_wakeup : 1;
    unsigned long long behavior : 2;
    unsigned long long needs_copy : 1;
    unsigned long long protection : 3;
    unsigned long long used_for_tpro : 1;
    unsigned long long max_protection : 4;
    unsigned long long inheritance : 2;
    unsigned long long use_pmap : 1;
    unsigned long long no_cache : 1;
    unsigned long long vme_permanent : 1;
    unsigned long long superpage_size : 1;
    unsigned long long map_aligned : 1;
    unsigned long long zero_wired_pages : 1;
    unsigned long long used_for_jit : 1;
    unsigned long long csm_associated : 1;
    unsigned long long iokit_acct : 1;
    unsigned long long vme_resilient_codesign : 1;
    unsigned long long vme_resilient_media : 1;
    unsigned long long vme_xnu_user_debug : 1;
    unsigned long long vme_no_copy_on_read : 1;
    unsigned long long translated_allow_execute : 1;
    unsigned long long vme_kernel_object : 1;
    unsigned short wired_count;
    unsigned short user_wired_count;
};

struct VMShmem vm_map_remote_page(uint64_t vmMap, uint64_t address);

// Walking another task's map (vm_map_iterate_entries) once and mapping its
// memory objects directly, instead of one map lookup per page.
struct VMEntryInfo {
    uint64_t start, end;
    uint64_t object;      // 0 for a submap or an unreadable object
    uint64_t offset;      // object offset of `start`
    uint32_t protection;  // VM_PROT_* bits
    bool isSubmap;
};
void vm_map_iterate_entries(uint64_t vm_map_ptr, void (^itBlock)(uint64_t start, uint64_t end, uint64_t entry, BOOL *stop));
bool vm_map_entry_info(uint64_t entryAddr, struct VMEntryInfo *out);
// Maps `len` bytes (page multiple) of `object` at object offset
// `objectOffset` (page aligned) into this process; release with
// vm_shmem_release(&shmem, len).
struct VMShmem vm_map_object_range(uint64_t object, uint64_t objectOffset, uint64_t len);
// As vm_map_object_range, for the object behind a file the caller has mapped
// itself (and faulted in): not capped at the object's reported size, which
// for some system files is far smaller than the file (SFUI.ttf: 16 KB of 8.3 MB).
struct VMShmem vm_map_file_object_range(uint64_t object, uint64_t objectOffset, uint64_t len);
void vm_shmem_release(struct VMShmem *shmem, uint64_t len);
