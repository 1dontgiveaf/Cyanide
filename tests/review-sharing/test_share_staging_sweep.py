#!/usr/bin/env python3
"""Synthetic regression for the app-owned FileBrowserShare sweep policy."""
from pathlib import Path
import fcntl
import os
import shutil
import tempfile
import time
import uuid

ROOT = Path(__file__).resolve().parents[2]
SOURCE = (ROOT / "Cyanide/FileBrowserViewController.m").read_text()
SCENE = (ROOT / "Cyanide/SceneDelegate.m").read_text()

assert "O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW" in SOURCE
assert "LOCK_EX | LOCK_NB" in SOURCE
assert "fb_share_is_uuid_directory_name" in SOURCE
assert "kFBShareStaleAge" in SOURCE
assert "filebrowser_sweep_stale_share_staging();" in SCENE

# Exercise the same safety decisions on a private synthetic staging root.
with tempfile.TemporaryDirectory(prefix="cyanide-share-sweep-") as temp:
    root = Path(temp) / "FileBrowserShare"
    root.mkdir()
    old = root / str(uuid.uuid4()).upper()
    old.mkdir()
    (old / ".active").write_text("stale")
    (old / "payload").write_bytes(b"old")

    live = root / str(uuid.uuid4()).upper()
    live.mkdir()
    marker = live / ".active"
    marker.write_text("live")
    live_lock = os.open(marker, os.O_RDONLY)
    fcntl.flock(live_lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    (live / "payload").write_bytes(b"must survive")

    outside = Path(temp) / "outside"
    outside.mkdir()
    (outside / "keep").write_text("do not remove")
    link = root / str(uuid.uuid4()).upper()
    link.symlink_to(outside, target_is_directory=True)

    # Make all candidates old enough while retaining the marker lock on live.
    stale_time = time.time() - 2 * 24 * 60 * 60
    for candidate in (old, live):
        os.utime(candidate, (stale_time, stale_time), follow_symlinks=False)

    now = time.time()
    for candidate in list(root.iterdir()):
        try:
            parsed = uuid.UUID(candidate.name)
        except ValueError:
            continue
        if str(parsed).upper() != candidate.name or not candidate.is_dir():
            continue
        st = os.lstat(candidate)
        if st.st_mtime > now or now - st.st_mtime < 24 * 60 * 60:
            continue
        marker_path = candidate / ".active"
        try:
            fd = os.open(marker_path, os.O_RDONLY | os.O_NOFOLLOW)
        except FileNotFoundError:
            fd = -1
        except OSError:
            continue
        if fd >= 0:
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                os.close(fd)
                continue
        current = os.lstat(candidate)
        if current.st_dev == st.st_dev and current.st_ino == st.st_ino:
            # shutil.rmtree does not follow the top-level symlink; the symlink
            # candidate was rejected above and is therefore untouched.
            shutil.rmtree(candidate)
        if fd >= 0:
            os.close(fd)

    assert not old.exists()
    assert live.exists() and (live / "payload").read_bytes() == b"must survive"
    assert link.is_symlink() and (outside / "keep").read_text() == "do not remove"
    os.close(live_lock)
print("share staging sweep synthetic filesystem contract: PASS")
