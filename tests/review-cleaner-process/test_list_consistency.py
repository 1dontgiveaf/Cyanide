#!/usr/bin/env python3
"""Source contracts for complete, internally consistent procmgr snapshots."""
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SOURCE = (ROOT / "Cyanide/utils/process.m").read_text()


def function_body(signature: str) -> str:
    start = SOURCE.index(signature)
    brace = SOURCE.index("{", start)
    depth = 0
    for index in range(brace, len(SOURCE)):
        if SOURCE[index] == "{":
            depth += 1
        elif SOURCE[index] == "}":
            depth -= 1
            if depth == 0:
                return SOURCE[brace : index + 1]
    raise AssertionError(f"unterminated function: {signature}")


fill = function_body("static bool procmgr_fill_entry(uint64_t proc, procmgr_entry_t *e)")
listing = function_body("int procmgr_list(procmgr_entry_t *entries, int max)")
head = function_body("static bool pm_is_allproc_head_link")

for needle in ("if (!pm_proc_readable(proc)) return false;", "if (!nm || !nm[0]) return false;", "*e = tmp;"):
    assert needle in fill, needle

for needle in (
    "BOOL truncated = NO;",
    "else if (n >= max) { truncated = YES; }",
    "if (incomplete || truncated || krw_op_error_count() != errorsBefore) return -1;",
    "pm_seen_proc(seen, seenCount, p)",
    "pm_next_proc_links_back(nx, p)",
    "pm_prev_proc_links_forward(pv, p)",
    "PM_RECORD_ENTRY(tmp)",
):
    assert needle in listing, needle

assert "if (_duplicate) { incomplete = YES; }" in listing
assert "Do not inspect proc-only fields at this address" in head
assert "kread64(first + off_proc_p_list_le_prev) != link" in head
assert "pm_next_proc_links_back(next, first)" in head
assert "off_proc_p_pid" not in head
# The old silent-cap loop must not reappear.
assert "n < max && procmgr_is_kern_ptr" not in listing
print("process-list consistency source contracts: PASS")
