"""系統匣圖示 (AppIndicator)、雙行微型膠囊渲染與精簡選單 (儀表板與設定在彈出視窗內)。"""

import time
from datetime import datetime
from typing import Optional

import gi

gi.require_version("Gtk", "3.0")
from gi.repository import GLib, Gtk  # noqa: E402

try:
    gi.require_version("AyatanaAppIndicator3", "0.1")
    from gi.repository import AyatanaAppIndicator3 as AppIndicator  # noqa: E402
except (ValueError, ImportError):
    gi.require_version("AppIndicator3", "0.1")
    from gi.repository import AppIndicator3 as AppIndicator  # noqa: E402

from . import notifications, update_check  # noqa: E402
from .bluetooth import BluetoothManager  # noqa: E402
from .history import HistoryManager  # noqa: E402
from .icons import TrayIconWriter, render_stacked, render_stats_badge, render_text  # noqa: E402
from .logger import mijia_log  # noqa: E402
from .options import DisplayStyle  # noqa: E402
from .parsers import SensorReading  # noqa: E402
from .settings import RUNTIME_DIR, settings  # noqa: E402


def dispatch_to_main(fn, *args) -> None:
    def run():
        fn(*args)
        return GLib.SOURCE_REMOVE
    GLib.idle_add(run)


