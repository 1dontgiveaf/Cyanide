> **Supported:** iPhone / iPad on iOS/iPadOS `17.0 – 18.7.1` or `26.0 – 26.0.1`.
> **Not supported:** iPhone 17 (A19 / A19 Pro) and M5 — Memory Integrity Enforcement.
> Any other device on a supported version works. [Details](https://github.com/kolbicz/Cyanide#supported-devices)

# Cyanide 1.8.1

This release adds the Daemons screen and System Info, makes respring and File Browser faster to use, and hardens the kernel chain, passcode theming, theme import and the installer queue.

## New

- **Daemons.** Turn launchd system services off and on from the app. Changes are staged and written on Save, advanced groups stay behind a switch, and each row shows its process and PID. The first open explains the risk: disabling the wrong daemon can require a full iOS restore. Kernel access is required and a saved session is reused when available.
- **System Info.** One place for device and OS details, uptime, kernel-access status, battery and per-app storage. Apps show their icons, sizes are right-aligned, and the list can be sorted.
- **Faster respring.** The respring cover is removed as soon as SpringBoard is back instead of waiting for a fixed timeout.
- **File Browser app names.** Container folders now show the app's name instead of a bare UUID, with a jump between the app's bundle and data containers.

## Improvements

- The earlier review batch is included: safe kernel reads and writes, per-task exception-guard handling, verified PAC keys, truthful OTA/Layout/LocationSim results, queue and plist-editor fixes, File Browser filtering, archive/import limits and QuickLoader fixes.
- The passcode importer reports partial results instead of a bare success, and its folder-mode changes are now verified and recoverable.
- Theme import and apply agree on the same image limits, so an imported theme no longer contains icons the apply path silently skips.

## Fixes

- **Exception-port teardown bypass is owner-scoped.** Only the thread that began a teardown (or an internal helper that explicitly enters the bypass) may sign while the lifecycle gate is closed. An unrelated live-tweak call can no longer slip through during teardown. Crash re-park is refused for live calls and admitted only from teardown-owned callers.
- **Passcode folders keep their directory type.** The APFS chmod path writes a raw mode; restores now rebuild `S_IFDIR` from the saved permissions, and records already written by the first 1.8.1 build are repaired.
- **Synthetic-thread liveness no longer trusts a stale ksafe snapshot.** An address outside the boot-time snapshot is refreshed and re-checked; a successful snapshot inside the 500 ms rate window counts as fresh, and only a real failure produces UNKNOWN.
- **Theme imports and applies use the same 256 KB per-icon cap.** An interrupted import swap is recovered at launch as well as on the next import.
- **Repo scripts for removed or renamed tweaks are pruned** when they are not enabled, installed or the active QuickLoader source; an installed tweak with an empty version string still counts as installed.
- **Installer preflight notes are consumed by the no-run completion**, so a NanoRegistry cache-push warning cannot surface in a later unrelated run.
- **The actions lock carries its owner in one atomic word.** A run request can no longer race a separate “run active” flag and be misclassified as a non-run action.
- **The init watchdog uses one atomic decision word**, so an init that returns at the 12 s boundary is either healthy or repaired, never both.
- **Safe-detach registration no longer leaks an assertion** when iOS expires the background task before the id is published.

## Good to know

> [!CAUTION]
> **You're responsible for your changes.** Disabling daemons or editing files can break iOS or your data. Keep a backup before changing anything you are unsure about.

- A run can still reboot an A18 / M4 device instead of succeeding. pe_v3 and the new caps reduce the exposure; they do not make the physical-aperture primitive risk-free.
- No on-device validation was possible for the exploit changes in this release; they are build- and code-path-verified only.

## About A18 / M4

- **pe_v3 is the default A18/M4 exploit path.** It stages once, hunts one mapping, caps unproven foreign reads at 20 and re-rolls a fresh layout instead of grinding a hunt that has already exceeded the cap. Every aperture panic in the collected logs happened during the hunt, not during a clean reoccupation cycle.
- **pe_v1 is kept as the explicit compatibility/debug path.** It has a per-pass successful-read budget (150) and a foreign-read cap (50), and the bounded-search option defaults to on (four passes, then a clean retry).
- **Post-hunt and post-acquisition verification.** After every hunt, and again after a successful acquisition, the app checks a fresh user mapping and the physical-OOB state before writing the result row or starting tweak work. On T8140 the page tables are SPTM-owned, so this is the checkable alternative to reading PFNs directly. It can catch a corrupted mapping before the delayed `write(2)` path; it does not make the physical-aperture primitive risk-free.
