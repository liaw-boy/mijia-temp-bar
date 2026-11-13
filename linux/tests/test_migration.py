import json
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from mijia_temp_bar.devices import (
    KIND_BROADCAST,
    KIND_STOCK,
    Device,
    DeviceStore,
    copy_without_overwrite,
    plan_migration,
)

A = "A4:C1:38:8C:9B:32"
B = "A4:C1:38:00:11:22"


class DictStore:
    """測試用的設定替身 (與 settings.Settings 相同的 get/set 介面)。"""

    def __init__(self, data=None):
        self.data = dict(data or {})

    def get(self, key, default=None):
        return self.data.get(key, default)

    def set(self, key, value):
        self.data[key] = value


class CopyWithoutOverwriteTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self._tmp.name)
        self.src = self.dir / "history.json"
        self.src.write_bytes(b"[1, 2, 3]")

    def tearDown(self):
        self._tmp.cleanup()

    def test_copies_and_keeps_source(self):
        dest = self.dir / "history" / "A4C1388C9B32.json"
        self.assertTrue(copy_without_overwrite(self.src, dest))
        self.assertEqual(dest.read_bytes(), b"[1, 2, 3]")
        self.assertEqual(self.src.read_bytes(), b"[1, 2, 3]")

    def test_never_overwrites_existing_destination(self):
        dest = self.dir / "dest.json"
        dest.write_bytes(b"keep me")
        self.assertFalse(copy_without_overwrite(self.src, dest))
        self.assertEqual(dest.read_bytes(), b"keep me")

    def test_missing_source(self):
        self.assertFalse(copy_without_overwrite(self.dir / "nope.json", self.dir / "dest.json"))
        self.assertFalse((self.dir / "dest.json").exists())

    def test_falls_back_when_hard_links_are_unsupported(self):
        dest = self.dir / "dest.json"
        with mock.patch("mijia_temp_bar.devices.os.link", side_effect=PermissionError("no links")):
            self.assertTrue(copy_without_overwrite(self.src, dest))
            self.assertFalse(copy_without_overwrite(self.src, dest))
        self.assertEqual(dest.read_bytes(), b"[1, 2, 3]")

    def test_leaves_no_temp_files(self):
        dest = self.dir / "dest.json"
        copy_without_overwrite(self.src, dest)
        copy_without_overwrite(self.src, dest)
        self.assertEqual(sorted(p.name for p in self.dir.iterdir()), ["dest.json", "history.json"])


class PlanMigrationTests(unittest.TestCase):
    def test_already_migrated(self):
        self.assertIsNone(plan_migration(True, A, True))

    def test_legacy_target_becomes_primary(self):
        plan = plan_migration(False, A.lower(), True)
        self.assertEqual(plan.devices, (Device(A, "溫濕度計 1", KIND_STOCK),))
        self.assertEqual(plan.primary_id, A)
        self.assertEqual(plan.copy_history_to, A)
        self.assertFalse(plan.legacy_unclaimed)

    def test_legacy_target_without_history(self):
        plan = plan_migration(False, A, False)
        self.assertIsNone(plan.copy_history_to)

    def test_broadcast_user_history_is_unclaimed(self):
        plan = plan_migration(False, None, True)
        self.assertEqual(plan.devices, ())
        self.assertTrue(plan.legacy_unclaimed)

    def test_fresh_install(self):
        plan = plan_migration(False, None, False)
        self.assertEqual(plan.devices, ())
        self.assertFalse(plan.legacy_unclaimed)

    def test_invalid_legacy_target_is_ignored(self):
        self.assertEqual(plan_migration(False, 123, False).devices, ())


class DeviceStoreMigrationTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self._tmp.name)
        self.legacy_history = self.dir / "history.json"
        self.history_dir = self.dir / "history"
        self.settings_file = self.dir / "settings.json"

    def tearDown(self):
        self._tmp.cleanup()

    def make_store(self, data):
        self.settings = DictStore(data)
        self.settings_file.write_text(json.dumps(data), encoding="utf-8")
        return DeviceStore(self.settings, self.history_dir, self.legacy_history, self.settings_file)

    def test_migrates_legacy_target_and_history(self):
        self.legacy_history.write_text("[]", encoding="utf-8")
        store = self.make_store({"TargetAddress": A, "LastLowBatteryNotificationTime": 1234.0})
        self.assertTrue(store.migrate())

        self.assertEqual([d.id for d in store.devices], [A])
        self.assertEqual(store.primary_id, A)
        self.assertEqual((self.history_dir / "A4C1388C9B32.json").read_text(encoding="utf-8"), "[]")
        self.assertEqual(self.settings.data["TargetAddress"], A)  # 舊鍵保留
        self.assertEqual(self.settings.data["LowBatteryAlertTimes"], {A: 1234.0})
        self.assertTrue((self.dir / "settings.pre-multidevice.json").exists())
        self.assertEqual(self.legacy_history.read_text(encoding="utf-8"), "[]")

    def test_second_run_does_nothing(self):
        store = self.make_store({"TargetAddress": A})
        self.assertTrue(store.migrate())
        store.remove(A)
        self.assertFalse(store.migrate())
        self.assertEqual(store.devices, ())  # 移除後不會從舊鍵復活

    def test_existing_destination_is_kept(self):
        self.legacy_history.write_text("[1]", encoding="utf-8")
        self.history_dir.mkdir()
        (self.history_dir / "A4C1388C9B32.json").write_text("[2]", encoding="utf-8")
        store = self.make_store({"TargetAddress": A})
        self.assertTrue(store.migrate())
        self.assertEqual((self.history_dir / "A4C1388C9B32.json").read_text(encoding="utf-8"), "[2]")

    def test_unclaimed_history_goes_to_first_added_device(self):
        self.legacy_history.write_text("[9]", encoding="utf-8")
        store = self.make_store({})
        store.migrate()
        self.assertTrue(self.settings.data["LegacyHistoryUnclaimed"])

        store.add([Device(B, "臥室", KIND_BROADCAST)])
        self.assertEqual((self.history_dir / "A4C138001122.json").read_text(encoding="utf-8"), "[9]")
        self.assertFalse(self.settings.data["LegacyHistoryUnclaimed"])
        self.assertEqual(store.primary_id, B)


class DeviceStoreOperationTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        dir_ = Path(self._tmp.name)
        self.settings = DictStore({"Devices": [], "PrimaryDeviceID": None})
        self.store = DeviceStore(self.settings, dir_ / "history", dir_ / "history.json", dir_ / "settings.json")

    def tearDown(self):
        self._tmp.cleanup()

    def test_add_sets_first_as_primary_and_persists(self):
        self.store.add([Device(A, "客廳", KIND_STOCK), Device(B, "臥室", KIND_BROADCAST)])
        self.assertEqual(self.store.primary_id, A)
        self.assertEqual(self.settings.data["PrimaryDeviceID"], A)
        self.assertEqual([d["id"] for d in self.settings.data["Devices"]], [A, B])

    def test_set_primary_and_remove_primary(self):
        self.store.add([Device(A, "客廳", KIND_STOCK), Device(B, "臥室", KIND_BROADCAST)])
        self.store.set_primary(B)
        self.assertEqual(self.store.primary_id, B)
        self.store.remove(B)
        self.assertEqual(self.store.primary_id, A)

    def test_set_primary_ignores_unknown(self):
        self.store.add([Device(A, "客廳", KIND_STOCK)])
        self.store.set_primary("missing")
        self.assertEqual(self.store.primary_id, A)

    def test_rename(self):
        self.store.add([Device(A, "客廳", KIND_STOCK)])
        self.store.rename(A, "書房")
        self.assertEqual(self.store.get(A).name, "書房")
        self.assertEqual(self.settings.data["Devices"][0]["name"], "書房")

    def test_ordered_ids_put_primary_first(self):
        self.store.add([Device(A, "客廳", KIND_STOCK), Device(B, "臥室", KIND_STOCK)])
        self.store.set_primary(B)
        self.assertEqual(self.store.ordered_ids(), [B, A])


if __name__ == "__main__":
    unittest.main()
