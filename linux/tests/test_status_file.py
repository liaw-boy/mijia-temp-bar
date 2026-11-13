import unittest
from datetime import datetime

from mijia_temp_bar.device_state import (
    DeviceState,
    display_device_id,
    should_hide_icon,
    summary_text,
    tray_values,
    with_reading,
    with_status,
)
from mijia_temp_bar.devices import KIND_BROADCAST, KIND_STOCK, Device
from mijia_temp_bar.parsers import SensorReading
from mijia_temp_bar.status_file import build_status_payload

A, B = "A4:C1:38:8C:9B:32", "AA:BB:CC:DD:EE:FF"
WHEN = datetime(2026, 11, 14, 9, 30, 0)


def reading(temp=24.5, hum=68.0):
    return SensorReading(temp, hum, 76, 2.789, None, "客廳", WHEN, "原廠直連 (即連即斷省電模式)")


class DeviceStateTests(unittest.TestCase):
    def test_reading_marks_reachable(self):
        state = with_reading(DeviceState(), reading())
        self.assertTrue(state.reachable)
        self.assertFalse(state.cached)

    def test_status_keeps_reachability_when_unspecified(self):
        state = with_status(with_reading(DeviceState(), reading()), "讀取感測數據中...", None)
        self.assertTrue(state.reachable)
        self.assertEqual(state.status, "讀取感測數據中...")
        self.assertIsNotNone(state.reading)

    def test_unreachable_keeps_last_reading(self):
        state = with_status(with_reading(DeviceState(), reading()), "設備未在連線範圍內", False)
        self.assertFalse(state.reachable)
        self.assertEqual(state.reading.temperature, 24.5)


class VisibilityTests(unittest.TestCase):
    def test_hide_only_when_all_unreachable(self):
        down = DeviceState(reachable=False)
        up = DeviceState(reachable=True)
        unknown = DeviceState(reachable=None)
        self.assertTrue(should_hide_icon(True, [A, B], {A: down, B: down}))
        self.assertFalse(should_hide_icon(True, [A, B], {A: down, B: up}))
        self.assertFalse(should_hide_icon(True, [A, B], {A: down, B: unknown}))
        self.assertFalse(should_hide_icon(True, [A, B], {A: down}))

    def test_never_hide_when_disabled_or_empty(self):
        self.assertFalse(should_hide_icon(False, [A], {A: DeviceState(reachable=False)}))
        self.assertFalse(should_hide_icon(True, [], {}))


class TrayValueTests(unittest.TestCase):
    def test_reachable_primary_shows_numbers(self):
        self.assertEqual(tray_values(with_reading(DeviceState(), reading())), (24.5, 68.0))

    def test_cached_reading_at_startup_is_shown(self):
        self.assertEqual(tray_values(DeviceState(reading=reading(), cached=True)), (24.5, 68.0))

    def test_unreachable_primary_shows_dashes(self):
        state = with_status(with_reading(DeviceState(), reading()), "設備未在連線範圍內", False)
        self.assertEqual(tray_values(state), (None, None))
        self.assertEqual(tray_values(None), (None, None))


class DisplayDeviceTests(unittest.TestCase):
    """帶筆電換地方：主裝置不在附近時改顯示附近那台，不改使用者選的主裝置。"""

    def setUp(self):
        self.C = "A4:C1:38:33:44:55"

    def state(self, reachable, minute=0):
        r = reading()
        r = SensorReading(r.temperature, r.humidity, r.battery_percent, r.voltage, None, "x",
                          datetime(2026, 11, 14, 9, minute), r.mode)
        return DeviceState(reading=r, reachable=reachable)

    def test_primary_nearby(self):
        states = {A: self.state(True), B: self.state(True, 5)}
        self.assertEqual(display_device_id(A, [A, B], states), A)

    def test_primary_away_shows_nearby_device(self):
        states = {A: self.state(False), B: self.state(True)}
        self.assertEqual(display_device_id(A, [A, B], states), B)

    def test_picks_most_recent_nearby_device(self):
        states = {A: self.state(False), B: self.state(True, 1), self.C: self.state(True, 9)}
        self.assertEqual(display_device_id(A, [A, B, self.C], states), self.C)

    def test_all_away_keeps_primary(self):
        states = {A: self.state(False), B: self.state(False)}
        self.assertEqual(display_device_id(A, [A, B], states), A)

    def test_unknown_primary_keeps_primary(self):
        states = {A: DeviceState(reading=reading(), reachable=None, cached=True), B: self.state(True)}
        self.assertEqual(display_device_id(A, [A, B], states), A)

    def test_nearby_device_without_reading_is_skipped(self):
        states = {A: self.state(False), B: DeviceState(reachable=True)}
        self.assertEqual(display_device_id(A, [A, B], states), A)

    def test_no_primary(self):
        self.assertIsNone(display_device_id(None, [], {}))


