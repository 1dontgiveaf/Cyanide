#!/usr/bin/env python3
"""Synthetic geometry checks for the iOS 26 layout transform.

This models UIView's centered scale plus the transform translation emitted by
 darksword_layout.m. It does not require SpringBoard or private UIKit classes.
"""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SOURCE = (ROOT / "Cyanide/tweaks/darksword_layout.m").read_text()


def transform(width, height, left, right, top, bottom, icon_scale):
    sx = sy = 1.0
    width_valid = height_valid = False
    if left + right and width > 0:
        available = width - left - right
        if available > 0:
            sx = available / width
            width_valid = True
    if top + bottom and height > 0:
        available = height - top - bottom
        if available > 0:
            sy = available / height
            height_valid = True
    if icon_scale > 0 and icon_scale != 1:
        sx *= icon_scale
        sy *= icon_scale
    tx = (left - right) / 2 if width_valid else 0.0
    ty = (top - bottom) / 2 if height_valid else 0.0
    return sx, sy, tx, ty


def centered_edges(size, scale, translation):
    half_remaining = (size - size * scale) / 2
    return half_remaining + translation, half_remaining - translation


def close(actual, expected, tolerance=1e-9):
    assert abs(actual - expected) <= tolerance, (actual, expected)


# The previously missing Home translation must preserve both asymmetric axes.
sx, sy, tx, ty = transform(390, 844, 31, 7, 42, 18, 1.0)
left, right = centered_edges(390, sx, tx)
top, bottom = centered_edges(844, sy, ty)
for actual, expected in ((left, 31), (right, 7), (top, 42), (bottom, 18)):
    close(actual, expected)

# Icon scale composes with the spacing scale while retaining the requested
# left/right and top/bottom differences (the extra scale's equal margins are
# not mistaken for asymmetric padding).
sx, sy, tx, ty = transform(390, 844, 31, 7, 42, 18, 0.9)
left, right = centered_edges(390, sx, tx)
top, bottom = centered_edges(844, sy, ty)
close(left - right, 24)
close(top - bottom, 24)

# Dock uses the historical horizontal total on both axes. Equal synthetic
# vertical edges preserve scaleY=scaleX without introducing a vertical shift.
sx, sy, tx, ty = transform(390, 390, 31, 7, 19, 19, 0.9)
close(sx, sy)
close(ty, 0.0)
close(tx, 12.0)
# A null edge sum is not a valid padding scale; asymmetric cancellation must
# remain identity rather than inventing a translation.
assert transform(390, 390, 10, -10, 0, 0, 1.0) == (1.0, 1.0, 0.0, 0.0)
# Stock values must produce a true identity transform, including no stale
# translation after a prior asymmetric run.
assert transform(390, 844, 0, 0, 0, 0, 1.0) == (1.0, 1.0, 0.0, 0.0)

# The geometry patch must not regress the explicitly supported dynamic icons.
for class_name in ("SBHClockApplicationIcon", "SBHCalendarApplicationIcon"):
    assert class_name in SOURCE
assert "result.tx = (extraLeft - extraRight) / 2.0;" in SOURCE
assert "result.ty = (extraTop - extraBottom) / 2.0;" in SOURCE
assert "double dockTotal = dockExL + dockExR;" in SOURCE
assert "dockTotal / 2.0, dockTotal / 2.0" in SOURCE
assert "double xf[6] = { scaleX, 0.0, 0.0, scaleY, tx, ty };" in SOURCE

print("layout geometry synthetic tests: PASS")
