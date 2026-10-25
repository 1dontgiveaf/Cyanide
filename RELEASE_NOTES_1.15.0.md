> **Supported:** iPhone / iPad on iOS/iPadOS `17.0 – 18.7.1` or `26.0 – 26.0.1`.
> **Not supported:** iPhone 17 (A19 / A19 Pro) and M5 — Memory Integrity Enforcement.
> Any other device on a supported version works. [Details](https://github.com/kolbicz/Cyanide#supported-devices)

# Cyanide 1.15.0

The iPad Dock, with its App Library button, on iPhone.

## New

- **iPad Dock** (Installer → SpringBoard): turns the Dock into SpringBoard's own iPad-style Dock, including the App Library button, for the current SpringBoard session. Writes no system files; turning it off brings the stock Dock back, and so does a respring.
  - The App Library button opens its own App Library, so the App Library page stays as it is.
  - Works together with **Disable App Library**: the App Library is then only in the Dock.
  - Ported from [hxhlb/cyanide](https://github.com/hxhlb/cyanide) (by Banana), with fixes for iOS 18 and for the App Library page breaking after the Dock's App Library was opened.

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
