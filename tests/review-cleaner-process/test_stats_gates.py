#!/usr/bin/env python3
"""Native and source contracts for mapped task/thread statistics reads."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
SOURCE = (ROOT / "Cyanide/utils/process.m").read_text()

def function_body(signature: str, after: int = 0) -> str:
    start = SOURCE.index(signature, after)
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

stats = function_body("static int pm_kernel_stats")
live = function_body("static bool pm_live_thread_sums")
recount_start = SOURCE.index("static bool pm_thread_sums_recount")
recount = function_body("static bool pm_thread_sums_recount", recount_start + 1)
for needle in (
    "pm_task_field_mapped(task, g_pm_off_task_ledger",
    "pm_task_field_mapped(task, g_pm_off_task_cpu_u",
    "pm_task_field_mapped(task, g_pm_off_task_cpu_s",
):
    assert needle in stats, needle
assert "!procmgr_is_kern_ptr(task) || !ksafe_available()" in stats
assert "pm_task_field_mapped(task, off_task_threads_next, 8)" in live
assert "pm_mapped_span(t, off_thread_task_threads_next, 8)" in live
assert "pm_mapped_span(th, g_pm_rc_lifetime_off, 8)" in recount
assert "pm_recount_array_span(g_pm_rc_count, g_pm_rc_track_stride" in recount
assert "offset + bytes > UINT32_MAX" in SOURCE
assert "offset > UINT64_MAX - base" in SOURCE

NATIVE = r'''
#include <assert.h>
#include <stdint.h>
#include <stdbool.h>
#include <limits.h>

static bool checked_offset_span(uint64_t offset, uint64_t bytes) {
    return bytes != 0 && bytes <= UINT32_MAX && offset <= UINT32_MAX &&
           offset <= UINT64_MAX - bytes && offset + bytes <= UINT32_MAX;
}
static bool fake_mapped_span(uint64_t base, uint64_t offset, uint64_t bytes) {
    if (base < 0x1000 || !checked_offset_span(offset, bytes) ||
        offset > UINT64_MAX - base || base + offset > UINT64_MAX - bytes)
        return false;
    return true;
}
static bool checked_recount(uint32_t count, uint32_t stride) {
    if (count == 0 || stride < 16 ||
        (uint64_t)count > (UINT64_MAX - 8) / stride)
        return false;
    return checked_offset_span(0, 8 + (uint64_t)count * stride);
}
int main(void) {
    assert(fake_mapped_span(0x2000, 0x100, 8));
    assert(!fake_mapped_span(0x0fff, 0x100, 8));
    assert(!fake_mapped_span(UINT64_MAX - 1, 4, 8));
    assert(!fake_mapped_span(0x2000, UINT32_MAX - 3, 8));
    assert(fake_mapped_span(0x2000, UINT32_MAX - 8, 8));
    assert(!fake_mapped_span(0x2000, 0, 0));
    assert(checked_recount(4, 24));
    assert(!checked_recount(UINT32_MAX, UINT32_MAX));
    assert(!checked_recount(1, 8));
    return 0;
}
'''
with tempfile.TemporaryDirectory(prefix="cyanide-stats-gates-") as td:
    td = Path(td)
    src = td / "stats_gates.c"
    exe = td / "stats_gates"
    src.write_text(NATIVE)
    subprocess.run(["cc", "-std=c11", "-Wall", "-Wextra", str(src), "-o", str(exe)], check=True)
    subprocess.run([str(exe)], check=True)
print("process stats mapped/span/overflow native and source guards: PASS")
