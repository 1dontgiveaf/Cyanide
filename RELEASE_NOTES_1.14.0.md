> **Supported:** iPhone / iPad on iOS/iPadOS `17.0 – 18.7.1` or `26.0 – 26.0.1`.
> **Not supported:** iPhone 17 (A19 / A19 Pro) and M5 — Memory Integrity Enforcement.
> Any other device on a supported version works. [Details](https://github.com/kolbicz/Cyanide#supported-devices)

# Cyanide 1.14.0

Font Overwrite, including the Lock Screen clock, and SpringBoard Tools that apply together with your other tweaks.

## New

- **Font Overwrite** (Settings → Lara): replace the system font, its italic and monospaced variants, or the **Lock Screen clock** with a font of your own. Thanks to [@rooootdev](https://github.com/rooootdev), whose lara this idea comes from.
  - The font is replaced in memory only. Nothing on the sealed system volume changes, and a restart always brings the original back. **Restore** does it without a restart (the original is backed up first).
  - Import a `.ttf`, `.otf` or `.ttc` from Files, tap it and pick what to replace. It has to be the same size as the system's font or smaller.
  - A plain font is adapted on the device so iOS accepts it as the system font (its weights and names, like lara's font patcher). Fonts with PostScript (CFF) outlines can't be adapted.
  - **Lock Screen Clock** changes every clock style at once. The weight slider has no effect on the new font.
  - The Lock Screen and its widgets are refreshed automatically. Respring to see the change everywhere else.

## Changes

- **SpringBoard Tools:** new **Apply with Tweaks** switch. Your SpringBoard Tools look is applied in every Apply Tweaks run too, e.g. after a respring.

## Fixes

- **SpringBoard Tools:** with Folder set to Disabled, folder backgrounds no longer come back while you swipe between Home Screen pages.

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
