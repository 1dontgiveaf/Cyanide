#!/usr/bin/env python3
"""Source/state contract checks for interrupted quiet GPS returns."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SOURCE = (ROOT / "Cyanide/SceneDelegate.m").read_text()

handle_start = SOURCE.index("- (void)handleActionURL:(NSURL *)url completion:")
active_start = SOURCE.index("- (void)sceneDidBecomeActive:")
foreground_start = SOURCE.index("- (void)sceneWillEnterForeground:")
background_start = SOURCE.index("- (void)sceneDidEnterBackground:")

handle = SOURCE[handle_start:active_start]
active = SOURCE[active_start:foreground_start]
foreground = SOURCE[foreground_start:background_start]
background = SOURCE[background_start:]

# The inactive completion records both the destination and the action owner.
assert "me2.homeOnNextActivation = YES;" in handle
assert "me2.returnAppOnNextActivation = returnApp;" in handle
assert "me2.deferredReturnGeneration = generation;" in handle

# A valid newer action invalidates the prior action's deferred return, while
# parse failures remain outside that supersession block.
parse_end = handle.index("    // A newly accepted action supersedes")
assert handle.index("if (!scene_parse_location_url") < parse_end
assert "self.homeOnNextActivation = NO;" in handle[parse_end:]
assert "self.returnAppOnNextActivation = nil;" in handle[parse_end:]
assert "self.deferredReturnGeneration = 0;" in handle[parse_end:]

# Activation consumes only an intent owned by the current action generation.
assert "BOOL ownedByCurrentAction = self.deferredReturnGeneration == self.actionGeneration;" in active
assert "if (ownedByCurrentAction) {" in active
assert "[self leaveToApp:app];" in active
assert active.index("self.returnAppOnNextActivation = nil;") < active.index("[self leaveToApp:app]")

# Both inactive and actual background interruptions must preserve action ownership.
assert "self.deferredReturnGeneration != 0" in foreground
assert "self.deferredReturnGeneration == self.actionGeneration" in foreground
assert "if (!preserveDeferredReturn)" in foreground
assert "sceneWasBackgrounded" not in foreground
assert "homeOnNextActivation = NO" not in background
assert "return; // Do not present an update prompt" in active

# State contract: a foreground transition preserves one current action's intent;
# consumption is once-only, and stale/ordinary reopen state does not return away.
def foreground_preserves(pending, owner, current):
    return pending and owner != 0 and owner == current
assert foreground_preserves(True, 7, 7) # interrupted action, regardless of background
assert not foreground_preserves(False, 0, 7) # ordinary reopen after consumption
assert not foreground_preserves(True, 6, 7) # superseding action
assert not foreground_preserves(True, 0, 0) # unowned initial state
print("deferred-return lifecycle source/state contract: PASS")
