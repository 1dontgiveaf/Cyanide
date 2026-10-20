#!/usr/bin/env python3
"""Regression contract for safe iPad share popover source anchoring."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SOURCE = (ROOT / "Cyanide/FileBrowserViewController.m").read_text()

anchor_start = SOURCE.index("UIPopoverPresentationController *pop")
anchor_end = SOURCE.index("[host presentViewController", anchor_start)
anchor = SOURCE[anchor_start:anchor_end]
assert "[source isKindOfClass:UIBarButtonItem.class]" in anchor
assert "((UIView *)source).window == presenter.view.window" in anchor
assert "((UIView *)source).superview != nil" in anchor
assert "pop.sourceView = host.view;" in anchor
assert anchor.index("window == presenter.view.window") < anchor.index("pop.sourceView = source;")

# Synthetic state model: only an attached view in the presenter's window is a
# valid source.  Everything else uses the stable presenter fallback.
def source_route(kind, attached, same_window, host_is_presenter, item_in_nav):
    if kind == "bar-item":
        return "bar-item" if host_is_presenter and item_in_nav else "presenter"
    return "view" if attached and same_window else "presenter"

assert source_route("bar-item", False, False, True, True) == "bar-item"
assert source_route("bar-item", False, False, False, True) == "presenter"
assert source_route("bar-item", False, False, True, False) == "presenter"
assert source_route("view", True, True, True, False) == "view"
assert source_route("view", False, True, True, False) == "presenter"
assert source_route("view", True, False, True, False) == "presenter"
print("share popover anchor contract: PASS")
