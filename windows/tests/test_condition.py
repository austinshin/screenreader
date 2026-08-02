"""Condition extraction — the brief's own phrasings, leading and trailing."""

import _bootstrap  # noqa: F401
import unittest

from crw import condition


class TestCondition(unittest.TestCase):
    def test_trailing_finish(self):
        clean, cond = condition.extract(
            "look into embeddings after I finish watching this video")
        self.assertEqual(clean, "look into embeddings")
        self.assertEqual(cond, "after I finish watching this video")

    def test_leading_done(self):
        clean, cond = condition.extract(
            "once I'm done testing the gate, share progress in #eng")
        self.assertEqual(clean, "share progress in #eng")
        self.assertEqual(cond, "once I'm done testing the gate")

    def test_trailing_wrap_up(self):
        clean, cond = condition.extract(
            "update Megan when I wrap up this conversation on Slack")
        self.assertEqual(clean, "update Megan")
        self.assertEqual(cond, "when I wrap up this conversation on Slack")

    def test_trailing_done_here(self):
        clean, cond = condition.extract("reply to this thread once I'm done here")
        self.assertEqual(clean, "reply to this thread")
        self.assertEqual(cond, "once I'm done here")

    def test_no_condition_passes_through(self):
        clean, cond = condition.extract("water the plants")
        self.assertEqual(clean, "water the plants")
        self.assertIsNone(cond)

    def test_im_without_apostrophe(self):
        clean, cond = condition.extract("send the doc when im done with this review")
        self.assertEqual(clean, "send the doc")
        self.assertEqual(cond, "when im done with this review")


if __name__ == "__main__":
    unittest.main()
