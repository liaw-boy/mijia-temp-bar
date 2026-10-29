import math
import unittest

from mijia_temp_bar.device_view import (
    SEGMENTS,
    digit_units,
    face_for_humidity,
    format_humidity,
    format_temperature,
    should_show_low_battery,
)
from mijia_temp_bar.options import describe_interval, parse_interval_minutes

try:
    import gi  # noqa: F401
    from mijia_temp_bar.chart import choose_time_step, filter_recent
    from mijia_temp_bar.history import HistoryPoint
    HAS_GTK = True
except (ImportError, ValueError):
    HAS_GTK = False


class IntervalInputTests(unittest.TestCase):
    def test_valid_minutes(self):
        self.assertEqual(parse_interval_minutes("5"), 300.0)
        self.assertEqual(parse_interval_minutes(" 0.5 "), 30.0)
        self.assertEqual(parse_interval_minutes("1440"), 86400.0)

    def test_invalid_input(self):
        for text in ("", "abc", "0.4", "1441", "-3", "nan", "inf"):
            self.assertIsNone(parse_interval_minutes(text), text)

    def test_describe(self):
        self.assertEqual(describe_interval(90 * 60.0), "1.5 小時")
        self.assertEqual(describe_interval(7200.0), "2 小時")
        self.assertEqual(describe_interval(420.0), "7 分鐘")


class DeviceViewLogicTests(unittest.TestCase):
    def test_faces(self):
        self.assertEqual(face_for_humidity(50), "(^_^)")
        self.assertEqual(face_for_humidity(39.9), "(-_-)")
        self.assertEqual(face_for_humidity(65.1), "(>_<)")
        self.assertEqual(face_for_humidity(None), "(-_-)")

    def test_formatting(self):
        self.assertEqual(format_temperature(26.84), "26.8")
        self.assertEqual(format_temperature(-3.5), "-3.5")
        self.assertEqual(format_temperature(None), "--.-")
        self.assertEqual(format_humidity(57.6), "58")
        self.assertEqual(format_humidity(None), "--")

    def test_every_formatted_char_is_drawable(self):
        for text in (format_temperature(-12.3), format_temperature(99.9), format_humidity(100), "--.-", "--"):
            for char in text:
                self.assertTrue(char == "." or char in SEGMENTS, char)
                self.assertTrue(math.isfinite(digit_units(char)))

    def test_segment_counts(self):
        self.assertEqual(sum(SEGMENTS["8"]), 7)
        self.assertEqual(sum(SEGMENTS["1"]), 2)
        self.assertEqual(sum(SEGMENTS["-"]), 1)

    def test_low_battery_icon(self):
        self.assertTrue(should_show_low_battery(15))
        self.assertFalse(should_show_low_battery(16))
        self.assertFalse(should_show_low_battery(None))


@unittest.skipUnless(HAS_GTK, "需要 GTK (PyGObject)")
class ChartLogicTests(unittest.TestCase):
    def test_step_grows_with_span_and_never_overcrowds(self):
        width = 500.0
        for span in (1800.0, 3600.0 * 6, 86400.0, 86400.0 * 7, 86400.0 * 30):
            step = choose_time_step(span, width)
            self.assertLessEqual(span / step, width / 80.0 + 1e-9)
        self.assertLess(choose_time_step(3600.0, width), choose_time_step(86400.0 * 30, width))

    def test_filter_recent(self):
        points = [HistoryPoint(t, 20.0, 50.0, 3.0, 90) for t in (0.0, 3600.0, 7200.0, 10800.0)]
        self.assertEqual(len(filter_recent(points, None)), 4)
        self.assertEqual([p.timestamp for p in filter_recent(points, 3600.0)], [7200.0, 10800.0])
        self.assertEqual(filter_recent([], 3600.0), [])


if __name__ == "__main__":
    unittest.main()
