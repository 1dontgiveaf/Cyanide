> **Supported:** iPhone / iPad on iOS/iPadOS `17.0 – 18.7.1` or `26.0 – 26.0.1`.
> **Not supported:** iPhone 17 (A19 / A19 Pro) and M5 — Memory Integrity Enforcement.
> Any other device on a supported version works. [Details](https://github.com/kolbicz/Cyanide#supported-devices)

# Cyanide 1.12.0

**SpringBoard Tools** recolor the dock, folders, Control Center, notifications and the app switcher, and Powercuff works again.

## New

- **SpringBoard Tools** (Settings → Lara). Idea from [lara](https://github.com/rooootdev/lara) by rooootdev, built differently: nothing in `/System` is changed.
  - Dock, Folder Background, Folder Blur, Control Center Modules, Control Center Blur, App Switcher Blur and Notification Banners.
  - Each one **Visible** (Apple's look), **Color** (your own tint and blur) or **Disabled** (no background).
  - Tap **Apply**: the dock, folder icons, Control Center and the app switcher change right away; opened folders and notifications the next time they appear. A respring undoes everything, so apply again after one.

## Fixes

- **Powercuff:** Light, Moderate and Heavy now really throttle (check with an app like CPU X). A changed level is applied on the next Apply, and removing Powercuff turns the throttling off again instead of keeping it until a reboot.
- **Repo sources:** a slow script download can no longer overwrite a newer script or bring back a deleted source; a source that suddenly lists no tweaks keeps its list while tweaks from it are installed; removing a repo package that switched on SBCustomizer, StatBar or Powercuff now turns that off too.
- **Update check:** an update prompt that couldn't be shown (e.g. Cyanide was in the background) appears the next time you open Cyanide instead of a day later.

## Good to know

- With **Color**, notifications show square on the Lock Screen: iOS draws them there as one shared blur cut into rounded shapes, and a changed one drops out of it (lara's files do the same). Banners elsewhere stay rounded.
- With **Control Center Blur** on Color, Control Center's own uncolored blur shows for a moment while it closes.

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
