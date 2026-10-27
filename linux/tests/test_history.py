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


if __name__ == "__main__":
    unittest.main()
