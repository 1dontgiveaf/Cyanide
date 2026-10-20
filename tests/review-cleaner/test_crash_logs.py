#!/usr/bin/env python3
"""Source contracts for the opt-in Crash Logs cleaner path.

These are deliberately narrow: the full no-follow deletion behavior is covered
by cleaner_helpers.py for app roots. This file guards the CrashReporter
allowlist, the synthetic row, and the publication rule.
"""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SOURCE = (ROOT / "Cyanide/CleanerViewController.m").read_text()

# Exact roots only; no broad Library/Logs or caller-supplied paths.
assert '"/private/var/mobile/Library/Logs/CrashReporter"' in SOURCE
assert '"/private/var/logs/CrashReporter"' in SOURCE
assert 'systemgroup.com.apple.osanalytics' in SOURCE
assert "cleaner_is_crash_log_root" in SOURCE
assert "cleaner_crash_log_roots" in SOURCE
assert "Library/Logs\"" not in SOURCE or "Logs/CrashReporter" in SOURCE

# The root open path must admit CrashReporter while retaining the app-root
# allowlist. Deletion and scanning go through the same validated descriptor.
assert "!cleaner_is_crash_log_root(path)" in SOURCE
assert "cleaner_open_trusted_root" in SOURCE
assert "cleaner_clear_directory(root" in SOURCE
assert "item.logRoots" in SOURCE

# Synthetic row and section.
assert 'crashLogs.name = @"Crash Logs"' in SOURCE
assert "CYCleanerSectionLogs" in SOURCE
assert "isCrashLogs" in SOURCE
assert "cleaner_published_crash_logs" in SOURCE

# Never default-select Crash Logs.
assert "crashLogs.selected = NO" in SOURCE

print("cleaner crash-log contracts: PASS")
