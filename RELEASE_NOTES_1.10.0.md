> **Supported:** iPhone / iPad on iOS/iPadOS `17.0 – 18.7.1` or `26.0 – 26.0.1`.
> **Not supported:** iPhone 17 (A19 / A19 Pro) and M5 — Memory Integrity Enforcement.
> Any other device on a supported version works. [Details](https://github.com/kolbicz/Cyanide#supported-devices)

# Cyanide 1.10.0

A Cache Cleaner, a Run Exploit button and one consistent way for the tools to get kernel access, file sharing from the File Browser, accurate icon resizing, and a cleaned-up Daemons list.

## New

- **Cache Cleaner** (Home → Tools, or Settings). Shows how much space each app's `Library/Caches` and `tmp` folders use and clears the ones you pick.
  - Only cache and temporary contents are removed. Documents, settings, logins and other app data are never touched.
  - Apps in use are skipped and re-checked right before each one is cleaned; built-in apps are not selected by default.
  - A summary shows what's reclaimable and how much is selected; apps can be sorted by size or name and filtered by name.
  - Long-press an app to open its caches in the File Browser, or use **Review Folders** to see the exact paths before cleaning.
  - **Crash Logs** is a separate, opt-in row. It removes only the contents of the CrashReporter folders, never app data. The same folder review and confirmation apply.
  - The first time you open it, Cyanide explains what cleaning can cause before anything can be removed.
  - While it loads, it shows what it's doing (getting access, finding apps, checking running apps, scanning).
- **Run Exploit** (Home → Tools, shown only while Cyanide has no kernel access). Runs the exploit for the tools without applying any tweaks, with the log shown while it runs.
- **Share files from the File Browser.** Long-press any file and choose **Share…** to AirDrop it, mail it or save it to Files. The plist editor has a share button too. A copy is shared, never the original.

## Improvements

- **Kernel access for the tools.** Process Viewer, File Browser, Daemons, Cleaner, System Info and the Location Services toggle (also from Control Center and links) reuse live or saved kernel access. When there is none, they run the exploit by themselves, except on A18 / M4, where a run can reboot the device: there they ask whether to run it (or use **Run Exploit** on Home), and the run happens with the log on screen instead of hidden in the background.
- **Cleaner safety.** Cleaning never follows links out of an app's folders, scans are bounded and stop if Cyanide goes to the background, and the result reports the space actually freed. An app that changes during a clean is skipped instead of stopping the whole pass, and the progress bar moves as each app finishes.
- **Daemons list.** Groups and daemons that don't exist on your iOS version are hidden instead of shown greyed out as "not running". AirPrint and Bluetooth Wake were removed: neither is a system daemon on iOS 17 or 18. A daemon you disabled with an older version can still be switched back on.
- **Home Layout Extras.** Uneven left/right Home Screen padding is kept when icons are resized, the Dock keeps scaling evenly, and turning Layout Extras off restores the normal layout while remembering your slider values.
- **What's New on Home** opens Settings → What's New when tapped.
- **Respring screen.** While SpringBoard restarts, Cyanide shows its logo and "Preparing respring…" instead of a second spinner next to the one from iOS.
- **Process Viewer.** Incomplete or inconsistent process lists are discarded instead of shown, apps are only marked as suspended when their identity is confirmed, and calibration can no longer be disturbed by a refresh running at the same time.

## Fixes

- **Theme and archive imports** verify ZIP checksums and only take effect once the whole archive has been checked, so a damaged archive no longer leaves half-imported files.
- **Icon scale (Home Layout Extras)** now starts from your device's real icon size. Before, it assumed 60 pt icons drawn at 2x. On iPhones with 64 pt icons, the percentage therefore shrank icons more than set, and icons came out slightly blurry on 3x screens. Clock and Calendar now match the other icons too.
- **Location Services toggle:** returning to the app you ran it from also works when Cyanide comes to the foreground in between.
- **Cleaner on A18 / M4:** fixed a device reboot that could happen while the Cleaner checked which apps are running.
- **Respring** no longer falls back to the slower WebKit method when you respring right after opening Cyanide, or when cleanup takes a moment longer.

## Removed

- **Auto-Upload Logs** was removed from Settings. Logs stay on your device; use **Share Log** to send one.

## Good to know

> [!CAUTION]
> **Cleaning caches has side effects.** Apps load slower at first and use data to rebuild their caches. Some apps keep offline content (music, podcasts, maps, game data) in their cache, which then has to be downloaded again; check large caches before cleaning. Rarely an app asks you to sign in again, and an app waiting in the background may crash once when you return to it.

- The freed space is temporary: apps refill their caches as you use them.
- **Icon scale looks different after updating?** On iPhones with 64 pt icons, the same Home and Dock scale now shrinks icons less than before. To keep your old look, lower the value by about 6 (for example 98 % → 92 %).

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
