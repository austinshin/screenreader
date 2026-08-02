"""The trigger FSM on synthetic snapshots — no wall-clock waiting. This is
the coverage the Lua side kept only as an inline heredoc in smoke-test.sh,
plus the retier limits (which had no test at all until the escalation bug)."""

import _bootstrap  # noqa: F401
import time
import unittest

from crw import config, notifier, reminders, tier, trigger

VIDEO = {"app": "Chrome", "exe": "chrome.exe", "title": "Talk - YouTube",
         "url": "https://www.youtube.com/watch?v=smoke", "reason": "timer"}
SLACK = {"app": "Slack", "exe": "slack.exe", "title": "#general",
         "reason": "timer"}
SEAM = {"app": "Slack", "exe": "slack.exe", "title": "#general",
        "reason": "app-switch"}


class TriggerTest(unittest.TestCase):
    def setUp(self):
        reminders.items.clear()
        self.notified = []
        self._real_notify = notifier.notify
        notifier.notify = lambda payload, opts=None: (
            self.notified.append((payload, opts or {})) or ["card"])

    def tearDown(self):
        notifier.notify = self._real_notify

    def test_edge_triggered_full_trace(self):
        r = reminders.add("smoke test reminder", VIDEO)
        trace = [r["state"]]                       # armed: thing on screen now
        trigger.tick(SLACK); trace.append(r["state"])   # cooldown
        trigger.tick(VIDEO); trace.append(r["state"])   # re-armed: not "done"
        for _ in range(config.ABSENT_SAMPLES):
            trigger.tick(SLACK)
        trace.append(r["state"])                        # ready
        trigger.tick(SEAM); trace.append(r["state"])    # fired on the seam
        self.assertEqual(trace, ["armed", "cooldown", "armed", "ready", "fired"])
        self.assertEqual(len(self.notified), 1)
        why = self.notified[0][1]["trigger"]["why"]
        self.assertIn("you switched apps", why)

    def test_never_fires_while_focused(self):
        r = reminders.add("smoke", VIDEO)
        for _ in range(config.ABSENT_SAMPLES * 3):
            trigger.tick(VIDEO)
        self.assertEqual(r["state"], "armed")
        self.assertEqual(self.notified, [])

    def test_ready_waits_for_seam_not_timer_ticks(self):
        r = reminders.add("smoke", VIDEO)
        for _ in range(config.ABSENT_SAMPLES + 1):
            trigger.tick(SLACK)
        self.assertEqual(r["state"], "ready")
        trigger.tick(SLACK)  # another plain tick: no seam, must not fire
        self.assertEqual(r["state"], "ready")

    def test_proximity_caps_at_upcoming_never_critical(self):
        # the escalation bug: every "in 5 minutes" reminder used to pass
        # through critical (siren, forced banner, seam-gate bypass)
        r = reminders.add("stretch", None, {"dueAt": int(time.time()) + 120})
        self.assertEqual(r["tier"], tier.UPCOMING)
        trigger.tick(SLACK)
        self.assertEqual(r["tier"], tier.UPCOMING)

    def test_ambient_never_promoted_by_the_clock(self):
        r = reminders.add("keep an eye on the build", None,
                          {"dueAt": int(time.time()) + 120})
        self.assertEqual(r["tier"], tier.AMBIENT)
        trigger.tick(SLACK)
        self.assertEqual(r["tier"], tier.AMBIENT)

    def test_ambient_fires_silently(self):
        # "never interrupts" includes the moment it fires: dashboard and
        # glance only, no card, no channel dispatch
        r = reminders.add("keep an eye on the build", None,
                          {"dueAt": int(time.time()) - 5})
        trigger.check_due(SLACK)
        self.assertEqual(r["state"], "fired")
        self.assertEqual(self.notified, [])

    def test_ambient_promoted_when_its_context_appears(self):
        # the deliberate exception: something you were only tracking is now
        # in front of you
        r = reminders.add("keep an eye on this", VIDEO)
        self.assertEqual(r["tier"], tier.AMBIENT)
        reminders.set_state(r, "pending")  # it left the screen at some point
        trigger.tick(VIDEO)
        self.assertEqual(r["tier"], tier.INCONTEXT)

    def test_defer_converts_contextual_to_scheduled(self):
        # "in 5 minutes" must not mean "in 5 minutes, if you also happen to
        # finish that thing"
        r = reminders.add("smoke", VIDEO)
        trigger.defer_by(r, 5, "5 min")
        self.assertEqual(r["state"], "scheduled")
        self.assertTrue(290 <= r["dueAt"] - time.time() <= 310)

    def test_scheduled_fires_on_the_clock(self):
        r = reminders.add("timed", None, {"dueAt": int(time.time()) - 1})
        trigger.check_due(SLACK)
        self.assertEqual(r["state"], "fired")
        why = self.notified[0][1]["trigger"]["why"]
        self.assertIn("the time you set arrived", why)

    def test_restore_fired_is_card_only_no_mirror(self):
        # remote channels already delivered once; a restart must not re-ping
        # a phone about nothing
        r = reminders.add("smoke", VIDEO)
        reminders.set_state(r, "fired")
        trigger.restore_fired()
        self.assertEqual(len(self.notified), 1)
        opts = self.notified[0][1]
        self.assertEqual(opts["channels"], ["card"])
        self.assertTrue(opts["no_mirror"])

    def test_persistence_roundtrip(self):
        reminders.add("survives restart", VIDEO)
        reminders.items.clear()
        reminders.load()
        self.assertEqual(len(reminders.items), 1)
        self.assertEqual(reminders.items[0]["text"], "survives restart")


if __name__ == "__main__":
    unittest.main()
