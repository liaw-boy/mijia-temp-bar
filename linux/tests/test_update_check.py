import time
import unittest
from unittest import mock

from mijia_temp_bar import update_check
from mijia_temp_bar.update_check import is_newer, is_trusted_release_url, parse_version, pick_latest

BASE = "https://github.com/liaw-boy/mijia-temp-bar/releases/tag/"


def release(tag, **extra):
    return {"tag_name": tag, "html_url": BASE + tag, "draft": False, "prerelease": False, **extra}


class VersionTests(unittest.TestCase):
    def test_compare(self):
        self.assertTrue(is_newer("1.10.0", "1.9.2"))
        self.assertTrue(is_newer("1.2", "1.1.9"))
        self.assertFalse(is_newer("1.1.0", "1.1.0"))
        self.assertFalse(is_newer("1.0.9", "1.1.0"))
        self.assertEqual(parse_version("2.0.0-beta"), (2, 0, 0))
        self.assertEqual(parse_version("x.y"), (0, 0))


class UrlTests(unittest.TestCase):
    def test_trusted(self):
        self.assertTrue(is_trusted_release_url(BASE + "linux-v1.2.0"))
        for bad in ("http://github.com/liaw-boy/mijia-temp-bar/x", "https://evil.example/liaw-boy/mijia-temp-bar/x",
                    "https://github.com/other/repo/x", "https://github.com.evil.example/liaw-boy/mijia-temp-bar/x"):
            self.assertFalse(is_trusted_release_url(bad), bad)


class PickLatestTests(unittest.TestCase):
    def test_ignores_macos_tags(self):
        result = pick_latest([release("v1.7.1"), release("v9.0.0")], "1.1.0")
        self.assertEqual(result.kind, "up_to_date")

    def test_finds_newest_linux_release(self):
        result = pick_latest([release("linux-v1.2.0"), release("linux-v1.10.0"), release("v1.7.1")], "1.1.0")
        self.assertEqual((result.kind, result.version), ("available", "1.10.0"))

    def test_skips_draft_prerelease_and_untrusted_url(self):
        releases = [
            release("linux-v2.0.0", draft=True),
            release("linux-v2.1.0", prerelease=True),
            {"tag_name": "linux-v3.0.0", "html_url": "https://evil.example/x"},
        ]
        self.assertEqual(pick_latest(releases, "1.1.0").kind, "up_to_date")

    def test_malformed_input(self):
        self.assertEqual(pick_latest({"a": 1}, "1.1.0").kind, "failed")
        self.assertEqual(pick_latest([None, 5, {"tag_name": 3}], "1.1.0").kind, "up_to_date")


class WorkerTests(unittest.TestCase):
    def test_unexpected_exception_still_dispatches(self):
        received = []
        with mock.patch.object(update_check, "fetch_and_check", side_effect=RuntimeError("boom")), \
                mock.patch.object(update_check.settings, "set"):
            update_check.check_async(received.append, lambda fn, *a: fn(*a))
            for _ in range(100):
                if received:
                    break
                time.sleep(0.01)
        self.assertEqual([r.kind for r in received], ["failed"])

    def test_unicode_digits_do_not_crash(self):
        self.assertEqual(parse_version("1.\u00b2"), (1, 0))

    def test_auto_check_due_ignores_bad_timestamps(self):
        for bad in (float("inf"), float("nan"), True, "x", 10**12):
            with mock.patch.object(update_check.settings, "get", side_effect=lambda k, d=None, v=bad: True if k == update_check.AUTO_KEY else v):
                self.assertTrue(update_check.due_for_auto_check(1000.0), bad)


if __name__ == "__main__":
    unittest.main()
