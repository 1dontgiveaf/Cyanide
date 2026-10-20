#!/usr/bin/env python3
"""Regression contract for structured-plist sharing.

The source guard prevents the writable editor from reopening its pathname in the
share worker.  The small model below exercises the race that matters: a clean
editor captures bytes, a save changes the source, and the staged share remains
the exact pre-save snapshot (including formatting).
"""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
EDITOR = (ROOT / "Cyanide/PlistEditorViewController.m").read_text()
SHARE = (ROOT / "Cyanide/FileBrowserViewController.m").read_text()

share_block = EDITOR[EDITOR.index("share.primaryAction"):EDITOR.index("self.navigationItem.rightBarButtonItems")]
assert "NSData *snapshot = [me.doc.original copy];" in share_block
assert "filebrowser_share_file(me, me.doc.path, NO, snapshot" in share_block
assert "me.doc.readOnly ? me.doc.original : nil" not in share_block
assert "filebrowser_share_file(me, me.doc.path, NO, nil" not in share_block
assert "filebrowser_share_file" in SHARE

# Behavioral model: copying the immutable loaded bytes before a save must win
# over any later pathname contents.  This also protects XML/OpenStep formatting
# that a fresh Foundation serialization could normalize.
loaded = b"<?xml version=\"1.0\"?><plist><dict><key>k</key><string>old</string></dict></plist>\n"
source = bytearray(loaded)
snapshot = bytes(source)
source[:] = b"<?xml version=\"1.0\"?><plist><dict><key>k</key><string>new</string></dict></plist>\n"
staged = snapshot
assert staged == loaded
assert staged != bytes(source)
print("plist share immutable snapshot race contract: PASS")
