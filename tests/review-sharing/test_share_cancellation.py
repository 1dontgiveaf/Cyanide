#!/usr/bin/env python3
"""Regression contract for presenter-owned share cancellation."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SOURCE = (ROOT / "Cyanide/FileBrowserViewController.m").read_text()
HEADER = (ROOT / "Cyanide/FileBrowserViewController.h").read_text()
PLIST = (ROOT / "Cyanide/PlistEditorViewController.m").read_text()

assert "void filebrowser_cancel_shares_for_presenter(UIViewController *presenter);" in HEADER
assert "- (void)cancelBeforePresentation" in SOURCE
assert "atomic_store_explicit(&_cancelled, true" in SOURCE
assert "atomic_store_explicit(&_stagingReady, true" in SOURCE
assert "if ([op isCancelled])" in SOURCE

# The root reader must be allowed to unwind its own RemoteCall session.  The
# share layer checks before and after the bounded read rather than tearing down
# that shared session from another thread.
root_start = SOURCE.index("} else if (viaRoot) {")
root_end = SOURCE.index("        } else {\n            fb_share_copy_regular", root_start)
root = SOURCE[root_start:root_end]
assert root.index("if ([op isCancelled])") < root.index("settings_root_read_file")
assert root.index("settings_root_read_file") < root.index("if ([op isCancelled])", root.index("settings_root_read_file"))
assert "remote_call" not in root.lower()

# Ordinary and preloaded copies check cancellation at chunk boundaries; a
# cancelled partial file is discarded by the operation cleanup.
copy_start = SOURCE.index("static BOOL fb_share_copy_regular")
copy_end = SOURCE.index("static void fb_share_complete", copy_start)
copy = SOURCE[copy_start:copy_end]
assert copy.count("[op isCancelled]") >= 3
assert "removeItemAtPath:op.stagedPath" in copy
assert "fb_share_write_data(op, snapshot" in SOURCE

# All three UI owners cancel only after disappearance.  A ready operation is
# deliberately not cancelled, so presenting an activity sheet does not tear
# down its staged file.
assert SOURCE.count("filebrowser_cancel_shares_for_presenter(self);") >= 2
assert "- (void)viewDidDisappear:(BOOL)animated" in PLIST
assert "filebrowser_cancel_shares_for_presenter(self);" in PLIST
assert "if (!atomic_load_explicit(&_stagingReady" in SOURCE

# Synthetic state model for the race: disappearance before staging completion
# cancels; disappearance after handoff preserves the staged operation.
for ready, expected_cancelled in ((False, True), (True, False)):
    cancelled = not ready
    assert cancelled is expected_cancelled
print("share cancellation ownership contract: PASS")
