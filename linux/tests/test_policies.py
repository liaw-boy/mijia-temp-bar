import unittest

from mijia_temp_bar.backoff import retry_delay
from mijia_temp_bar.notifications import COOLDOWN_SECONDS, is_low, should_alert


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


if __name__ == "__main__":
    unittest.main()
