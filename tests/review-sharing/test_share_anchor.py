#!/usr/bin/env python3
"""Regression contract for safe iPad share popover source anchoring."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SOURCE = (ROOT / "Cyanide/FileBrowserViewController.m").read_text()

anchor_start = SOURCE.index("UIPopoverPresentationController *pop")
anchor_end = SOURCE.index("[presenter presentViewController", anchor_start)
anchor = SOURCE[anchor_start:anchor_end]
assert "[source isKindOfClass:UIBarButtonItem.class]" in anchor
assert "((UIView *)source).window == presenter.view.window" in anchor
assert "((UIView *)source).superview != nil" in anchor
assert "pop.sourceView = presenter.view;" in anchor
assert anchor.index("window == presenter.view.window") < anchor.index("pop.sourceView = source;")

# Synthetic state model: only an attached view in the presenter's window is a
# valid source.  Everything else uses the stable presenter fallback.
def source_route(kind, attached, same_window):
    if kind == "bar-item":
        return "bar-item"
    return "view" if attached and same_window else "presenter"

assert source_route("bar-item", False, False) == "bar-item"
assert source_route("view", True, True) == "view"
assert source_route("view", False, True) == "presenter"
assert source_route("view", True, False) == "presenter"
print("share popover anchor contract: PASS")
