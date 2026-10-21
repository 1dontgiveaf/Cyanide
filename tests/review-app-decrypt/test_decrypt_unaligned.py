#!/usr/bin/env python3
"""Contract for the unaligned-range decryption attempts.

live 9: 1.1.1.1's executable and NotificationService extension have 4 KB
aligned crypt ranges on a 16 KB-page device. mremap_encrypted has no cryptoff
argument, so the implementation tries plausible address/length pairs. It must
not launch the app.
"""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SOURCE = (ROOT / "Cyanide/tweaks/app_decrypt.m").read_text()

assert "ad_try_mremap_variants" in SOURCE
assert "\"page-range\"" in SOURCE
assert "\"crypt-range\"" in SOURCE
assert "\"crypt-exact\"" in SOURCE
assert "\"prefix-page-range\"" in SOURCE
assert "\"prefix-crypt-range\"" in SOURCE
assert "mremapEncrypted" in SOURCE
assert "posix_spawn" not in SOURCE
assert "task_for_pid" not in SOURCE
assert "launched-app" not in SOURCE
assert "memcmp(enc, dec" in SOURCE
assert "cryptidFileOffset" in SOURCE
assert "hasCodesign" in SOURCE

print("app decrypt unaligned mremap attempts: PASS")
