"""Port of cr/test_timeparse.lua — same cases, same structural assertions
(month/day/hour, "in the future") so the suite passes at any time of day."""

import _bootstrap  # noqa: F401
import time
import unittest

from crw import timeparse


class TestTimeparse(unittest.TestCase):
    def test_plain_task_untouched(self):
        clean, at, phrase = timeparse.extract("reply to the thread")
        self.assertIsNone(at)
        self.assertEqual(clean, "reply to the thread")

    def test_today_parses_and_stays_future(self):
        # regression lock (from the Lua side): "today" once crashed extraction
        clean, at, phrase = timeparse.extract("buy milk today")
        self.assertEqual(clean, "buy milk")
        self.assertIsNotNone(at)
        self.assertGreater(at, time.time())
        self.assertLess(at - time.time(), 86400)

    def test_tonight_means_evening_never_past(self):
        clean, at, phrase = timeparse.extract("water the plants tonight")
        self.assertEqual(clean, "water the plants")
        self.assertGreater(at, time.time())
        self.assertLess(at - time.time(), 86400)

    def test_at_130_reads_as_one_thirty(self):
        # the "four seconds from now" incident: speech drops the colon
        clean, at, phrase = timeparse.extract("get on a meeting at 130")
        self.assertEqual(clean, "get on a meeting")
        self.assertGreater(at, time.time())
        d = time.localtime(at)
        self.assertEqual(d.tm_min, 30)
        self.assertEqual(d.tm_hour % 12, 1)

    def test_time_and_date_keep_both_halves(self):
        clean, at, phrase = timeparse.extract("send it at 5pm august 1")
        self.assertEqual(clean, "send it")
        d = time.localtime(at)
        self.assertEqual((d.tm_mon, d.tm_mday, d.tm_hour), (8, 1, 17))

    def test_bare_hour_next_occurrence(self):
        clean, at, phrase = timeparse.extract("call the vet at 4")
        self.assertEqual(clean, "call the vet")
        self.assertGreater(at, time.time())
        d = time.localtime(at)
        self.assertEqual(d.tm_hour % 12, 4)
        self.assertEqual(d.tm_min, 0)

    def test_relative_with_filler(self):
        clean, at, phrase = timeparse.extract("stretch in like five minutes")
        self.assertEqual(clean, "stretch")
        self.assertTrue(290 <= at - time.time() <= 310)

    def test_dangling_connective_trimmed(self):
        clean, at, phrase = timeparse.extract("pay rent on august 1")
        self.assertEqual(clean, "pay rent")
        d = time.localtime(at)
        self.assertEqual((d.tm_mon, d.tm_mday, d.tm_hour), (8, 1, 9))

    def test_today_with_explicit_time_keeps_it(self):
        clean, at, phrase = timeparse.extract("submit the report today at 11:59pm")
        self.assertEqual(clean, "submit the report")
        d = time.localtime(at)
        self.assertEqual((d.tm_hour, d.tm_min), (23, 59))

    def test_tomorrow(self):
        clean, at, phrase = timeparse.extract("ship the build tomorrow at 9am")
        self.assertEqual(clean, "ship the build")
        d = time.localtime(at)
        n = time.localtime(time.time() + 86400)
        self.assertEqual((d.tm_mon, d.tm_mday, d.tm_hour), (n.tm_mon, n.tm_mday, 9))


if __name__ == "__main__":
    unittest.main()