class StatusBarController:
    def __init__(self, app: Gtk.Application):
        self.app = app
        self.is_connected = False
        self.latest_reading: Optional[SensorReading] = None
        self.dashboard = None
        self._temp_show_source: Optional[int] = None
        self.status_text = "正在搜尋藍牙設備..."
        self.update_result = None

        # 讀取偏好設定
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

        self.bluetooth_manager = BluetoothManager(dispatch=dispatch_to_main)
        self.bluetooth_manager.delegate = self

        self._icons = TrayIconWriter(RUNTIME_DIR / "icons")
        self._setup_indicator()
        self._setup_menu()

        # 啟動時立刻恢復最近一次讀取的數據 (避免圖示閃爍或意外消失)
        history = HistoryManager.shared()
        if history.points:
            last = history.points[-1]
            self.is_connected = True
            self._set_visible(True)
            cached = SensorReading(
                temperature=last.temperature,
                humidity=last.humidity,
                battery_percent=last.batteryPercent,
                voltage=last.voltage,
                rssi=None,
                device_name="LYWSD03MMC",
                last_updated=datetime.fromtimestamp(last.timestamp),
                mode="原廠直連 (秒讀休眠)",
            )
            self.latest_reading = cached
            self._update_title()
        elif self.hide_when_disconnected:
            # 首次全新安裝無快取數據時，若超過 45 秒未連線才依設定隱藏
            self._temp_show_source = GLib.timeout_add_seconds(45, self._hide_if_still_disconnected)

        self.bluetooth_manager.start()

        # 啟動後稍等再檢查新版本 (每天最多一次)
        GLib.timeout_add_seconds(8, self._auto_check_update)

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

    # MARK: - 系統匣圖示

    def _setup_indicator(self) -> None:
        self.indicator = AppIndicator.Indicator.new(
            "mijia-temp-bar",
            self._icons.write(render_text("🌡️ 搜尋中...")),
            AppIndicator.IndicatorCategory.HARDWARE,
        )
        self.indicator.set_title("米家藍牙溫濕度計 2")
        self.indicator.set_status(AppIndicator.IndicatorStatus.ACTIVE)

    def _set_visible(self, visible: bool) -> None:
        self.indicator.set_status(
            AppIndicator.IndicatorStatus.ACTIVE if visible else AppIndicator.IndicatorStatus.PASSIVE
        )

    def _set_tray_image(self, surface, description: str) -> None:
        self.indicator.set_icon_full(self._icons.write(surface), description)

    def _update_title(self) -> None:
        r = self.latest_reading or self.bluetooth_manager.current_reading
        if r is None:
            self._set_tray_image(render_text("🌡️ 搜尋中..."), "搜尋中")
            return

        t, h = r.temperature, r.humidity
        if self.display_style == DisplayStyle.STATS_BADGE:
            surface = render_stats_badge(t, h)
        elif self.display_style == DisplayStyle.STACKED:
            surface = render_stacked(t, h)
        elif self.display_style == DisplayStyle.HORIZONTAL:
            surface = render_text(f"🌡️ {t:.1f}°C  💧 {h:.0f}%")
        elif self.display_style == DisplayStyle.TEMP_ONLY:
            surface = render_text(f"🌡️ {t:.1f}°C")
        else:
            surface = render_text(f"{t:.1f}° {h:.0f}%")

        description = (
            f"{r.device_name}\n溫度: {t:.1f}°C\n濕度: {h:.0f}%\n電量: {r.battery_percent}%\n"
            f"更新間隔: {int(self.bluetooth_manager.refresh_interval)}秒\n模式: {r.mode}"
        )
        self._set_tray_image(surface, description)

    def _hide_if_still_disconnected(self) -> bool:
        self._temp_show_source = None
        if not self.is_connected:
            self._set_visible(False)
            mijia_log("尚未連線，依設定自動隱藏狀態列圖示")
        return GLib.SOURCE_REMOVE

    def _cancel_temp_show_timer(self) -> None:
        if self._temp_show_source is not None:
            GLib.source_remove(self._temp_show_source)
            self._temp_show_source = None

    def temporarily_show_status_item(self) -> None:
        self._cancel_temp_show_timer()
        self._set_visible(True)
        if not self.is_connected and self.hide_when_disconnected:
            self._temp_show_source = GLib.timeout_add_seconds(10, self._hide_if_still_disconnected)

    def handle_reopen(self) -> None:
        """使用者再次從應用程式選單啟動時：暫時喚起狀態列顯示並打開儀表板。"""
        self.temporarily_show_status_item()
        self.show_dashboard()

    # MARK: - 選單

    def _add_item(self, menu: Gtk.Menu, label: str, callback=None) -> Gtk.MenuItem:
        item = Gtk.MenuItem.new_with_label(label)
        if callback is not None:
            item.connect("activate", lambda _item: callback())
        else:
            item.set_sensitive(False)
        menu.append(item)
        return item

    def _setup_menu(self) -> None:
        """精簡選單：只留開啟儀表板與結束；間隔、樣式、通知等設定都在儀表板的「設定」分頁。"""
        menu = Gtk.Menu()
        open_dashboard_item = self._add_item(menu, "開啟儀表板", self.show_dashboard)
        menu.append(Gtk.SeparatorMenuItem())
        self._add_item(menu, "結束 MijiaTempBar", self.app.quit)
        menu.show_all()
        self.indicator.set_menu(menu)
        # 滑鼠中鍵點擊圖示直接開啟儀表板
        self.indicator.set_secondary_activate_target(open_dashboard_item)

    # MARK: - 供儀表板設定分頁呼叫

    def set_display_style(self, style: DisplayStyle) -> None:
        self.display_style = style
        settings.set("DisplayStyle", int(style))
        self._update_title()

    def set_hide_when_disconnected(self, hide: bool) -> None:
        self.hide_when_disconnected = hide
        settings.set("HideWhenDisconnected", hide)
        self._set_visible(not (hide and not self.is_connected))

    def show_dashboard(self) -> None:
        if self.dashboard is None:
            from .dashboard import DashboardWindow
            self.dashboard = DashboardWindow(self)
        reading = self.latest_reading or self.bluetooth_manager.current_reading
        if reading is not None:
            self.dashboard.update_reading(reading)
        else:
            self.dashboard.reload_data()
        self.dashboard.update_status(self.status_text)
        if self.update_result is not None:
            self.dashboard.show_update_result(self.update_result)
        self.dashboard.show_near_pointer()

    def refresh_now(self) -> None:
        self._set_visible(True)
        self.set_status_text("正在連線重新整理...")
        self.bluetooth_manager.manual_refresh()

    def set_status_text(self, text: str) -> None:
        self.status_text = text
        if self.dashboard is not None:
            self.dashboard.update_status(text)

    # MARK: - BluetoothManagerDelegate

    def did_update_status(self, status: str, reachable: Optional[bool] = None) -> None:
        self.set_status_text(status)

        if reachable is False:
            self.is_connected = False
            if self.hide_when_disconnected:
                self._set_visible(False)
        elif self.latest_reading is None:
            self._set_tray_image(render_text(f"🌡️ {status}"), status)

    def did_update_reading(self, reading: SensorReading) -> None:
        self.is_connected = True
        self._cancel_temp_show_timer()
        self.latest_reading = reading

        self._set_visible(True)
        self._update_title()

        # 記錄歷史數據 (開源廣播模式依更新間隔取樣，避免每幾秒就寫一次檔) 並同步儀表板
        history = HistoryManager.shared()
        last_ts = history.points[-1].timestamp if history.points else None
        if (not reading.is_broadcast or last_ts is None
                or time.time() - last_ts >= self.bluetooth_manager.refresh_interval):
            history.add_point(
                temp=reading.temperature,
                hum=reading.humidity,
                volt=reading.voltage,
                battery=reading.battery_percent,
            )
        if self.dashboard is not None:
            self.dashboard.update_reading(reading)
        notifications.check_reading(self.app, reading, time.time())
        notifications.check_humidity(self.app, reading, time.time())

    def did_fail_with_error(self, error: str) -> None:
        self.set_status_text(error)
