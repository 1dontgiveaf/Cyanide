> **Supported:** iPhone / iPad on iOS/iPadOS `17.0 – 18.7.1` or `26.0 – 26.0.1`.
> **Not supported:** iPhone 17 (A19 / A19 Pro) and M5 — Memory Integrity Enforcement.
> Any other device on a supported version works. [Details](https://github.com/kolbicz/Cyanide#supported-devices)

# Cyanide 1.11.0

A new **Lara** section with tools ported from lara, a more capable File Browser, and a smarter Cache Cleaner.

## New

- **Lara** (Settings → Lara). Tools ported from [lara](https://github.com/rooootdev/lara) by rooootdev, with his permission, rebuilt on Cyanide's own kernel access and SpringBoard calls:
  - **Performance HUD:** Apple's frame-rate and GPU overlay, in ten modes (Basic, Full, Power, GPU Time and more).
  - **Debug Overlay:** Apple's internal UIKit inspector, opened by double-tapping the status bar. Until the next respring.
  - **Upside Down:** the Home Screen and Lock Screen can rotate to portrait upside down. Until the next respring.
  - **Hidden Settings:** ten hidden iOS preferences, such as Show Touches, build number in the status bar, Metal HUD in all apps, no low-battery alerts and no breadcrumbs. Most apply after a respring.
  - **JIT Enabler:** opens an app with JIT, for emulators and similar apps signed with a development profile.
  - **3-App Limit:** shows which sideloaded apps count toward the free Apple ID limit and frees the slots. Run it again after installing or refreshing an app.
  - **Wallet Card Art:** replace a Wallet card's picture with your own (cosmetic); the original is backed up and can be restored.
  - **App Decrypt:** makes a decrypted IPA of an App Store app on your device, e.g. to inject a tweak and sideload it. The app is started in the background and its code is read decrypted from it; app extensions and Watch apps are left out. A progress bar shows how far it is. IPAs stay on your device until you share them. Only for apps you own.
- **File Browser:**
  - **Copy, Cut and Paste** between folders (long-press an item, then use + in the target folder).
  - **Image viewer** with zoom and Share for PNG, JPEG, HEIC, GIF, WebP and more.
  - **Search in subfolders** (search tab "Subfolders"), with "Show in Folder" for each result.
  - **Sort By** Name, Date Modified or Size.
  - **Permissions…** to change the mode of files you own.

## Improvements

- **File Browser sharing:** files of any size can be shared now (before: up to 64 MB), and without needing room for a copy.
- **Cache Cleaner:** "Select Large Caches (50 MB+)" in the ⋯ menu picks only the caches worth clearing, and the result now explains that apps refill their caches as you use them.
- **Cache Cleaner on small iPhones:** the blue Clean button is easier to hit; taps near the edge of the bottom bar now count (reported on the iPhone mini).

## Good to know

- The Lara tools are new and change parts of SpringBoard at runtime. If something looks wrong, a respring undoes Debug Overlay and Upside Down; Hidden Settings can be switched off again.
- JIT only works for apps installed with a development profile (get-task-allow); some apps can't tell JIT is on.

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
