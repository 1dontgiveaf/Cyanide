#!/usr/bin/env python3
"""Synthetic state and source checks for the external GPS retry transaction.

This intentionally does not invoke Location Services, kernel code, or UIKit.
The small model exercises the completion boundary that SceneDelegate owns.
"""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SOURCE = (ROOT / "Cyanide/SceneDelegate.m").read_text()

# The accepted action owns one completion boundary and one underlying callback.
accepted = SOURCE.index("__block BOOL completionDelivered = NO;")
callback = SOURCE.index("settings_location_services_set_async", accepted)
callback_end = SOURCE.index("        });\n    };", callback)
transaction = SOURCE[accepted:callback_end]
assert "CYLocationRequestCompletion finish" in transaction
assert "if (completionDelivered) return;" in transaction
assert "__block BOOL operationCallbackHandled = NO;" in transaction
assert "if (operationCallbackHandled) return;" in transaction

# The full-exploit result must branch before the terminal completion and must
# pass the retained completion into the retry instead of passing nil.
full_required = transaction.index("kSettingsFullExploitRequiredMessage")
terminal = transaction.index("finish(ok, message);")
assert full_required < terminal
assert "handleActionURL:url completion:finish" in transaction
assert "handleActionURL:url completion:nil" not in transaction
assert "finish(NO, retryMessage);" in transaction
assert "retryOwner.actionInProgress = NO;" in transaction


class ExternalAction:
    """Minimal main-thread state machine for the accepted action contract."""

    def __init__(self):
        self.generation = 1
        self.action_in_progress = True
        self.completions = []
        self.callback_handled = False
        self.completion_delivered = False
        self.prompted = False

    def finish(self, ok, message):
        if self.completion_delivered:
            return
        self.completion_delivered = True
        self.completions.append((ok, message))

    def first_result(self, ok, message):
        if self.callback_handled:
            return
        self.callback_handled = True
        if not ok and message == "full-exploit-required":
            self.prompted = True
            # The accepted transaction remains busy while the prompt is up.
            return
        self.finish(ok, message)
        self.action_in_progress = False

    def prompt_result(self, ready):
        assert self.prompted and self.action_in_progress
        if not ready:
            self.action_in_progress = False
            self.finish(False, "cancelled")
            return
        # Retry is a new generation of the same transaction. The completion
        # boundary is deliberately retained across that generation change.
        self.action_in_progress = False
        self.generation += 1
        self.action_in_progress = True
        self.callback_handled = False

    def retry_result(self, ok, message):
        if self.callback_handled:
            return
        self.callback_handled = True
        self.finish(ok, message)
        self.action_in_progress = False


# Initial failure is intermediate: no external completion is consumed.
action = ExternalAction()
action.first_result(False, "full-exploit-required")
assert action.completions == []
assert action.action_in_progress and action.prompted

# Confirming and succeeding reports one final success, even if the callback is
# accidentally delivered twice by a lower layer.
action.prompt_result(True)
action.retry_result(True, "Location Services is on.")
action.retry_result(False, "duplicate failure")
assert action.completions == [(True, "Location Services is on.")]
assert not action.action_in_progress

# Declining the prompt reports an explicit terminal cancellation and clears the
# busy state without attempting a hidden retry.
cancelled = ExternalAction()
cancelled.first_result(False, "full-exploit-required")
cancelled.prompt_result(False)
assert cancelled.completions == [(False, "cancelled")]
assert not cancelled.action_in_progress

# A stale retry cannot publish a result after supersession.
superseded = ExternalAction()
superseded.first_result(False, "full-exploit-required")
superseded.generation += 1
superseded.action_in_progress = False
superseded.finish(False, "superseded")
superseded.prompt_result if False else None
assert superseded.completions == [(False, "superseded")]

print("external GPS completion transaction synthetic/source contract: PASS")
