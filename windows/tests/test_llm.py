"""The transcript-polish guards — the part that must be right without
Ollama in the room. The transport is stubbed; what's under test is the
policy: repair passes, rewrite dies, failure never touches the transcript."""

import _bootstrap  # noqa: F401
import unittest

from crw import llm


class TestGuards(unittest.TestCase):
    def test_number_normalization_is_a_repair(self):
        ok, _ = llm._acceptable("buy milk at one thirty", "buy milk at 1:30")
        self.assertTrue(ok)

    def test_homophone_fix_is_a_repair(self):
        ok, _ = llm._acceptable("by milk on the way home", "buy milk on the way home")
        self.assertTrue(ok)

    def test_added_information_is_a_rewrite(self):
        # hallucinating a time onto a reminder is worse than any mishearing
        ok, reason = llm._acceptable("water the plants",
                                     "water the plants tomorrow morning")
        self.assertFalse(ok)

    def test_unrelated_output_is_a_rewrite(self):
        ok, _ = llm._acceptable("email sarah about the deck",
                                "here is your corrected reminder")
        self.assertFalse(ok)

    def test_runaway_growth_is_a_rewrite(self):
        ok, _ = llm._acceptable("call mom", "call mom " + "and also " * 20)
        self.assertFalse(ok)


class TestPolish(unittest.TestCase):
    def setUp(self):
        self._avail, self._chat = llm.available, llm._chat

    def tearDown(self):
        llm.available, llm._chat = self._avail, self._chat

    def test_no_ollama_means_passthrough(self):
        llm.available = lambda: None
        text, meta = llm.polish("by milk at one thirty")
        self.assertEqual(text, "by milk at one thirty")
        self.assertIsNone(meta)

    def test_good_repair_is_accepted_with_provenance(self):
        llm.available = lambda: "test-model"
        llm._chat = lambda model, text: "buy milk at 1:30"
        text, meta = llm.polish("by milk at one thirty")
        self.assertEqual(text, "buy milk at 1:30")
        self.assertEqual(meta["model"], "test-model")
        self.assertEqual(meta["raw"], "by milk at one thirty")

    def test_hallucination_is_discarded(self):
        llm.available = lambda: "test-model"
        llm._chat = lambda model, text: "water the plants tomorrow morning"
        text, meta = llm.polish("water the plants")
        self.assertEqual(text, "water the plants")
        self.assertIsNone(meta)

    def test_unchanged_output_reports_unchanged(self):
        llm.available = lambda: "test-model"
        llm._chat = lambda model, text: text
        text, meta = llm.polish("water the plants")
        self.assertEqual(text, "water the plants")
        self.assertIsNone(meta)

    def test_transport_failure_never_loses_the_transcript(self):
        llm.available = lambda: "test-model"

        def boom(model, text):
            raise OSError("connection refused")
        llm._chat = boom
        text, meta = llm.polish("water the plants")
        self.assertEqual(text, "water the plants")
        self.assertIsNone(meta)

    def test_empty_output_is_passthrough(self):
        llm.available = lambda: "test-model"
        llm._chat = lambda model, text: ""
        text, meta = llm.polish("water the plants")
        self.assertEqual(text, "water the plants")
        self.assertIsNone(meta)


if __name__ == "__main__":
    unittest.main()
