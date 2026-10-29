import unittest

from mijia_temp_bar.backoff import retry_delay
from mijia_temp_bar.notifications import (
    COOLDOWN_SECONDS,
    HUMIDITY_REPEAT_SECONDS,
    HumidityMonitor,
    is_low,
    should_alert,
    valid_thresholds,
)


class RetryDelayTests(unittest.TestCase):
    def test_backoff_steps(self):
        self.assertEqual(retry_delay(1, 300.0), 60.0)
        self.assertEqual(retry_delay(2, 30.0), 30.0)
        self.assertEqual(retry_delay(3, 300.0), 300.0)
        self.assertEqual(retry_delay(5, 300.0), 900.0)

    def test_never_shorter_than_user_interval(self):
        self.assertEqual(retry_delay(6, 3600.0), 3600.0)


class LowBatteryTests(unittest.TestCase):
    def test_is_low(self):
        self.assertTrue(is_low(15, 2.9))
        self.assertTrue(is_low(50, 2.6))
        self.assertFalse(is_low(16, 2.7))

    def test_cooldown(self):
        self.assertTrue(should_alert(10, 2.5, None, 1000.0))
        self.assertFalse(should_alert(10, 2.5, 1000.0, 1000.0 + COOLDOWN_SECONDS - 1))
        self.assertTrue(should_alert(10, 2.5, 1000.0, 1000.0 + COOLDOWN_SECONDS))

    def test_no_alert_when_battery_ok(self):
        self.assertFalse(should_alert(80, 3.0, None, 1000.0))


class HumidityMonitorTests(unittest.TestCase):
    def test_alerts_once_per_excursion(self):
        m = HumidityMonitor()
        self.assertIsNone(m.check(55, 70, 30, 0))
        self.assertEqual(m.check(75, 70, 30, 10), "high")
        self.assertIsNone(m.check(76, 70, 30, 20))

    def test_repeats_after_interval(self):
        m = HumidityMonitor()
        self.assertEqual(m.check(75, 70, 30, 0), "high")
        self.assertIsNone(m.check(75, 70, 30, HUMIDITY_REPEAT_SECONDS - 1))
        self.assertEqual(m.check(75, 70, 30, HUMIDITY_REPEAT_SECONDS), "high")

    def test_low_and_switching_direction(self):
        m = HumidityMonitor()
        self.assertEqual(m.check(25, 70, 30, 0), "low")
        self.assertEqual(m.check(75, 70, 30, 1), "high")

    def test_hysteresis_rearms_only_after_buffer(self):
        m = HumidityMonitor()
        self.assertEqual(m.check(75, 70, 30, 0), "high")
        self.assertIsNone(m.check(69, 70, 30, 1))   # 在緩衝區內，尚未重新武裝
        self.assertIsNone(m.check(75, 70, 30, 2))   # 不重複通知
        self.assertIsNone(m.check(60, 70, 30, 3))   # 回到安全範圍，重新武裝
        self.assertEqual(m.check(75, 70, 30, 4), "high")

    def test_valid_thresholds(self):
        self.assertTrue(valid_thresholds(70, 30))
        self.assertFalse(valid_thresholds(30, 70))
        self.assertFalse(valid_thresholds(70, 70))
        self.assertFalse(valid_thresholds(101, 30))
        self.assertFalse(valid_thresholds(70, -1))


if __name__ == "__main__":
    unittest.main()
