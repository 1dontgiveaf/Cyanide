> **Supported:** iPhone / iPad on iOS/iPadOS `17.0 – 18.7.1` or `26.0 – 26.0.1`.
> **Not supported:** iPhone 17 (A19 / A19 Pro) and M5 — Memory Integrity Enforcement.
> Any other device on a supported version works. [Details](https://github.com/kolbicz/Cyanide#supported-devices)

# Cyanide 1.9.0

Daemons, System Info, a Reboot button and a smarter Location Services toggle, plus three rounds of review fixes.

## New

- **Daemons.** Turn launchd system services off and on. Changes are staged and written on Save, risky groups stay behind a second switch, and each row shows its process and PID. Turning Software Updates back on also clears the OTA blocks.
- **System Info.** Device and iOS details, uptime, kernel-access status, battery health and storage per app, with icons and sorting.
- **Reboot.** A Reboot button next to Respring in Quick Actions. It stops live tweaks first, then asks iOS to restart.
- **Faster respring.** SpringBoard is asked to restart itself instead of being forced to; the old way is still used if that request can't be confirmed.
- **Location Services toggle goes back where you were.** From Control Center or Shortcuts over an app, Cyanide returns to that app afterwards; from the Home Screen, to the Home Screen. Run while Cyanide is open, it stays.
- **File Browser app names.** Container folders show the app's name and icon, with a jump between an app's bundle and its data.
- **What's New is back** in Settings, with Show Less at the top.

## Fixes

- Tweaks no longer report "applied" when the change couldn't be confirmed: SBCustomizer, Drag Coefficient, Powercuff, NiceBar Lite, Watch Pairing, Location Simulator and OTA now say when something didn't take.
- Turning off a DarkSword patch now offers a respring; it stays active until then.
- A tweak removed from its source is stopped and uninstalled, and an out-of-date repo script no longer runs.
- A failed theme apply keeps the current theme instead of breaking it.
- Imports are size-limited while reading, archives never clear a folder that has content, and files that change while being read are rejected.
- The install queue can't start a second run while one is in progress.
- More kernel-access and SpringBoard-session paths stop safely instead of risking a reboot.
- NiceBar Lite no longer writes your location into the log.

## Good to know

> [!CAUTION]
> **You're responsible for your changes.** Disabling daemons or editing files can break iOS or your data. Keep a backup before changing anything you are unsure about.

- Some file-system tweaks (OTA, Watch Pairing, Passcode Style, Call Recording Sound) now stop with an error on devices where Cyanide's safer file-access path doesn't work, instead of using a riskier fallback.
- A reboot takes as long as a normal iPhone restart; Cyanide's own part is a few seconds.

## About A18 / M4

- **pe_v3 is the default A18/M4 exploit path.** It stages once, hunts one mapping and re-rolls a fresh layout instead of grinding a hunt that has gone on too long. pe_v1 stays available as the compatibility path.
- **Checks after every hunt.** The app verifies its mapping after each hunt and after a successful acquisition before doing any further work. This catches a broken state earlier; it doesn't make a run risk-free, and a run can still reboot an A18 / M4 device.
