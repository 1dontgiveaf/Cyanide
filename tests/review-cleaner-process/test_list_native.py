#!/usr/bin/env python3
"""Run the actual list implementation against a deterministic fake kernel graph."""
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / 'Cyanide/utils/process.m'
MOCKS = r'''
#include <stdint.h>
#include <stdbool.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
typedef bool BOOL;
#define YES true
#define NO false
#define KSAFE_REFRESH_DONE 1
static const uint32_t off_proc_p_pid = 16;
static const uint32_t off_proc_p_list_le_next = 0;
static const uint32_t off_proc_p_list_le_prev = 8;
typedef struct { int pid; uint64_t kproc; char name[32]; } procmgr_entry_t;
typedef struct { uint64_t address, next, prev; uint32_t pid; char name[32]; } Node;
static Node nodes[3];
static const uint64_t head = 0xf000;
static uint64_t selfAddress = 0x2000, errors;
static int g_pm_ksafe_refresh_pending, pidReads[3], churnPid;
static int index_of(uint64_t address) {
    for (int i=0; i<3; i++) if (nodes[i].address == address) return i;
    return -1;
}
static bool procmgr_is_kern_ptr(uint64_t address) { return address >= 0x1000; }
static bool ksafe_available(void) { return true; }
static bool kaddr_is_mapped(uint64_t address, uint32_t size) {
    return index_of(address) >= 0 || (address == head && size <= 8);
}
static bool pm_proc_readable(uint64_t address) { return index_of(address) >= 0; }
static bool pm_list_ensure_ksafe_gate(void) { return true; }
static bool kexploit_krw_ready(void) { return true; }
static void krw_set_nonfatal(bool value) { (void)value; }
static uint64_t krw_op_error_count(void) { return errors; }
static bool krw_batch_begin(void) { return true; }
static void krw_batch_end(void) {}
static int ksafe_refresh_status(void) { return KSAFE_REFRESH_DONE; }
static uint64_t proc_self(void) { return selfAddress; }
static uint64_t kread64(uint64_t address) {
    if (address == head) return nodes[0].address;
    for (int i=0; i<3; i++) {
        if (address == nodes[i].address) return nodes[i].next;
        if (address == nodes[i].address + 8) return nodes[i].prev;
    }
    errors++; return 0;
}
static uint32_t kread32(uint64_t address) {
    for (int i=0; i<3; i++) if (address == nodes[i].address + 16) {
        pidReads[i]++;
        if (churnPid && i == 1 && pidReads[i] > 1) return nodes[i].pid + 100;
        return nodes[i].pid;
    }
    errors++; return UINT32_MAX;
}
static char *proc_get_p_name(uint64_t address) {
    int i=index_of(address); return i >= 0 ? nodes[i].name : NULL;
}
static void reset(void) {
    memset(nodes, 0, sizeof(nodes)); memset(pidReads, 0, sizeof(pidReads));
    errors=0; churnPid=0; selfAddress=0x2000; g_pm_ksafe_refresh_pending=0;
    for (int i=0; i<3; i++) {
        nodes[i].address=(uint64_t)(i+1)*0x1000;
        nodes[i].pid=(uint32_t)i+1;
        snprintf(nodes[i].name, sizeof(nodes[i].name), "Proc%d", i+1);
        nodes[i].next=i == 2 ? 0 : (uint64_t)(i+2)*0x1000;
        nodes[i].prev=i == 0 ? head : (uint64_t)i*0x1000;
    }
}
static void check(bool ok, const char *label) {
    if (!ok) { fprintf(stderr, "FAIL: %s\n", label); exit(1); }
}
'''
CASES = r'''
int main(void) {
    procmgr_entry_t entries[4];
    reset(); check(procmgr_list(entries,4)==3, "complete middle-anchor list");
    reset(); selfAddress=0x1000; check(procmgr_list(entries,3)==3, "complete first-anchor list");
    reset(); selfAddress=0x3000; check(procmgr_list(entries,3)==3, "complete last-anchor list");
    reset(); check(procmgr_list(entries,2)==-1, "buffer truncation is unavailable");
    reset(); nodes[2].pid=nodes[1].pid; check(procmgr_list(entries,4)==-1, "duplicate PID unavailable");
    reset(); nodes[2].prev=0x1000; check(procmgr_list(entries,4)==-1, "broken reverse link unavailable");
    reset(); nodes[0].next=0x3000; check(procmgr_list(entries,4)==-1, "broken forward link unavailable");
    reset(); nodes[2].name[0]=0; check(procmgr_list(entries,4)==-1, "unknown forward name unavailable");
    reset(); nodes[0].name[0]=0; check(procmgr_list(entries,4)==-1, "unknown reverse name is not a sentinel");
    reset(); churnPid=1; check(procmgr_list(entries,4)==-1, "PID drift during publication unavailable");
    puts("process-list mocked-native regressions: PASS");
    return 0;
}
'''
class ProcessListNativeTests(unittest.TestCase):
    def test_fake_kernel_graph(self):
        source = SOURCE.read_text()
        start = source.index("// Read one proc's pid+name into an entry.")
        end = source.index('// --- credential escalation', start)
        code = MOCKS + source[start:end] + CASES
        with tempfile.TemporaryDirectory(prefix='cyanide-process-model-') as temporary:
            base = Path(temporary)
            harness, executable = base / 'graph.c', base / 'graph'
            harness.write_text(code)
            subprocess.run(['xcrun', 'clang', '-std=c11', str(harness), '-o', str(executable)], check=True)
            subprocess.run([str(executable)], check=True)

if __name__ == '__main__':
    unittest.main()
