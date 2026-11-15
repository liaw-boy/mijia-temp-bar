import unittest

from mijia_temp_bar import device_history as dh
from mijia_temp_bar.history import HistoryPoint


class ParseTests(unittest.TestCase):
    def test_record(self):
        # idx=5, ts=7200, 最高 25.3°C/60%, 最低 -1.5°C/40%
        rec = dh.parse_record(bytes.fromhex("05000000201C0000FD003CF1FF28"))
        self.assertEqual(rec, dh.HourlyRecord(5, 7200, 25.3, 60.0, -1.5, 40.0))

    def test_invalid_record(self):
        self.assertIsNone(dh.parse_record(bytes.fromhex("05000000201C0000FD003C")))
        self.assertIsNone(dh.parse_record(bytes.fromhex("05000000201C0000FD00FFF1FF28")))  # 濕度 255

    def test_time_and_count(self):
        self.assertEqual(dh.parse_device_time(bytes.fromhex("10270000")), 10000)
        self.assertEqual(dh.parse_count(bytes.fromhex("0A00000005000000")), (10, 5))
        self.assertIsNone(dh.parse_count(b"\x01"))


class PlanTests(unittest.TestCase):
    NOW = 10_000_000.0

    def steady(self, seconds):
        return [self.NOW - t for t in range(int(seconds), -1, -300)]

    def test_gap_start(self):
        two_days = self.steady(2 * 86400)
        self.assertEqual(dh.gap_start(two_days, self.NOW), self.NOW - 30 * 86400)  # 最前面沒資料
        recent = [t for t in two_days if self.NOW - t < 86400]
        covered = self.NOW - 86400 - 60
        self.assertIsNone(dh.gap_start(recent, self.NOW, covered))
        holed = [t for t in recent if not (self.NOW - 10 * 3600 <= t <= self.NOW - 7 * 3600)]
        hole_start = max(t for t in holed if t < self.NOW - 10 * 3600)
        self.assertEqual(dh.gap_start(holed, self.NOW, covered), hole_start)  # 中間的舊空白
        self.assertIsNone(dh.gap_start(holed, self.NOW, self.NOW - 6 * 3600))  # 已完整讀過的時段
        newer = [t for t in holed if t <= self.NOW - 2 * 3600]
        self.assertIsNotNone(dh.gap_start(newer, self.NOW, self.NOW - 6 * 3600))  # 之後的新空白

    def test_long_interval_is_not_a_gap(self):
        self.assertIsNone(dh.gap_start([self.NOW - 3 * 3600], self.NOW, self.NOW - 3 * 3600 - 60, interval=3 * 3600))

    def test_record_index_even_when_values_invalid(self):
        raw = bytes.fromhex("05000000201C0000FD00FFF1FF28")
        self.assertIsNone(dh.parse_record(raw))
        self.assertEqual(dh.record_index(raw), 5)

    def test_start_index(self):
        self.assertEqual(dh.start_index(100, 50, self.NOW - 3 * 3600 - 60, self.NOW), 95)
        self.assertEqual(dh.start_index(100, 3, self.NOW - 10 * 3600, self.NOW), 97)
        self.assertEqual(dh.start_index(1000, 1000, self.NOW - 60 * 86400, self.NOW), 0)  # 從最舊的開始
        self.assertEqual(dh.chunk_end(0, 1000), 719)
        self.assertEqual(dh.chunk_end(900, 1000), 999)

    def test_gap_range_follows_retention(self):
        self.assertEqual(dh.gap_start([], self.NOW, retention=90), self.NOW - 90 * 86400)
        hourly_old = [self.NOW - t for t in range(60 * 86400, 31 * 86400 - 1, -3600)]
        steady = [self.NOW - t for t in range(31 * 86400 - 300, -1, -300)]
        self.assertIsNone(dh.gap_start(hourly_old + steady, self.NOW, self.NOW - 60 * 86400 - 60, retention=90))

    def test_retention_days(self):
        self.assertEqual(dh.retention_days(90), 90)
        self.assertEqual(dh.retention_days(7), 30)
        self.assertEqual(dh.retention_days(None), 30)
        self.assertIsNone(dh.start_index(0, 0, self.NOW, self.NOW))


class CompactTests(unittest.TestCase):
    def test_compact(self):
        base = 3600 * 3000.0
        now = base + 200 * 86400

        def pt(ago, t):
            return HistoryPoint(now - ago, t, 50.0, 3.0, 90)
        raw = [pt(100 * 86400, 1), pt(40 * 86400 - 600, 20), pt(40 * 86400 - 1200, 22), pt(86400, 25), pt(86400 - 300, 26)]
        out = dh.compact(raw, now, 90)
        self.assertEqual(len(out), 3)  # 過期刪除、同一小時合併
        self.assertEqual(out[0], HistoryPoint(now - 40 * 86400 + 1800, 21.0, 50.0, 3.0, 90))
        self.assertEqual(out[1:], [pt(86400, 25), pt(86400 - 300, 26)])  # 最近 30 天完整保留
        self.assertEqual(dh.compact(out, now, 90), out)  # 重複壓縮結果不變


class FillTests(unittest.TestCase):
    NOW = 1_000_000.0

    def test_fills_only_gaps_at_hour_middle(self):
        existing = [HistoryPoint(self.NOW - 5100, 20.0, 50.0, 3.0, 90)]
        records = [
            dh.HourlyRecord(1, 30000 - 6 * 3600, 22.0, 60.0, 20.0, 50.0),
            dh.HourlyRecord(2, 30000 - 2 * 3600, 30.0, 70.0, 28.0, 60.0),  # 該時段已有讀數
            dh.HourlyRecord(3, 40000, 30.0, 70.0, 28.0, 60.0),             # 未來時間
        ]
        merged = dh.fill(existing, records, 30000, self.NOW, 2.9, 80)
        self.assertEqual(len(merged), 2)
        self.assertEqual(merged[0], HistoryPoint(self.NOW - 6 * 3600 + 1800, 21.0, 55.0, 2.9, 80))
        self.assertEqual(merged[1], existing[0])

    def test_no_records(self):
        existing = [HistoryPoint(self.NOW, 20.0, 50.0, 3.0, 90)]
        self.assertEqual(dh.fill(existing, [], 0, self.NOW, 3.0, 90), existing)


if __name__ == "__main__":
    unittest.main()
