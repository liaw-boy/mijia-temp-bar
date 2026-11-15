import csv
import tempfile
import unittest
from datetime import datetime
from pathlib import Path

from mijia_temp_bar.history import HistoryManager


class HistoryManagerTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self._tmp.name)
        self.path = self.dir / "history.json"

    def tearDown(self):
        self._tmp.cleanup()

    def test_persist_and_reload(self):
        history = HistoryManager(self.path)
        history.add_point(23.31, 32.0, 2.876, 86, timestamp=1_000.0)
        history.add_point(24.10, 35.0, 2.880, 86, timestamp=1_300.0)

        reloaded = HistoryManager(self.path)
        self.assertEqual(reloaded.points, history.points)
        self.assertEqual(reloaded.min_temperature, 23.31)
        self.assertEqual(reloaded.max_temperature, 24.10)
        self.assertEqual(reloaded.min_humidity, 32.0)
        self.assertEqual(reloaded.max_humidity, 35.0)

    def test_trims_to_max_points(self):
        history = HistoryManager(self.path)
        history.MAX_POINTS = 3
        for i in range(5):
            history.add_point(20.0 + i, 50.0, 3.0, 100, timestamp=float(i))
        self.assertEqual([p.temperature for p in history.points], [22.0, 23.0, 24.0])

    def test_empty_and_corrupted_file(self):
        history = HistoryManager(self.path)
        self.assertEqual(history.points, [])
        self.assertIsNone(history.min_temperature)

        self.path.write_text("{not json", encoding="utf-8")
        self.assertEqual(HistoryManager(self.path).points, [])

    def test_export_csv(self):
        history = HistoryManager(self.path)
        ts = datetime(2026, 1, 2, 3, 4, 5).timestamp()
        history.add_point(23.314, 32.04, 2.8764, 86, timestamp=ts)

        out = self.dir / "export.csv"
        history.export_csv(out)
        with open(out, encoding="utf-8", newline="") as f:
            rows = list(csv.reader(f))
        self.assertEqual(rows[0], ["時間", "溫度 (°C)", "濕度 (%)", "電壓 (V)", "電量百分比 (%)"])
        self.assertEqual(rows[1], ["2026-01-02 03:04:05", "23.31", "32.0", "2.876", "86"])


class PerDeviceHistoryTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.base = Path(self._tmp.name) / "history"

    def tearDown(self):
        self._tmp.cleanup()

    def test_each_device_has_its_own_file(self):
        a = HistoryManager.for_device("A4:C1:38:8C:9B:32", self.base)
        b = HistoryManager.for_device("A4:C1:38:00:11:22", self.base)
        a.add_point(20.0, 50.0, 3.0, 100, timestamp=1.0)
        self.assertEqual(a.storage_path, self.base / "A4C1388C9B32.json")
        self.assertEqual(b.points, [])
        self.assertTrue((self.base / "A4C1388C9B32.json").exists())
        self.assertFalse((self.base / "A4C138001122.json").exists())

    def test_for_device_reuses_instance(self):
        first = HistoryManager.for_device("A4:C1:38:8C:9B:32", self.base)
        self.assertIs(first, HistoryManager.for_device("A4:C1:38:8C:9B:32", self.base))

    def test_last_point(self):
        history = HistoryManager.for_device("A4:C1:38:8C:9B:32", self.base)
        self.assertIsNone(history.last_point)
        history.add_point(20.0, 50.0, 3.0, 100, timestamp=5.0)
        self.assertEqual(history.last_point.timestamp, 5.0)

    def test_corrupted_file_is_set_aside_before_overwrite(self):
        self.base.mkdir(parents=True)
        path = self.base / "A4C1388C9B32.json"
        path.write_text("{broken", encoding="utf-8")
        history = HistoryManager(path)
        self.assertEqual(history.points, [])
        backups = list(self.base.glob("A4C1388C9B32.corrupt-*.json"))
        self.assertEqual(len(backups), 1)
        self.assertEqual(backups[0].read_text(encoding="utf-8"), "{broken")

    def test_non_utf8_file_is_set_aside_not_crash(self):
        self.base.mkdir(parents=True)
        path = self.base / "A4C1388C9B32.json"
        path.write_bytes(b"\xff\xfe\x00bad")
        history = HistoryManager(path)
        self.assertEqual(history.points, [])
        self.assertEqual(len(list(self.base.glob("A4C1388C9B32.corrupt-*.json"))), 1)

    def test_unreadable_file_is_never_overwritten(self):
        path = self.base / "A4C1388C9B32.json"
        path.mkdir(parents=True)  # 目錄當檔案讀 → IsADirectoryError (OSError，但不是檔案不存在)
        history = HistoryManager(path)
        history.add_point(20.0, 50.0, 3.0, 100, timestamp=1.0)
        self.assertTrue(path.is_dir())


if __name__ == "__main__":
    unittest.main()
