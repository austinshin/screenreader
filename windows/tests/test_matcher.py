"""Referent binding and the presence predicate."""

import _bootstrap  # noqa: F401
import unittest

from crw import matcher

VIDEO = {"app": "Chrome", "exe": "chrome.exe",
         "title": "Talk - YouTube - Google Chrome",
         "url": "https://www.youtube.com/watch?v=abc123&t=42s"}
SLACK = {"app": "Slack", "exe": "slack.exe", "title": "#general - Slack"}


class TestMatcher(unittest.TestCase):
    def test_spinner_and_braille_stripped(self):
        # terminals render spinner frames into titles; every frame looked
        # like a context change until these were stripped
        self.assertEqual(matcher.normalize_title("⠧ vim — notes.md"), "vim — notes.md")
        self.assertEqual(matcher.normalize_title("✳ build running"), "build running")

    def test_youtube_url_key_is_the_video_id(self):
        self.assertEqual(matcher.url_key("https://www.youtube.com/watch?v=abc123&t=42s"),
                         "yt:abc123")
        self.assertEqual(matcher.url_key("https://youtu.be/abc123?t=9"), "yt:abc123")

    def test_other_urls_keep_query_drop_fragment(self):
        self.assertEqual(matcher.url_key("https://x.com/a?q=1#frag"),
                         "https://x.com/a?q=1")

    def test_url_bound_matches_by_video_id(self):
        ref = matcher.bind(VIDEO)
        seeked = dict(VIDEO, url="https://www.youtube.com/watch?v=abc123&t=99s",
                      title="Talk (99:00) - YouTube - Google Chrome")
        self.assertTrue(matcher.matches(ref, seeked))
        self.assertFalse(matcher.matches(ref, SLACK))

    def test_title_bound_needs_same_exe(self):
        ref = matcher.bind(SLACK)
        self.assertTrue(matcher.matches(ref, dict(SLACK, title="#general - Slack ")))
        self.assertFalse(matcher.matches(ref, dict(SLACK, exe="chrome.exe")))

    def test_media_fallback_playing_in_background(self):
        # a bound video still playing in a background tab is not "done"
        ref = matcher.bind(dict(VIDEO, url=None))
        elsewhere = dict(SLACK, media={"title": "Talk - YouTube - Google Chrome",
                                       "playing": True})
        self.assertTrue(matcher.matches(ref, elsewhere))
        paused = dict(SLACK, media={"title": "Talk - YouTube - Google Chrome",
                                    "playing": False})
        self.assertFalse(matcher.matches(ref, paused))

    def test_nothing_bindable(self):
        self.assertIsNone(matcher.bind({"app": "X", "exe": "x.exe"}))
        self.assertIsNone(matcher.bind(None))


if __name__ == "__main__":
    unittest.main()
