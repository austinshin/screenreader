"""Tier classification — the opening position rules."""

import _bootstrap  # noqa: F401
import unittest

from crw import tier


class TestTier(unittest.TestCase):
    def test_urgency_wins(self):
        t, why = tier.classify("submit the form before it closes", bound=False)
        self.assertEqual(t, tier.CRITICAL)

    def test_binding_beats_tier2_words(self):
        # "reply" is a tier-2 word, but the binding already says when it's
        # relevant — moving it to upcoming would file it under a heading
        # whose trigger it doesn't use
        t, why = tier.classify("reply to this thread", bound=True)
        self.assertEqual(t, tier.INCONTEXT)

    def test_critical_survives_binding(self):
        t, why = tier.classify("urgent: reply to this thread", bound=True)
        self.assertEqual(t, tier.CRITICAL)

    def test_informational_survives_binding(self):
        t, why = tier.classify("keep an eye on the build", bound=True)
        self.assertEqual(t, tier.AMBIENT)

    def test_default_is_upcoming(self):
        t, why = tier.classify("water the plants", bound=False)
        self.assertEqual(t, tier.UPCOMING)

    def test_only_critical_bypasses_seam_gate(self):
        self.assertTrue(tier.bypasses_seam_gate(tier.CRITICAL))
        for t in (tier.UPCOMING, tier.INCONTEXT, tier.AMBIENT, None):
            self.assertFalse(tier.bypasses_seam_gate(t))


if __name__ == "__main__":
    unittest.main()
