#!/usr/bin/env python3
"""Source contracts for fail-closed process suspend classification.

These checks do not execute Objective-C or the KRW primitive. They protect the
control flow that is reviewable on macOS: cleaner rows use their mapped list
entry, identity calibration is strict, and failed/drifting reads return the
unknown sentinel rather than being treated as running or suspended.
"""
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
PROCESS = (ROOT / "Cyanide/utils/process.m").read_text()
HEADER = (ROOT / "Cyanide/utils/process.h").read_text()
SETTINGS = (ROOT / "Cyanide/SettingsViewController.m").read_text()


def function_body(source: str, signature: str) -> str:
    start = source.index(signature)
    brace = source.index("{", start)
    depth = 0
    for index in range(brace, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return source[brace : index + 1]
    raise AssertionError(f"unterminated function: {signature}")


compat = function_body(PROCESS, "int procmgr_suspend_count(int pid)")
identity = function_body(PROCESS, "int procmgr_identity_for_pid(int pid, char *buf, size_t len, uint64_t *kprocOut)")
entry = function_body(PROCESS, "int procmgr_suspend_count_for_entry_locked(uint64_t proc, int pid)")
strict = function_body(PROCESS, "static bool pm_task_matches_proc_strict(uint64_t task, uint64_t proc)")
row = function_body(PROCESS, "bool procmgr_row_info_locked(uint64_t kproc, int pid, procmgr_row_info_t *out)")
active = function_body(SETTINGS, "NSSet<NSString *> *settings_active_process_names(void)")

assert "int procmgr_suspend_count_for_entry" in HEADER
assert "proc_find(" not in compat
assert "procmgr_list(entries, cap)" in compat
assert "if (n >= 0)" in compat
assert "return -1;" in compat

for needle in (
    "pthread_mutex_lock(&g_pm_identity_lookup_lock);",
    "procmgr_list(entries, cap)",
    "if (n >= 0 && ksafe_available())",
    "kaddr_is_mapped(proc, procSpan)",
    "uint64_t errorsBefore = krw_op_error_count();",
    "currentPid != pid",
    "strncmp(nm, entries[i].name",
    "pthread_mutex_unlock(&g_pm_identity_lookup_lock);",
):
    assert needle in identity, needle
assert "proc_find(" not in identity

for needle in (
    "if (!ksafe_available()) return false;",
    "pm_task_matches_proc(task, proc) == 1",
    "kaddr_is_mapped(proc, procSpan)",
    "kaddr_is_mapped(task, taskSpan)",
):
    assert needle in strict, needle

for needle in (
    "uint64_t errorsBefore = krw_op_error_count();",
    "pm_task_matches_proc_strict(task, proc)",
    "if (krw_op_error_count() != errorsBefore) rc = -1;",
    "if ((int)kread32(proc + off_proc_p_pid) != pid)",
):
    assert needle in entry, needle

assert "pm_task_for_entry(kproc, &task)" in row
assert "pm_task_matches_proc(task, kproc) == 0" not in row
assert "procmgr_suspend_count_for_entry(buf[i].kproc, buf[i].pid)" in active
assert "procmgr_suspend_count(buf[i].pid)" not in active
print("suspend identity source contracts: PASS")

# Calibration invoked by Cleaner must not walk foreign procs without gates.
for signature in ("static void pm_calibrate_bsdinfo(void)", "static void pm_calibrate_suspcount_locked(void)"):
    calibration = function_body(PROCESS, signature)
    assert "proc_find(" not in calibration
    assert "pm_find_entry_task(1, &lproc, &ltask)" in calibration
assert "if (!krw_batch_begin()) return -1;" in entry
assert "krw_batch_end();" in entry
assert "if (name.length == 0) { free(buf); return nil; }" in active
