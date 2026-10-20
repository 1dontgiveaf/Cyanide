#!/usr/bin/env python3
"""Synthetic contract and state-model tests for Layout Extras restoration."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
LAYOUT = (ROOT / "Cyanide/tweaks/darksword_layout.m").read_text()
HEADER = (ROOT / "Cyanide/tweaks/darksword_layout.h").read_text()
SETTINGS = (ROOT / "Cyanide/SettingsViewController.m").read_text()


def identity_transform():
    # The iOS 26 restore call supplies zero extras and unit icon scales.
    return (1.0, 1.0, 0.0, 0.0)


def restore_marker(enabled, applied, restore_succeeds):
    """Model the planner's marker transition, independent of UIKit/RemoteCall."""
    restore_planned = not enabled and applied
    return (restore_planned, False if restore_planned and restore_succeeds else applied)


assert identity_transform() == (1.0, 1.0, 0.0, 0.0)
assert restore_marker(False, True, True) == (True, False)
assert restore_marker(False, True, False) == (True, True)
assert restore_marker(True, True, True) == (False, True)
assert restore_marker(False, False, True) == (False, False)

assert "bool darksword_layout_restore_in_session(void);" in HEADER
assert "return darksword_layout_apply_in_session(0.0, 0.0, 0.0, 0.0," in LAYOUT
assert "0.0, 0.0, 1.0, 1.0);" in LAYOUT
assert "BOOL restoreLayoutExtras = !layoutExtrasEnabled" in SETTINGS
assert "settings_tweak_is_applied(kSettingsLayoutExtrasEnabled)" in SETTINGS
assert "settings_mark_tweak_applied(kSettingsLayoutExtrasEnabled, NO);" in SETTINGS
assert "if (ok) {" in SETTINGS
# Saved slider/configuration keys are read-only in the restore path; no reset or
# removal of LayoutHome/LayoutDock values is permitted.
restore_start = SETTINGS.index("static bool settings_restore_layout_extras_locked")
restore_end = SETTINGS.index("static GravityLiteConfig", restore_start)
restore_helper = SETTINGS[restore_start:restore_end]
assert "setInteger" not in restore_helper
assert "removeObject" not in restore_helper

print("layout restore synthetic tests: PASS")
