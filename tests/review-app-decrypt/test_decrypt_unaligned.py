#!/usr/bin/env python3
"""Contract for the unaligned-range decryption fallback.

live 9: 1.1.1.1's executable and NotificationService extension have
4 KB-aligned crypt ranges on a 16 KB-page device. mremap_encrypted requires
16 KB alignment in both mmap offset and address, so the fallback must start
the executable suspended and read the decrypted range from the task.
"""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SOURCE = (ROOT / "Cyanide/tweaks/app_decrypt.m").read_text()

assert "ad_decrypt_range_in_spawned_process" in SOURCE
assert "ad_decrypt_range_in_springboard_spawn" in SOURCE
assert "posix_spawnattr_init" in SOURCE
assert "task_for_pid" in SOURCE
assert "POSIX_SPAWN_START_SUSPENDED" in SOURCE
assert "task_for_pid" in SOURCE
assert "ad_task_read" in SOURCE
assert "ad_task_main_header" in SOURCE
assert "filetype == MH_EXECUTE" in SOURCE
assert "start % page" in SOURCE
# The normal path must remain mremap_encrypted, not a blanket spawn.
assert "mremapEncrypted(map, mapLen" in SOURCE
# Clear the cryptid only after a verified decrypted copy.
assert "memcmp(enc, dec" in SOURCE
assert "cryptidFileOffset" in SOURCE

print("app decrypt unaligned fallback: PASS")
