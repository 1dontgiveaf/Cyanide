#!/usr/bin/env python3
"""Test calibration ownership without invoking offset discovery or kernel reads."""
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / 'Cyanide/utils/process.m'

def function(source, signature):
    start = source.index(signature)
    brace = source.index('{', start)
    depth = 0
    for i in range(brace, len(source)):
        if source[i] == '{': depth += 1
        elif source[i] == '}':
            depth -= 1
            if not depth: return source[start:i+1]
    raise AssertionError(signature)

class CalibrationOwnershipTests(unittest.TestCase):
    def test_public_readers_and_writer_share_owner(self):
        source = SOURCE.read_text()
        signatures = [
            'int procmgr_calibrate(void)',
            'int procmgr_task_thread_count_offset(void)',
            'int procmgr_suspend_count_for_entry(uint64_t proc, int pid)',
            'bool procmgr_mem_calibrated(void)',
            'bool procmgr_cpu_calibrated(void)',
            'int procmgr_task_role(int pid)',
            'int procmgr_stats(int pid, uint64_t *residentBytes, uint64_t *cpuNs)',
            'bool procmgr_row_info(uint64_t kproc, int pid, procmgr_row_info_t *out)',
        ]
        for signature in signatures:
            body = function(source, signature)
            with self.subTest(signature=signature):
                self.assertLess(body.index('pm_calibration_lock_enter();'), body.index('_locked('))
                self.assertLess(body.index('_locked('), body.index('pm_calibration_lock_leave();'))
                self.assertLess(body.index('pm_calibration_lock_leave();'), body.index('return result;'))
                self.assertEqual(body.count('return '), 1)
                self.assertNotIn('krw_batch_begin', body)
        calibration = function(source, 'static int procmgr_calibrate_locked(void)')
        getter = function(source, 'static int procmgr_task_thread_count_offset_locked(void)')
        self.assertIn('pm_calibrate_suspcount_locked();', calibration)
        self.assertIn('pm_calibrate_suspcount_locked();', getter)
        self.assertNotIn('pm_calibration_lock_enter()', calibration)
        self.assertNotIn('pm_calibration_lock_enter()', getter)

    def test_native_concurrent_publication(self):
        source = SOURCE.read_text()
        lock = source[source.index('// One owner for all mutable calibration state'):source.index('// MUST match early_kread()')]
        wrappers = function(source, 'int procmgr_calibrate(void)') + '\n' + function(source, 'int procmgr_task_thread_count_offset(void)')
        code = r'''
#include <pthread.h>
#include <sched.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
static int first, second, torn;
static int procmgr_calibrate_locked(void) { first++; sched_yield(); second=first; return 1; }
static int procmgr_task_thread_count_offset_locked(void) { if (first != second) torn++; return first; }
''' + lock + wrappers + r'''
static void *worker(void *argument) {
    for (int i=0; i<500; i++) {
        if ((uintptr_t)argument) procmgr_calibrate();
        else procmgr_task_thread_count_offset();
    }
    return NULL;
}
int main(void) {
    pthread_t threads[8];
    for (int i=0; i<8; i++) if (pthread_create(&threads[i],NULL,worker,(void *)(uintptr_t)(i<4))) return 2;
    for (int i=0; i<8; i++) pthread_join(threads[i],NULL);
    if (torn || first != 2000 || second != first) return 1;
    puts("calibration concurrent-owner regression: PASS"); return 0;
}
'''
        with tempfile.TemporaryDirectory(prefix='cyanide-calibration-test-') as temporary:
            base = Path(temporary)
            harness, executable = base / 'ownership.c', base / 'ownership'
            harness.write_text(code)
            subprocess.run(['xcrun','clang','-std=c11','-pthread',str(harness),'-o',str(executable)], check=True)
            subprocess.run([str(executable)], check=True)

if __name__ == '__main__':
    unittest.main()