class SummaryTextTests(unittest.TestCase):
    def test_formats(self):
        self.assertEqual(summary_text("客廳", with_reading(DeviceState(), reading())), "客廳 · 24.5° · 68%")
        down = with_status(DeviceState(reading=reading()), "設備未在連線範圍內", False)
        self.assertEqual(summary_text("客廳", down), "客廳 · -- (設備未在連線範圍內)")
        self.assertEqual(summary_text("臥室", DeviceState()), "臥室 · 等待讀取")


class StatusPayloadTests(unittest.TestCase):
    def test_keeps_legacy_top_level_keys_for_primary(self):
        devices = (Device(A, "客廳", KIND_STOCK), Device(B, "臥室", KIND_BROADCAST))
        states = {A: with_reading(DeviceState(), reading()), B: DeviceState(reachable=False, status="未收到廣播")}
        payload = build_status_payload(devices, states, A, 300.0, "2026-11-14T09:30:00+08:00")

        self.assertEqual(payload["status"], "正常運作中")
        self.assertEqual(payload["temperature"], 24.5)
        self.assertEqual(payload["deviceName"], "客廳")
        self.assertEqual(payload["refreshIntervalSeconds"], 300)
        self.assertEqual(payload["primaryDeviceId"], A)
        self.assertEqual([d["id"] for d in payload["devices"]], [A, B])
        self.assertTrue(payload["devices"][0]["primary"])
        self.assertEqual(payload["devices"][0]["lastUpdated"], "2026-11-14T09:30:00")
        self.assertEqual(payload["devices"][1], {
            "id": B, "name": "臥室", "kind": KIND_BROADCAST, "primary": False,
            "reachable": False, "status": "未收到廣播",
        })

    def test_top_level_follows_displayed_device(self):
        """主裝置不在附近、狀態列改顯示附近那台時，頂層欄位也跟著是那台，外部程式不會讀到舊數字。"""
        devices = (Device(A, "客廳", KIND_STOCK), Device(B, "臥室", KIND_STOCK))
        states = {
            A: with_status(DeviceState(reading=reading(20.0, 50.0)), "設備未在連線範圍內", False),
            B: with_reading(DeviceState(), reading(26.0, 70.0)),
        }
        payload = build_status_payload(devices, states, A, 300.0, "t", displayed_id=B)

        self.assertEqual(payload["temperature"], 26.0)
        self.assertEqual(payload["deviceName"], "臥室")
        self.assertEqual(payload["status"], "正常運作中")
        self.assertEqual(payload["primaryDeviceId"], A)
        self.assertEqual(payload["displayedDeviceId"], B)
        self.assertTrue(payload["devices"][0]["primary"])

    def test_displayed_defaults_to_primary(self):
        devices = (Device(A, "客廳", KIND_STOCK),)
        payload = build_status_payload(devices, {A: with_reading(DeviceState(), reading())}, A, 300.0, "t")
        self.assertEqual(payload["displayedDeviceId"], A)
        self.assertEqual(payload["deviceName"], "客廳")

    def test_adapter_status_overrides(self):
        payload = build_status_payload((), {}, None, 300.0, "t", adapter_status="電腦藍牙已關閉")
        self.assertEqual(payload["status"], "電腦藍牙已關閉")
        self.assertNotIn("temperature", payload)
        self.assertEqual(payload["devices"], [])

    def test_no_devices(self):
        self.assertEqual(build_status_payload((), {}, None, 300.0, "t")["status"], "尚未加入裝置")


if __name__ == "__main__":
    unittest.main()
