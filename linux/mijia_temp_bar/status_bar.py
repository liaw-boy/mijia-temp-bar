"""系統匣圖示 (AppIndicator)、雙行微型膠囊渲染與下拉選單。"""

import time
from datetime import datetime
from enum import IntEnum
from typing import List, Optional, Tuple

import gi

gi.require_version("Gtk", "3.0")
from gi.repository import GLib, Gtk  # noqa: E402

try:
    gi.require_version("AyatanaAppIndicator3", "0.1")
    from gi.repository import AyatanaAppIndicator3 as AppIndicator  # noqa: E402
except (ValueError, ImportError):
    gi.require_version("AppIndicator3", "0.1")
    from gi.repository import AppIndicator3 as AppIndicator  # noqa: E402

from . import autostart  # noqa: E402
from .bluetooth import BluetoothManager  # noqa: E402
from .history import HistoryManager  # noqa: E402
from .icons import TrayIconWriter, render_stacked, render_stats_badge, render_text  # noqa: E402
from .logger import mijia_log  # noqa: E402
from .parsers import SensorReading  # noqa: E402
from .settings import RUNTIME_DIR, settings  # noqa: E402


class DisplayStyle(IntEnum):
    STATS_BADGE = 0  # 雙行微型膠囊風格 (TMP / HUM 雙行對齊)
    STACKED = 1      # 純數字雙行堆疊 (26.1° / 63%)
    HORIZONTAL = 2   # 橫向完整 (🌡️ 26.1°C  💧 65%)
    TEMP_ONLY = 3    # 僅溫度 (🌡️ 26.1°C)
    COMPACT = 4      # 緊湊單行 (26.1° 65%)


STYLE_TITLES: List[Tuple[DisplayStyle, str]] = [
    (DisplayStyle.STATS_BADGE, "雙行微型膠囊樣式 ([TMP] / [HUM])"),
    (DisplayStyle.STACKED, "純數字雙行堆疊 (26.1° / 63%)"),
    (DisplayStyle.HORIZONTAL, "橫向完整 (🌡️ 26°C  💧 65%)"),
    (DisplayStyle.TEMP_ONLY, "僅溫度 (🌡️ 26°C)"),
    (DisplayStyle.COMPACT, "緊湊單行 (26.1° 65%)"),
]

INTERVALS: List[Tuple[str, float]] = [
    ("30 秒 (即時模式 - 較耗電)", 30.0),
    ("1 分鐘", 60.0),
    ("3 分鐘", 180.0),
    ("5 分鐘 (推薦平衡)", 300.0),
    ("10 分鐘", 600.0),
    ("15 分鐘", 900.0),
    ("30 分鐘 (極致省電)", 1800.0),
    ("1 小時 (超省電休眠，續航 1 年+)", 3600.0),
    ("2 小時", 7200.0),
]

