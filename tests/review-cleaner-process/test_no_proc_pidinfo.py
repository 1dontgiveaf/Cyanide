#!/usr/bin/env python3
"""Guard the 2026-10-20 panic workaround.

The panic was a zalloc per-CPU validation failure reached through a
proc_pidinfo copy path during Cleaner's suspend_count calibration. Process.m
must not call proc_pidinfo from any of its calibration/stat paths.
"""
from pathlib import Path

SOURCE = (Path(__file__).resolve().parents[2] / "Cyanide/utils/process.m").read_text()

# The declaration may remain for binary compatibility, but no call may remain.
assert "proc_pidinfo(pid" not in SOURCE
assert "proc_pidinfo(getpid" not in SOURCE
assert "= proc_pidinfo(" not in SOURCE

# Own-thread count and own CPU use Mach traps instead.
assert "task_threads(mach_task_self()" in SOURCE
assert "task_info(mach_task_self(), TASK_BASIC_INFO" in SOURCE
assert "pm_taskinfo_threadnum(UINT32" not in SOURCE  # no pid-taking helper

print("process proc_pidinfo removal contracts: PASS")
