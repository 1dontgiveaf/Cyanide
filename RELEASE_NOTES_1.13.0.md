> **Supported:** iPhone / iPad on iOS/iPadOS `17.0 – 18.7.1` or `26.0 – 26.0.1`.
> **Not supported:** iPhone 17 (A19 / A19 Pro) and M5 — Memory Integrity Enforcement.
> Any other device on a supported version works. [Details](https://github.com/kolbicz/Cyanide#supported-devices)

# Cyanide 1.13.0

A tweak to hide the "new app" dots, a clear message on unsupported devices, and another Powercuff fix.

## New

- **Hide New App Dots** (Installer → SpringBoard): removes the blue dot next to the names of newly installed and updated apps, and keeps new ones from appearing until the next respring.

## Changes

- **Unsupported devices and iOS versions** now get a "Not Supported" screen with the reason instead of crashing (e.g. iOS 16 through an installer that skips the version check). Nothing else of Cyanide runs there.

## Fixes

- **Powercuff:** Cyanide now gives thermalmonitord time to take the new level before it disconnects, as 1.3.6 did. The log shows whether it worked: the system thermal state should read Critical with Heavy (also visible in apps like CPU X). If it still doesn't throttle for you, please send the log.

## About A18 / M4

On A18 / M4 devices a run has about a 50/50 chance of rebooting the device (a
kernel "panic") instead of succeeding — a known limit of these chips that can't
be fully fixed. It's a coin flip, so if it reboots, just try again; a few
attempts usually gets there. Once a run works, it stays working until your next
restart.

If you keep hitting panics, Settings → Launch Options has four knobs for the
A18 chain — exploit path (pe_v3 default, pe_v1 / pe_v2), memory shaping,
interleaved search and bounded search. Defaults are unchanged in this release;
other combinations may do better on your device. Each applies to the next fresh
run.
