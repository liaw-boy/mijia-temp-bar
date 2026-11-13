"""系統匣圖示 (AppIndicator)、多裝置狀態與選單 (儀表板與設定在彈出視窗內)。

狀態列只顯示「主裝置」；每台裝置的讀數、狀態、歷史與通知各自獨立。
"""

import time
from dataclasses import replace
from datetime import datetime
from typing import Dict, List, Optional, Tuple

import gi

gi.require_version("Gtk", "3.0")
from gi.repository import GLib, Gtk  # noqa: E402

try:
    gi.require_version("AyatanaAppIndicator3", "0.1")
    from gi.repository import AyatanaAppIndicator3 as AppIndicator  # noqa: E402
except (ValueError, ImportError):
    gi.require_version("AppIndicator3", "0.1")
    from gi.repository import AppIndicator3 as AppIndicator  # noqa: E402

from . import device_dialogs, notifications, update_check  # noqa: E402
from .bluetooth import DISCOVERY_SECONDS, BluetoothManager  # noqa: E402
from .device_menu import DeviceMenu  # noqa: E402
from .device_state import (  # noqa: E402
    DeviceState,
    display_device_id,
    should_hide_icon,
    tray_values,
    with_reading,
    with_status,
)
from .devices import KIND_STOCK, Device, DeviceStore, default_name  # noqa: E402
from .discovery import Candidate  # noqa: E402
from .history import HISTORY_DIR, LEGACY_HISTORY_PATH, HistoryManager  # noqa: E402
from .icons import TrayIconWriter, format_hum, format_temp, render_stacked, render_stats_badge, render_text  # noqa: E402
from .logger import mijia_log  # noqa: E402
from .options import DisplayStyle  # noqa: E402
from .parsers import MODE_STOCK, SensorReading  # noqa: E402
from .presence import ReprobeTriggers  # noqa: E402
from .settings import CONFIG_DIR, RUNTIME_DIR, settings  # noqa: E402
from .status_file import build_status_payload, write_status_json  # noqa: E402

DISCOVERY_PROMPTED_KEY = "DiscoveryPromptShown"
STATUS_WRITE_SECONDS = 5.0      # 狀態 JSON 最多每 5 秒寫一次
TEMP_SHOW_SECONDS = 10          # 從應用程式選單再開一次時，暫時顯示圖示的秒數
CACHED_STATUS = "使用上次紀錄"


def dispatch_to_main(fn, *args) -> None:
    def run():
        fn(*args)
        return GLib.SOURCE_REMOVE
    GLib.idle_add(run)


