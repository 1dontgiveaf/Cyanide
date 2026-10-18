> **Supported:** iPhone / iPad on iOS/iPadOS `17.0 – 18.7.1` or `26.0 – 26.0.1`.
> **Not supported:** iPhone 17 (A19 / A19 Pro) and M5 — Memory Integrity Enforcement.
> Any other device on a supported version works. [Details](https://github.com/kolbicz/Cyanide#supported-devices)

# Cyanide 1.8.1

A hardening release for the kernel chain, passcode theming, theme import and the installer queue.

## A18 / M4

- **pe_v3 is now the default A18/M4 exploit path.** It stages once, hunts one mapping, caps unproven foreign reads at 20 and re-rolls a fresh layout instead of grinding a hunt that has already exceeded the cap. Every aperture panic in the collected logs happened during the hunt, not during a clean reoccupation cycle.
- **pe_v1 is kept as the explicit compatibility/debug path.** It now has a per-pass successful-read budget (150) and a foreign-read cap (50), and the bounded-search option defaults to on (four passes, then a clean retry).
- **Post-acquisition verification** checks the kernel Mach-O mapping, a fresh user mapping and the physical-OOB state before the app starts tweak or log work. On T8140 the page tables are SPTM-owned, so this is the checkable alternative to reading PFNs directly; a corrupted mapping is caught before the delayed `write(2)` path.

## Fixes

- **Exception-port teardown bypass is owner-scoped.** Only the thread that began a teardown (or an internal helper that explicitly enters the bypass) may sign while the lifecycle gate is closed. An unrelated live-tweak call can no longer slip through during teardown.
- **Synthetic-thread liveness no longer trusts a stale ksafe snapshot.** An address outside the boot-time snapshot is refreshed and re-checked; if the refresh itself cannot run, the answer is UNKNOWN, not GONE.
- **Passcode folder modes are persisted and retried.** A restore that could not be verified is recorded, and the next apply/restore retries it before writing anything new. Backup import also has a bounded directory walk.
- **Theme imports and applies use the same 256 KB per-icon cap.** Import no longer reports success for icons the apply path would silently skip. An interrupted import swap is recovered on the next import.
- **Repo scripts for removed or renamed tweaks are pruned** when they are not enabled, installed or the active QuickLoader source.
- **Installer preflight notes are consumed by the no-run completion**, so a NanoRegistry cache-push warning cannot surface in a later unrelated run.
- **The actions lock now carries its owner in one atomic word.** A run request can no longer race the old separate “run active” flag and be misclassified as a non-run action.
- **The init watchdog publishes completion before retirement**, so an init that returns at the 120 s boundary is not repaired as if it were wedged.
- **Safe-detach registration no longer leaks an assertion** when iOS expires the background task before the id is published.

## Notes

- A run can still reboot an A18 / M4 device instead of succeeding. pe_v3 and the new caps reduce the exposure; they do not make the physical-aperture primitive risk-free.
- No on-device validation was possible for the exploit changes in this release; they are build- and code-path-verified only.
