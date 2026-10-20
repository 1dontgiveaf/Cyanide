#!/usr/bin/env python3
"""Cleaner calibration must stay on the suspend-count path.

The 2026-10-20 panic came from the CPU/memory calibration's speculative KRW
reads (socket getsockopt), not from proc_pidinfo. Commit 34e2bbc fixed Cleaner
by calling procmgr_calibrate_suspend_count(); this test keeps it that way.
"""
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[2]
settings = (ROOT / "Cyanide/SettingsViewController.m").read_text()
process = (ROOT / "Cyanide/utils/process.m").read_text()


def function_body(source, signature):
    start = source.index(signature)
    brace = source.index("{", start)
    depth = 0
    for i in range(brace, len(source)):
        if source[i] == "{":
            depth += 1
        elif source[i] == "}":
            depth -= 1
            if depth == 0:
                return source[brace:i + 1]
    raise AssertionError(f"unterminated function: {signature}")


active = function_body(settings, "NSSet<NSString *> *settings_active_process_names(void)")
# Remove comments so the explanatory "Not procmgr_calibrate()" sentence is
# not mistaken for a call.
active_code = re.sub(r"/\*.*?\*/", "", active, flags=re.S)
active_code = re.sub(r"//[^\n]*", "", active_code)
assert "procmgr_calibrate_suspend_count()" in active_code
assert "procmgr_calibrate()" not in active_code
assert "procmgr_calibrate_locked" not in active_code

suspend = function_body(process, "int procmgr_calibrate_suspend_count(void)")
assert "pm_calibrate_identity_locked()" in suspend
assert "procmgr_calibrate_locked" not in suspend
assert "pm_calibrate_mem" not in suspend
assert "pm_calibrate_cpu" not in suspend

# The own-CPU reference used by cache validation must be the live+dead total
# from libproc, not TASK_BASIC_INFO's terminated-thread-only times.
own_cpu = function_body(process, "static void procmgr_own_cpu_ns(uint64_t *u, uint64_t *s)")
assert "proc_pidinfo(getpid(), PM_PROC_PIDTASKINFO" in own_cpu

# The suspend-count calibration's own-thread count stays on task_threads.
threads = function_body(process, "static bool pm_taskinfo_threadnum(uint32_t *out)")
assert "task_threads(mach_task_self()" in threads
assert "proc_pidinfo" not in threads

print("cleaner calibration scope: PASS")
