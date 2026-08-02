"""Port of cr/test_dictate.lua — raw whisper stdout through clean().
Imports crw.dictate without sounddevice installed: voice deps are optional
and the parser must not depend on them."""

import _bootstrap  # noqa: F401
import unittest

from crw import dictate


class TestClean(unittest.TestCase):
    def ok(self, raw, want):
        text, reason = dictate.clean(raw)
        self.assertIsNotNone(text, f"rejected: {reason}")
        self.assertEqual(text.lower(), want.lower())

    def rejected(self, raw):
        text, reason = dictate.clean(raw)
        self.assertIsNone(text)

    def test_leading_space_and_trailing_period_stripped(self):
        self.ok(" Remind me to water the plants.", "water the plants")

    def test_bare_command_needs_no_preamble(self):
        self.ok(" Water the plants.", "water the plants")

    def test_time_phrase_does_not_truncate_task(self):
        # REGRESSION LOCK (inherited): the held key defines the end, so
        # nothing may truncate on content — "and cc legal" must survive
        self.ok(" Remind me to email Sarah at 3pm and cc legal.",
                "email Sarah at 3pm and cc legal")

    def test_inner_capitalization_survives(self):
        text, _ = dictate.clean(" Remind me to reply to Saujas about the take-home.")
        self.assertEqual(text, "reply to Saujas about the take-home")

    def test_blank_audio_rejected(self):
        self.rejected(" [BLANK_AUDIO]")

    def test_hallucinated_caption_rejected(self):
        # whisper does not return empty on silence, it hallucinates captions
        self.rejected(" Thank you.")

    def test_empty_rejected(self):
        self.rejected("")

    def test_noise_matches_whole_strings_only(self):
        # REGRESSION LOCK: as a substring test, "thank you" would swallow this
        self.ok(" Thank Ruth for the coffee.", "thank Ruth for the coffee")

    def test_condition_reaches_shared_parser_intact(self):
        self.ok(" Remind me to send the summary once I'm done with this.",
                "send the summary once I'm done with this")


if __name__ == "__main__":
    unittest.main()