class StatusBarController:
    def __init__(self, app: Gtk.Application):
        self.app = app
        self.dashboard = None
        self.update_result = None
        self.adapter_status: Optional[str] = None
        self.adapter_hint: Optional[str] = None
        self._force_visible_source: Optional[int] = None
        self._status_write_source: Optional[int] = None
        self._last_status_write = 0.0
        self._discovery_dialog: Optional[device_dialogs.DiscoveryDialog] = None
        self._last_tray_key: Optional[tuple] = None
        self._menu: Optional[Gtk.Menu] = None
        self._load_preferences()

        self.device_store = DeviceStore(settings, HISTORY_DIR, LEGACY_HISTORY_PATH, CONFIG_DIR / "settings.json")
        try:
            self.device_store.migrate()
        except OSError as e:
            mijia_log(f"遷移失敗，下次啟動會再試: {e}")
        # 啟動時先用每台最後一筆歷史當快取 (避免圖示閃爍或意外消失)
        self.states: Dict[str, DeviceState] = {d.id: self._cached_state(d) for d in self.devices}

        self.bluetooth_manager = BluetoothManager(dispatch=dispatch_to_main)
        self.bluetooth_manager.delegate = self

        self._icons = TrayIconWriter(RUNTIME_DIR / "icons")
        self._setup_indicator()
        self.device_menu = DeviceMenu(self)
        self.rebuild_menu()
        self._refresh_tray()

        self.bluetooth_manager.start(self.devices, self.device_store.ordered_ids())
        # 帶筆電換地方：喚醒或換到另一個網路時立刻重新偵測，狀態列才能改顯示附近那台
        self._reprobe = ReprobeTriggers(self.bluetooth_manager.reprobe_all)
        GLib.timeout_add_seconds(8, self._auto_check_update)
        if not self.devices and settings.get(DISCOVERY_PROMPTED_KEY) is not True:
            GLib.timeout_add_seconds(2, self._first_run_discovery)

    def _load_preferences(self) -> None:
        hide = settings.get("HideWhenDisconnected")
        if isinstance(hide, bool):
            self.hide_when_disconnected = hide
        else:
            self.hide_when_disconnected = True
            settings.set("HideWhenDisconnected", True)
        try:
            self.display_style = DisplayStyle(settings.get("DisplayStyle"))
        except ValueError:
            self.display_style = DisplayStyle.STATS_BADGE
            settings.set("DisplayStyle", int(DisplayStyle.STATS_BADGE))

    def _cached_state(self, device: Device) -> DeviceState:
        last = HistoryManager.for_device(device.id).last_point
        if last is None:
            return DeviceState()
        reading = SensorReading(
            temperature=last.temperature,
            humidity=last.humidity,
            battery_percent=last.batteryPercent,
            voltage=last.voltage,
            rssi=None,
            device_name=device.name,
            last_updated=datetime.fromtimestamp(last.timestamp),
            mode=MODE_STOCK if device.kind == KIND_STOCK else "開源廣播",
            is_broadcast=device.kind != KIND_STOCK,
        )
        return DeviceState(reading=reading, reachable=None, status=CACHED_STATUS, cached=True)

    def _auto_check_update(self) -> bool:
        if update_check.due_for_auto_check(time.time()):
            update_check.check_async(self._on_update_result, dispatch_to_main)
        return GLib.SOURCE_REMOVE

    def _on_update_result(self, result) -> None:
        self.update_result = result
        if self.dashboard is not None:
            self.dashboard.show_update_result(result)

    def shutdown(self) -> None:
        mijia_log("MijiaTempBar 正在退出...")
        self.bluetooth_manager.shutdown()

    # MARK: - 裝置查詢 (給選單與儀表板使用)

    @property
    def devices(self) -> Tuple[Device, ...]:
        return self.device_store.devices

    @property
    def primary_id(self) -> Optional[str]:
        return self.device_store.primary_id

    def state_for(self, device_id: Optional[str]) -> DeviceState:
        return self.states.get(device_id, DeviceState()) if device_id else DeviceState()

    @property
    def displayed_id(self) -> Optional[str]:
        """狀態列實際顯示的裝置：主裝置不在附近時改為附近那台。"""
        return display_device_id(self.primary_id, self.device_store.ordered_ids(), self.states)

    # MARK: - 系統匣圖示

    def _setup_indicator(self) -> None:
        self.indicator = AppIndicator.Indicator.new(
            "mijia-temp-bar",
            self._icons.write(render_text("🌡️ 搜尋中...")),
            AppIndicator.IndicatorCategory.HARDWARE,
        )
        self.indicator.set_title("米家藍牙溫濕度計")
        self.indicator.set_status(AppIndicator.IndicatorStatus.ACTIVE)

    def _set_visible(self, visible: bool) -> None:
        self.indicator.set_status(
            AppIndicator.IndicatorStatus.ACTIVE if visible else AppIndicator.IndicatorStatus.PASSIVE
        )

    def _set_tray_image(self, key: tuple, render, description: str) -> None:
        """key 與上次相同就不重畫 (每台裝置的事件都會觸發更新，但多半與主裝置無關)。"""
        if key == self._last_tray_key:
            return
        self._last_tray_key = key
        self.indicator.set_icon_full(self._icons.write(render()), description)

    def _refresh_tray(self) -> None:
        self._update_title()
        self._update_visibility()
        self.device_menu.update_labels()

    def _update_title(self) -> None:
        primary = self.device_store.get(self.displayed_id)
        if primary is None:
            text = "🌡️ 尚未加入裝置"
            self._set_tray_image(("text", text), lambda: render_text(text), "尚未加入裝置，請從選單搜尋新裝置")
            return
        state = self.state_for(primary.id)
        if state.reading is None and state.reachable is not False:
            text = f"🌡️ {self.adapter_status or state.status}"
            self._set_tray_image(("text", text), lambda: render_text(text), f"{primary.name}: {text}")
            return

        # 主裝置連不到時 tray_values 回傳 None，圖示顯示 --
        t, h = tray_values(state)
        key = ("values", self.display_style, format_temp(t), format_hum(h), primary.id, self.primary_id, state.status)
        self._set_tray_image(key, lambda: self._render_values(t, h), self._tooltip(primary, state, t, h))

    def _render_values(self, t: Optional[float], h: Optional[float]):
        ts, hs = format_temp(t), format_hum(h)
        if self.display_style == DisplayStyle.STATS_BADGE:
            return render_stats_badge(t, h)
        if self.display_style == DisplayStyle.STACKED:
            return render_stacked(t, h)
        if self.display_style == DisplayStyle.HORIZONTAL:
            return render_text(f"🌡️ {ts}°C  💧 {hs}%")
        if self.display_style == DisplayStyle.TEMP_ONLY:
            return render_text(f"🌡️ {ts}°C")
        return render_text(f"{ts}° {hs}%")

    def _tooltip(self, device: Device, state: DeviceState, t: Optional[float], h: Optional[float]) -> str:
        battery = f"{state.reading.battery_percent}%" if state.reading else "--"
        main = self.device_store.get(self.primary_id)
        note = f" (主裝置 {main.name} 不在附近)" if main is not None and main.id != device.id else ""
        return (
            f"{device.name}{note}\n溫度: {format_temp(t)}°C\n濕度: {format_hum(h)}%\n電量: {battery}\n"
            f"更新間隔: {int(self.bluetooth_manager.refresh_interval)}秒\n狀態: {state.status}"
        )

    def _update_visibility(self) -> None:
        if self._force_visible_source is not None:
            self._set_visible(True)
            return
        ids = [d.id for d in self.devices]
        self._set_visible(not should_hide_icon(self.hide_when_disconnected, ids, self.states))

    def temporarily_show_status_item(self) -> None:
        if self._force_visible_source is not None:
            GLib.source_remove(self._force_visible_source)
        self._force_visible_source = GLib.timeout_add_seconds(TEMP_SHOW_SECONDS, self._end_force_visible)
        self._set_visible(True)

    def _end_force_visible(self) -> bool:
        self._force_visible_source = None
        self._update_visibility()
        return GLib.SOURCE_REMOVE

    def handle_reopen(self) -> None:
        """使用者再次從應用程式選單啟動時：暫時喚起狀態列顯示並打開儀表板。"""
        self.temporarily_show_status_item()
        self.show_dashboard()

    # MARK: - 選單

    def rebuild_menu(self) -> None:
        old_menu = self._menu
        self._menu, open_dashboard_item = self.device_menu.build()
        self.indicator.set_menu(self._menu)
        # 滑鼠中鍵點擊圖示直接開啟儀表板
        self.indicator.set_secondary_activate_target(open_dashboard_item)
        if old_menu is not None:
            old_menu.destroy()

    # MARK: - 供儀表板設定分頁呼叫

    def set_display_style(self, style: DisplayStyle) -> None:
        self.display_style = style
        settings.set("DisplayStyle", int(style))
        self._update_title()

    def set_hide_when_disconnected(self, hide: bool) -> None:
        self.hide_when_disconnected = hide
        settings.set("HideWhenDisconnected", hide)
        self._update_visibility()

    def show_dashboard(self) -> None:
        if self.dashboard is None:
            from .dashboard import DashboardWindow
            self.dashboard = DashboardWindow(self)
        if self.update_result is not None:
            self.dashboard.show_update_result(self.update_result)
        self.dashboard.show_near_pointer()

    def refresh_now(self, device_id: Optional[str] = None) -> None:
        """立即更新原廠裝置 (None 為全部)；開源廣播裝置本來就持續更新。"""
        targets = [d for d in self.devices if d.kind == KIND_STOCK and device_id in (None, d.id)]
        if not targets:
            return
        self.temporarily_show_status_item()
        for device in targets:
            self._set_device_status(device.id, "正在連線重新整理...", None)
        self.bluetooth_manager.manual_refresh(device_id)

    # MARK: - 裝置管理

    def set_primary(self, device_id: str) -> None:
        device = self.device_store.get(device_id)
        if device is None or device_id == self.primary_id:
            return
        self.device_store.set_primary(device_id)
        mijia_log(f"狀態列主裝置改為 {device.name} [{device_id}]")
        self._devices_changed()

    def rename_device(self, device_id: str, parent: Optional[Gtk.Window] = None) -> None:
        device = self.device_store.get(device_id)
        if device is None:
            return
        name = device_dialogs.ask_rename(parent, device.name)
        if name is None:
            return
        try:
            self.device_store.rename(device_id, name)
        except ValueError as e:
            device_dialogs.show_error(parent, "無法重新命名", str(e))
            return
        self._devices_changed()

    def remove_device(self, device_id: str, parent: Optional[Gtk.Window] = None) -> None:
        device = self.device_store.get(device_id)
        if device is None or not device_dialogs.confirm_remove(parent, device.name):
            return
        self.device_store.remove(device_id)
        self.states.pop(device_id, None)
        mijia_log(f"已移除裝置 {device.name} [{device_id}] (歷史檔保留)")
        self._devices_changed()

    def open_discovery(self) -> None:
        settings.set(DISCOVERY_PROMPTED_KEY, True)
        if self._discovery_dialog is None:
            self._discovery_dialog = device_dialogs.DiscoveryDialog(
                existing_ids=lambda: {d.id for d in self.devices},
                duration=DISCOVERY_SECONDS,
                on_add=self._add_candidates,
                on_retry=self._start_discovery_scan,
                on_closed=self._on_discovery_closed,
            )
            self._start_discovery_scan()
        else:
            self._discovery_dialog.present()

    def _start_discovery_scan(self) -> None:
        dialog = self._discovery_dialog
        if dialog is None:
            return
        dialog.show_searching()
        self.bluetooth_manager.start_discovery(
            lambda found: dialog.update(found) if self._discovery_dialog is dialog else None,
            lambda found: dialog.finish(found) if self._discovery_dialog is dialog else None,
        )

    def _on_discovery_closed(self) -> None:
        self._discovery_dialog = None
        self.bluetooth_manager.cancel_discovery()

    def _first_run_discovery(self) -> bool:
        if not self.devices:
            mijia_log("尚未加入任何裝置，自動開啟搜尋視窗")
            self.open_discovery()
        return GLib.SOURCE_REMOVE

    def _add_candidates(self, candidates: List[Candidate]) -> None:
        existing = list(self.devices)
        new_devices = []
        for candidate in candidates:
            device = Device(candidate.id, default_name(existing), candidate.kind)
            existing.append(device)
            new_devices.append(device)
        for device in self.device_store.add(new_devices):
            self.states[device.id] = self._cached_state(device)
            mijia_log(f"已加入裝置 {device.name} [{device.id}] ({device.kind})")
        self._devices_changed()

    def _devices_changed(self) -> None:
        self.bluetooth_manager.set_devices(self.devices, self.device_store.ordered_ids())
        self.rebuild_menu()
        self._refresh_tray()
        if self.dashboard is not None:
            self.dashboard.reload_devices()
        self._schedule_status_write()

    # MARK: - BluetoothManagerDelegate

    def did_update_adapter_status(self, status: str, available: bool) -> None:
        self.adapter_status = None if available else status
        if available:
            self.adapter_hint = None
        self._refresh_tray()
        if self.dashboard is not None:
            self.dashboard.refresh_status()
        self._schedule_status_write()

    def did_update_device_status(self, device_id: str, status: str, reachable: Optional[bool]) -> None:
        self._set_device_status(device_id, status, reachable)

    def _set_device_status(self, device_id: str, status: str, reachable: Optional[bool]) -> None:
        if self.device_store.get(device_id) is None:
            return  # 已移除的裝置
        self.states[device_id] = with_status(self.state_for(device_id), status, reachable)
        self._refresh_tray()
        if self.dashboard is not None:
            self.dashboard.device_state_changed(device_id)
        self._schedule_status_write()

    def did_update_reading(self, device_id: str, reading: SensorReading) -> None:
        device = self.device_store.get(device_id)
        if device is None:
            return
        reading = replace(reading, device_name=device.name)
        self.states[device_id] = with_reading(self.state_for(device_id), reading)
        self._record_history(device_id, reading)
        self._refresh_tray()
        if self.dashboard is not None:
            self.dashboard.device_state_changed(device_id)
        now = time.time()
        notifications.check_reading(self.app, device_id, device.name, reading, now)
        notifications.check_humidity(self.app, device_id, device.name, reading, now)
        self._schedule_status_write()

    def _record_history(self, device_id: str, reading: SensorReading) -> None:
        """開源廣播依更新間隔取樣 (避免每幾秒就寫一次檔)；原廠讀數每筆都記錄。"""
        history = HistoryManager.for_device(device_id)
        last = history.last_point
        if (not reading.is_broadcast or last is None
                or time.time() - last.timestamp >= self.bluetooth_manager.refresh_interval):
            history.add_point(
                temp=reading.temperature,
                hum=reading.humidity,
                volt=reading.voltage,
                battery=reading.battery_percent,
            )

    def did_fail_with_error(self, error: str) -> None:
        self.adapter_hint = error
        if self.dashboard is not None:
            self.dashboard.refresh_status()

    # MARK: - 狀態 JSON

    def _schedule_status_write(self) -> None:
        if self._status_write_source is not None:
            return
        wait = max(0.0, STATUS_WRITE_SECONDS - (time.monotonic() - self._last_status_write))
        self._status_write_source = GLib.timeout_add(int(wait * 1000), self._write_status)

    def _write_status(self) -> bool:
        self._status_write_source = None
        self._last_status_write = time.monotonic()
        payload = build_status_payload(
            self.devices, self.states, self.primary_id, self.bluetooth_manager.refresh_interval,
            datetime.now().astimezone().isoformat(timespec="seconds"), self.adapter_status,
            displayed_id=self.displayed_id,
        )
        write_status_json(payload)
        return GLib.SOURCE_REMOVE