CUSTOM_INTERVAL_TITLE = "自訂時間 (分鐘)..."


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
        self._updating_menu = False

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
            self._apply_reading_to_menu(cached)
        elif self.hide_when_disconnected:
            # 首次全新安裝無快取數據時，若超過 45 秒未連線才依設定隱藏
            self._temp_show_source = GLib.timeout_add_seconds(45, self._hide_if_still_disconnected)

        self.bluetooth_manager.start()
        self._refresh_interval_menu_checks()

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
        menu = Gtk.Menu()

        self.header_item = self._add_item(menu, "米家藍牙溫濕度計 2", self.show_dashboard)
        open_dashboard_item = self._add_item(menu, "📊 開啟即時儀表板與歷史圖表...", self.show_dashboard)
        self.status_item = self._add_item(menu, "狀態: 正在搜尋藍牙設備...")

        menu.append(Gtk.SeparatorMenuItem())

        self.temp_item = self._add_item(menu, "溫度: -- °C")
        self.hum_item = self._add_item(menu, "濕度: -- %")
        self.bat_item = self._add_item(menu, "電量: -- %")
        self.mode_item = self._add_item(menu, "模式: --")
        self.time_item = self._add_item(menu, "最後更新: --")

        menu.append(Gtk.SeparatorMenuItem())

        self._add_item(menu, "重新整理 / 重新搜尋", self._handle_refresh)

        # 連線間隔 / 更新頻率子選單
        interval_menu = Gtk.Menu()
        self._interval_items: List[Tuple[Gtk.RadioMenuItem, float]] = []
        group = None
        for title, seconds in INTERVALS:
            item = Gtk.RadioMenuItem.new_with_label_from_widget(group, title)
            group = item
            item.connect("activate", self._handle_select_interval, seconds)
            interval_menu.append(item)
            self._interval_items.append((item, seconds))
        interval_menu.append(Gtk.SeparatorMenuItem())
        self.custom_interval_item = Gtk.RadioMenuItem.new_with_label_from_widget(group, CUSTOM_INTERVAL_TITLE)
        self.custom_interval_item.connect("activate", self._handle_custom_interval)
        interval_menu.append(self.custom_interval_item)

        interval_parent = Gtk.MenuItem.new_with_label("連線間隔時間 (更新頻率)")
        interval_parent.set_submenu(interval_menu)
        menu.append(interval_parent)

        # 僅連線時顯示開關
        self.hide_when_disconnected_item = Gtk.CheckMenuItem.new_with_label("僅連線時顯示 (斷線時自動隱藏圖示)")
        self.hide_when_disconnected_item.set_active(self.hide_when_disconnected)
        self.hide_when_disconnected_item.connect("activate", self._toggle_hide_when_disconnected)
        menu.append(self.hide_when_disconnected_item)

        # 樣式切換子選單
        style_menu = Gtk.Menu()
        self._style_items: List[Tuple[Gtk.RadioMenuItem, DisplayStyle]] = []
        group = None
        for style, title in STYLE_TITLES:
            item = Gtk.RadioMenuItem.new_with_label_from_widget(group, title)
            group = item
            item.set_active(style == self.display_style)
            item.connect("activate", self._handle_select_style, style)
            style_menu.append(item)
            self._style_items.append((item, style))

        style_parent = Gtk.MenuItem.new_with_label("狀態列樣式")
        style_parent.set_submenu(style_menu)
        menu.append(style_parent)

        # 開機自動啟動 (Linux 沒有統一的登入項目設定介面，直接提供開關)
        self.autostart_item = Gtk.CheckMenuItem.new_with_label("開機時自動啟動")
        self.autostart_item.set_active(autostart.is_enabled())
        self.autostart_item.connect("activate", self._toggle_autostart)
        menu.append(self.autostart_item)

        menu.append(Gtk.SeparatorMenuItem())

        self._add_item(menu, "結束 MijiaTempBar", self.app.quit)

        menu.show_all()
        self.indicator.set_menu(menu)
        # 滑鼠中鍵點擊圖示直接開啟儀表板
        self.indicator.set_secondary_activate_target(open_dashboard_item)

    # MARK: - Actions

    def _handle_select_interval(self, item: Gtk.RadioMenuItem, seconds: float) -> None:
        if self._updating_menu or not item.get_active():
            return
        self.bluetooth_manager.set_refresh_interval(seconds)
        self._refresh_interval_menu_checks()

    def _handle_custom_interval(self, _item: Gtk.RadioMenuItem) -> None:
        if self._updating_menu:
            return

        dialog = Gtk.MessageDialog(
            message_type=Gtk.MessageType.QUESTION,
            buttons=Gtk.ButtonsType.NONE,
            text="自訂更新間隔時間",
        )
        dialog.format_secondary_text("請輸入更新輪詢間隔（以分鐘為單位）：\n例如輸入 60 代表 1 小時，輸入 120 代表 2 小時。")
        dialog.add_buttons("取消", Gtk.ResponseType.CANCEL, "確定", Gtk.ResponseType.OK)
        dialog.set_default_response(Gtk.ResponseType.OK)
        dialog.set_keep_above(True)

        entry = Gtk.Entry()
        entry.set_text(str(max(1, int(self.bluetooth_manager.refresh_interval / 60.0))))
        entry.set_activates_default(True)
        dialog.get_message_area().pack_start(entry, False, False, 0)
        entry.show()

        response = dialog.run()
        text = entry.get_text().strip()
        dialog.destroy()

        if response == Gtk.ResponseType.OK:
            try:
                minutes = float(text)
            except ValueError:
                minutes = 0.0
            if minutes >= 0.5:
                self.bluetooth_manager.set_refresh_interval(minutes * 60.0)
        self._refresh_interval_menu_checks()

    def _refresh_interval_menu_checks(self) -> None:
        current = self.bluetooth_manager.refresh_interval
        matched = next((item for item, seconds in self._interval_items if abs(seconds - current) < 0.1), None)

        self._updating_menu = True
        try:
            (matched or self.custom_interval_item).set_active(True)
        finally:
            self._updating_menu = False

        if matched is not None:
            self.custom_interval_item.set_label(CUSTOM_INTERVAL_TITLE)
        elif current >= 3600.0:
            hours = current / 3600.0
            formatted = f"{hours:.0f}" if hours.is_integer() else f"{hours:.1f}"
            self.custom_interval_item.set_label(f"自訂時間... (目前: {formatted} 小時)")
        else:
            self.custom_interval_item.set_label(f"自訂時間... (目前: {round(current / 60.0)} 分鐘)")

    def _toggle_hide_when_disconnected(self, item: Gtk.CheckMenuItem) -> None:
        if self._updating_menu:
            return
        self.hide_when_disconnected = item.get_active()
        settings.set("HideWhenDisconnected", self.hide_when_disconnected)
        self._set_visible(not (self.hide_when_disconnected and not self.is_connected))

    def _toggle_autostart(self, item: Gtk.CheckMenuItem) -> None:
        try:
            autostart.set_enabled(item.get_active())
        except OSError as e:
            mijia_log(f"無法設定開機自動啟動: {e}")
        self._updating_menu = True
        try:
            item.set_active(autostart.is_enabled())
        finally:
            self._updating_menu = False

    def _handle_select_style(self, item: Gtk.RadioMenuItem, style: DisplayStyle) -> None:
        if self._updating_menu or not item.get_active():
            return
        self.display_style = style
        settings.set("DisplayStyle", int(style))
        self._update_title()

    def show_dashboard(self) -> None:
        if self.dashboard is None:
            from .dashboard import DashboardWindow
            self.dashboard = DashboardWindow(on_refresh_requested=self.bluetooth_manager.manual_refresh)
        reading = self.latest_reading or self.bluetooth_manager.current_reading
        if reading is not None:
            self.dashboard.update_reading(reading)
        else:
            self.dashboard.reload_data()
        self.dashboard.present()

    def _handle_refresh(self) -> None:
        self._set_visible(True)
        self.status_item.set_label("狀態: 正在連線重新整理...")
        self.bluetooth_manager.manual_refresh()

    # MARK: - BluetoothManagerDelegate

    def did_update_status(self, status: str, reachable: Optional[bool] = None) -> None:
        self.status_item.set_label(f"狀態: {status}")

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
        self._apply_reading_to_menu(reading)

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

    def _apply_reading_to_menu(self, reading: SensorReading) -> None:
        self.header_item.set_label(reading.device_name)
        self.temp_item.set_label(f"溫度: {reading.temperature:.1f} °C")
        self.hum_item.set_label(f"濕度: {reading.humidity:.1f} %")
        self.bat_item.set_label(f"電量: {reading.battery_percent} % ({reading.voltage:.2f}V)")
        self.mode_item.set_label(f"連線模式: {reading.mode}")
        self.time_item.set_label(f"最後更新: {reading.last_updated:%H:%M:%S}")
        self.status_item.set_label("狀態: 正常運作中")

    def did_fail_with_error(self, error: str) -> None:
        self.status_item.set_label(f"提示: {error}")
