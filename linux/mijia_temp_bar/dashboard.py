"""彈出式儀表板：標頭 (即時裝置示意圖)、數據圖表分頁與設定分頁。

從系統匣選單開啟，貼近滑鼠位置顯示；點視窗外面 (失去焦點) 或按 Esc 會收起。
"""

import time
from pathlib import Path
from typing import Callable, List, Optional, Tuple

import gi

gi.require_version("Gdk", "3.0")
gi.require_version("GdkPixbuf", "2.0")
gi.require_version("Gtk", "3.0")
from gi.repository import Gdk, GdkPixbuf, GLib, Gtk, Pango  # noqa: E402

from . import autostart, notifications  # noqa: E402
from .chart import ChartDataType, ChartView  # noqa: E402
from .device_view import create_device_view  # noqa: E402
from .history import HistoryManager  # noqa: E402
from .icons import render_app_icon  # noqa: E402
from .logger import mijia_log  # noqa: E402
from .options import (  # noqa: E402
    CHART_RANGES,
    DEFAULT_CHART_RANGE_INDEX,
    INTERVALS,
    STYLE_TITLES,
    describe_interval,
    parse_interval_minutes,
)
from . import __version__  # noqa: E402
from .parsers import SensorReading  # noqa: E402

CSS = b"""
.mijia-dashboard { background-color: #15171c; border: 1px solid rgba(255, 255, 255, 0.14); }
.mijia-dashboard .header-title { font-size: 15px; font-weight: bold; }
.mijia-dashboard .model-badge { font-family: monospace; font-size: 10px; font-weight: 600; color: rgb(89, 191, 255); }
.mijia-dashboard .status-dot { font-size: 11px; font-weight: 500; }
.mijia-dashboard .last-update { font-size: 11px; color: rgb(140, 140, 140); }
.mijia-dashboard .metric-card { border-radius: 14px; border: 1px solid rgba(255, 255, 255, 0.08); background-color: rgba(255, 255, 255, 0.05); }
.mijia-dashboard .card-header { font-size: 12px; font-weight: 500; color: rgb(179, 179, 179); }
.mijia-dashboard .card-value { font-size: 32px; font-weight: bold; }
.mijia-dashboard .temp .card-value { color: rgb(255, 122, 31); }
.mijia-dashboard .hum .card-value { color: rgb(13, 173, 255); }
.mijia-dashboard .bat .card-value { color: rgb(26, 224, 133); }
.mijia-dashboard .card-sub { font-size: 11px; font-weight: 500; color: rgb(179, 179, 179); }
.mijia-dashboard .chart-title { font-size: 14px; font-weight: bold; }
.mijia-dashboard .section-title { font-size: 12px; font-weight: 600; color: rgb(158, 158, 158); }
.mijia-dashboard .settings-card { border-radius: 10px; border: 1px solid rgba(255, 255, 255, 0.08); background-color: rgba(255, 255, 255, 0.05); }
.mijia-dashboard .row-title { font-size: 13px; font-weight: 500; }
.mijia-dashboard .row-caption { font-size: 11px; color: rgb(148, 148, 148); }
.mijia-dashboard .about { font-size: 11px; color: rgb(128, 128, 128); }
"""

_css_installed = False


def _install_css() -> None:
    global _css_installed
    if _css_installed:
        return
    provider = Gtk.CssProvider()
    provider.load_from_data(CSS)
    Gtk.StyleContext.add_provider_for_screen(
        Gdk.Screen.get_default(), provider, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION
    )
    _css_installed = True


def _label(text: str, css_class: str, xalign: float = 0.0, tabular: bool = False) -> Gtk.Label:
    label = Gtk.Label(label=text, xalign=xalign)
    label.get_style_context().add_class(css_class)
    if tabular:
        attrs = Pango.AttrList()
        attrs.insert(Pango.attr_font_features_new("tnum"))
        label.set_attributes(attrs)
    return label


def _pixbuf_from_surface(surface) -> GdkPixbuf.Pixbuf:
    return Gdk.pixbuf_get_from_surface(surface, 0, 0, surface.get_width(), surface.get_height())


PANEL_WIDTH = 660
ROW_HEIGHT = 52          # 設定列固定高度
ROW_INSET = 16           # 設定列左右內距 (標題、說明、區塊標題共用同一條左邊界)


class DashboardWindow(Gtk.Window):
    def __init__(self, controller):
        super().__init__(title="米家溫濕度計 2")
        _install_css()
        self.controller = controller
        self._busy = False        # 開啟對話框時不因失去焦點而收起
        self._loading = False     # 同步設定值時不觸發變更事件
        self._focus_timer: Optional[int] = None

        self.set_decorated(False)
        self.set_resizable(False)
        self.set_skip_taskbar_hint(True)
        self.set_keep_above(True)
        self.set_icon(_pixbuf_from_surface(render_app_icon(128)))
        self.get_style_context().add_class("mijia-dashboard")
        self.connect("delete-event", lambda *_: self.hide() or True)
        self.connect("focus-out-event", self._on_focus_out)
        self.connect("key-press-event", self._on_key_press)

        container = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=0)
        container.set_margin_start(24)
        container.set_margin_end(24)
        container.set_margin_top(18)
        container.set_margin_bottom(20)
        self.add(container)

        self.stack = Gtk.Stack()
        self.stack.set_transition_type(Gtk.StackTransitionType.NONE)
        self.stack.add_titled(self._build_dashboard_page(), "dashboard", "數據圖表")
        self.stack.add_titled(self._build_settings_page(), "settings", "設定")

        container.pack_start(self._build_header(), False, False, 0)
        container.pack_start(self.stack, True, True, 0)
        container.show_all()
        self.reload_data()
        self.reload_settings()

    # MARK: - 彈出與收起

    def show_near_pointer(self, tab: str = "dashboard") -> None:
        self.stack.set_visible_child_name(tab)
        if tab == "settings":
            self.reload_settings()
        self.show_all()

        display = Gdk.Display.get_default()
        pointer = display.get_default_seat().get_pointer()
        _screen, px, py = pointer.get_position()
        monitor = display.get_monitor_at_point(px, py)
        area = monitor.get_workarea()
        width, height = self.get_size()
        # 系統匣多半在螢幕上緣：視窗右上角貼近滑鼠，並限制在工作區內
        x = min(max(area.x, px - width + 24), area.x + area.width - width)
        y = min(max(area.y, py + 12), area.y + area.height - height)
        self.move(x, y)
        self.present()

    def _on_focus_out(self, _widget, event) -> bool:
        # 下拉選單等的暫時抓取也會觸發失去焦點，所以稍後再確認視窗是否真的不在前景
        if self._focus_timer is None:
            self._focus_timer = GLib.timeout_add(150, self._hide_if_unfocused)
        return False

    def _hide_if_unfocused(self) -> bool:
        self._focus_timer = None
        if not self._busy and not self.is_active():
            self.hide()
        return GLib.SOURCE_REMOVE

    def _on_key_press(self, _widget, event) -> bool:
        if event.keyval == Gdk.KEY_Escape:
            self.hide()
            return True
        return False

    # MARK: - 標頭

    def _build_header(self) -> Gtk.Box:
        header = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=12)
        header.set_margin_bottom(14)

        self.device_view = create_device_view(46)
        self.device_view.set_valign(Gtk.Align.CENTER)
        header.pack_start(self.device_view, False, False, 0)

        titles = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=2)
        titles.set_valign(Gtk.Align.CENTER)
        title_row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
        title_row.pack_start(_label("米家藍牙溫濕度計 2", "header-title"), False, False, 0)
        badge = _label("LYWSD03MMC", "model-badge")
        badge.set_valign(Gtk.Align.CENTER)
        title_row.pack_start(badge, False, False, 0)
        titles.pack_start(title_row, False, False, 0)
        self.status_label = _label("● 搜尋中", "status-dot")
        self.status_label.set_ellipsize(Pango.EllipsizeMode.END)
        self.status_label.set_max_width_chars(28)
        titles.pack_start(self.status_label, False, False, 0)
        header.pack_start(titles, False, False, 0)

        switcher = Gtk.StackSwitcher()
        switcher.set_stack(self.stack)
        switcher.set_valign(Gtk.Align.CENTER)
        header.pack_end(switcher, False, False, 0)
        return header

    def update_status(self, text: str) -> None:
        self.status_label.set_text(f"● {text}")
        if "正常" in text or "休眠" in text:
            color = "#40e080"
        elif "連線中" in text or "搜尋" in text or "讀取" in text:
            color = "#59bfff"
        else:
            color = "#ffa633"
        self.status_label.set_markup(
            f'<span foreground="{color}">{GLib.markup_escape_text(self.status_label.get_text())}</span>'
        )

    # MARK: - 數據圖表分頁

    def _build_dashboard_page(self) -> Gtk.Box:
        page = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=0)

        cards = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=11, homogeneous=True)
        self.temp_value, self.temp_sub = self._add_metric_card(cards, "temp", "溫度")
        self.hum_value, self.hum_sub = self._add_metric_card(cards, "hum", "相對濕度")
        self.bat_value, self.bat_sub = self._add_metric_card(cards, "bat", "電池狀態")
        page.pack_start(cards, False, False, 0)

        chart_header = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
        chart_header.set_margin_top(16)
        chart_header.set_margin_bottom(10)
        chart_header.pack_start(_label("歷史趨勢", "chart-title"), False, False, 2)

        segments = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=0)
        segments.get_style_context().add_class("linked")
        group = None
        for data_type, title in (
            (ChartDataType.OVERVIEW, "總覽"),
            (ChartDataType.TEMPERATURE, "溫度"),
            (ChartDataType.HUMIDITY, "濕度"),
            (ChartDataType.VOLTAGE, "電壓"),
        ):
            button = Gtk.RadioButton.new_with_label_from_widget(group, title)
            button.set_mode(False)
            button.connect("toggled", self._handle_segment_changed, data_type)
            segments.pack_start(button, False, False, 0)
            group = button
        chart_header.pack_start(segments, False, False, 0)

        refresh_button = Gtk.Button(label="立即更新")
        refresh_button.connect("clicked", lambda _b: self.controller.refresh_now())
        chart_header.pack_end(refresh_button, False, False, 0)
        export_button = Gtk.Button(label="匯出 CSV")
        export_button.connect("clicked", self._handle_export_csv)
        chart_header.pack_end(export_button, False, False, 0)

        self.range_combo = Gtk.ComboBoxText()
        for title, _seconds in CHART_RANGES:
            self.range_combo.append_text(title)
        self.range_combo.set_active(DEFAULT_CHART_RANGE_INDEX)
        self.range_combo.connect("changed", self._handle_range_changed)
        chart_header.pack_end(self.range_combo, False, False, 0)
        page.pack_start(chart_header, False, False, 0)

        self.chart_view = ChartView()
        self.chart_view.set_size_request(PANEL_WIDTH - 48, 300)
        self.chart_view.time_range = CHART_RANGES[DEFAULT_CHART_RANGE_INDEX][1]
        page.pack_start(self.chart_view, True, True, 0)
        return page

    def _add_metric_card(self, parent: Gtk.Box, css_class: str, category: str) -> Tuple[Gtk.Label, Gtk.Label]:
        card = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=0)
        card.get_style_context().add_class("metric-card")
        card.get_style_context().add_class(css_class)
        card.set_size_request(190, 96)

        header = _label(category, "card-header")
        header.set_margin_start(14)
        header.set_margin_top(10)
        card.pack_start(header, False, False, 0)

        value = _label("--", "card-value", tabular=True)
        value.set_margin_start(12)
        card.pack_start(value, True, True, 0)

        sub = _label("載入中...", "card-sub")
        sub.set_margin_start(14)
        sub.set_margin_bottom(10)
        sub.set_ellipsize(Pango.EllipsizeMode.END)
        card.pack_start(sub, False, False, 0)

        parent.pack_start(card, True, True, 0)
        return value, sub

    def update_reading(self, r: SensorReading) -> None:
        history = HistoryManager.shared()
        self.temp_value.set_text(f"{r.temperature:.1f}°C")
        min_t = history.min_temperature if history.min_temperature is not None else r.temperature
        max_t = history.max_temperature if history.max_temperature is not None else r.temperature
        self.temp_sub.set_text(f"歷史 {min_t:.1f}° ~ {max_t:.1f}°")

        self.hum_value.set_text(f"{r.humidity:.0f}%")
        self.hum_sub.set_text("舒適" if 40 <= r.humidity <= 65 else ("偏濕" if r.humidity > 65 else "偏乾"))

        self.bat_value.set_text(f"{r.battery_percent}%")
        low = r.battery_percent <= 15 or r.voltage <= 2.60
        self.bat_sub.set_text(f"{r.voltage:.3f} V · " + ("電量過低，請更換電池" if low else "正常"))

        self.device_view.set_reading(r.temperature, r.humidity, r.battery_percent)
        self.reload_data()

    def reload_data(self) -> None:
        self.chart_view.update_points(HistoryManager.shared().points)

    def _handle_segment_changed(self, button: Gtk.RadioButton, data_type: ChartDataType) -> None:
        if button.get_active():
            self.chart_view.data_type = data_type

    def _handle_range_changed(self, combo: Gtk.ComboBoxText) -> None:
        index = combo.get_active()
        if 0 <= index < len(CHART_RANGES):
            self.chart_view.time_range = CHART_RANGES[index][1]

    def _handle_export_csv(self, _button) -> None:
        self._busy = True
        try:
            self._export_csv()
        finally:
            self._busy = False

    def _export_csv(self) -> None:
        chooser = Gtk.FileChooserNative.new("匯出溫濕度歷史數據", self, Gtk.FileChooserAction.SAVE, "儲存", "取消")
        chooser.set_do_overwrite_confirmation(True)
        chooser.set_current_name(f"mijia_temp_history_{int(time.time())}.csv")
        csv_filter = Gtk.FileFilter()
        csv_filter.set_name("CSV (*.csv)")
        csv_filter.add_pattern("*.csv")
        chooser.add_filter(csv_filter)

        response = chooser.run()
        filename = chooser.get_filename()
        chooser.destroy()
        if response != Gtk.ResponseType.ACCEPT or not filename:
            return

        try:
            HistoryManager.shared().export_csv(Path(filename))
            title, message, kind = "匯出成功", f"數據已成功儲存至:\n{filename}", Gtk.MessageType.INFO
        except OSError as e:
            title, message, kind = "匯出失敗", str(e), Gtk.MessageType.ERROR

        dialog = Gtk.MessageDialog(transient_for=self, modal=True, message_type=kind,
                                   buttons=Gtk.ButtonsType.OK, text=title)
        dialog.format_secondary_text(message)
        dialog.run()
        dialog.destroy()

    # MARK: - 設定分頁

    def _build_settings_page(self) -> Gtk.ScrolledWindow:
        scroller = Gtk.ScrolledWindow()
        scroller.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)
        scroller.set_min_content_height(470)
        scroller.set_min_content_width(PANEL_WIDTH - 48)

        page = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=0)
        page.set_margin_end(10)
        scroller.add(page)

        # 更新與省電
        card = self._section(page, "更新與省電")
        self.interval_combo = Gtk.ComboBoxText()
        for title, _seconds in INTERVALS:
            self.interval_combo.append_text(title)
        self.interval_combo.connect("changed", self._handle_interval_selected)
        self.custom_interval_entry = Gtk.Entry()
        self.custom_interval_entry.set_width_chars(9)
        self.custom_interval_entry.set_placeholder_text("自訂分鐘")
        self.custom_interval_entry.set_alignment(0.5)
        self.custom_interval_entry.connect("activate", self._handle_custom_interval)
        self._add_row(card, "更新間隔", "間隔越長越省電；自訂請輸入分鐘後按 Enter。",
                      [self.interval_combo, self.custom_interval_entry])

        # 狀態列
        card = self._section(page, "狀態列")
        self.style_combo = Gtk.ComboBoxText()
        for _style, title in STYLE_TITLES:
            self.style_combo.append_text(title)
        self.style_combo.connect("changed", self._handle_style_changed)
        self._add_row(card, "圖示樣式", None, [self.style_combo])
        self.hide_switch = self._switch(self._handle_hide_toggled)
        self._add_row(card, "僅連線時顯示", "斷線時隱藏系統匣圖示。", [self.hide_switch])
        self.autostart_switch = self._switch(self._handle_autostart_toggled)
        self._add_row(card, "開機自動啟動", "登入桌面時自動執行。", [self.autostart_switch])

        # 通知
        card = self._section(page, "通知")
        self.low_battery_switch = self._switch(self._handle_low_battery_toggled)
        self._add_row(card, "低電量通知", "電量 ≤ 15% 或電壓 ≤ 2.60V 時提醒，每天最多一次。", [self.low_battery_switch])
        self.humidity_switch = self._switch(self._handle_humidity_toggled)
        self._add_row(card, "濕度警示", "超出下方設定範圍時通知，持續超標每 3 小時再提醒。", [self.humidity_switch])
        self.humidity_high_spin = self._percent_spin()
        self._add_row(card, "濕度上限 (%)", "高於此值時通知。", [self.humidity_high_spin])
        self.humidity_low_spin = self._percent_spin()
        self._add_row(card, "濕度下限 (%)", "低於此值時通知。", [self.humidity_low_spin])

        about = _label(f"MijiaTempBar for Linux v{__version__}  ·  米家藍牙溫濕度計 2 (LYWSD03MMC)", "about")
        about.set_margin_start(ROW_INSET)
        about.set_margin_top(4)
        about.set_margin_bottom(8)
        page.pack_start(about, False, False, 0)
        return scroller

    def _section(self, page: Gtk.Box, title: str) -> Gtk.Box:
        header = _label(title, "section-title")
        header.set_margin_start(ROW_INSET)
        header.set_margin_top(14)
        header.set_margin_bottom(6)
        page.pack_start(header, False, False, 0)
        card = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=0)
        card.get_style_context().add_class("settings-card")
        page.pack_start(card, False, False, 0)
        return card

    def _add_row(self, card: Gtk.Box, title: str, caption: Optional[str], controls: List[Gtk.Widget]) -> None:
        """統一規格的設定列：固定高度，左邊標題 (+ 單行說明)，右邊控制項靠右。"""
        if card.get_children():
            card.pack_start(Gtk.Separator(orientation=Gtk.Orientation.HORIZONTAL), False, False, 0)

        row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
        row.set_size_request(-1, ROW_HEIGHT)
        row.set_margin_start(ROW_INSET)
        row.set_margin_end(ROW_INSET)

        texts = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=2)
        texts.set_valign(Gtk.Align.CENTER)
        title_label = _label(title, "row-title")
        title_label.set_ellipsize(Pango.EllipsizeMode.END)
        texts.pack_start(title_label, False, False, 0)
        if caption:
            caption_label = _label(caption, "row-caption")
            caption_label.set_ellipsize(Pango.EllipsizeMode.END)
            caption_label.set_tooltip_text(caption)
            texts.pack_start(caption_label, False, False, 0)
        row.pack_start(texts, True, True, 0)

        for control in reversed(controls):
            control.set_valign(Gtk.Align.CENTER)
            row.pack_end(control, False, False, 0)
        card.pack_start(row, False, False, 0)

    @staticmethod
    def _switch(handler: Callable) -> Gtk.Switch:
        switch = Gtk.Switch()
        switch.connect("notify::active", handler)
        return switch

    def _percent_spin(self) -> Gtk.SpinButton:
        spin = Gtk.SpinButton.new_with_range(0, 100, 1)
        spin.set_width_chars(4)
        spin.set_alignment(0.5)
        spin.connect("value-changed", self._handle_humidity_threshold_changed)
        return spin

    def reload_settings(self) -> None:
        """依目前實際設定同步控制項 (同步期間不觸發變更事件)。"""
        self._loading = True
        try:
            bt = self.controller.bluetooth_manager
            current = bt.refresh_interval
            index = next((i for i, (_t, sec) in enumerate(INTERVALS) if abs(sec - current) < 0.1), -1)
            self.interval_combo.set_active(index)
            self.custom_interval_entry.set_text("" if index >= 0 else describe_interval(current).split(" ")[0])
            self.custom_interval_entry.set_tooltip_text(None if index >= 0 else f"目前自訂：{describe_interval(current)}")

            self.style_combo.set_active(int(self.controller.display_style))
            self.hide_switch.set_active(self.controller.hide_when_disconnected)
            self.autostart_switch.set_active(autostart.is_enabled())
            self.low_battery_switch.set_active(notifications.is_enabled())

            enabled = notifications.humidity_enabled()
            high, low = notifications.humidity_thresholds()
            self.humidity_switch.set_active(enabled)
            self.humidity_high_spin.set_value(high)
            self.humidity_low_spin.set_value(low)
            self.humidity_high_spin.set_sensitive(enabled)
            self.humidity_low_spin.set_sensitive(enabled)
        finally:
            self._loading = False

    # 設定變更處理

    def _handle_interval_selected(self, combo: Gtk.ComboBoxText) -> None:
        index = combo.get_active()
        if self._loading or index < 0:
            return
        self.controller.bluetooth_manager.set_refresh_interval(INTERVALS[index][1])
        self.reload_settings()

    def _handle_custom_interval(self, entry: Gtk.Entry) -> None:
        seconds = parse_interval_minutes(entry.get_text())
        if seconds is not None:
            self.controller.bluetooth_manager.set_refresh_interval(seconds)
        else:
            mijia_log("自訂間隔無效 (需為 0.5 ~ 1440 分鐘)，維持原設定")
        self.reload_settings()

    def _handle_style_changed(self, combo: Gtk.ComboBoxText) -> None:
        index = combo.get_active()
        if self._loading or not (0 <= index < len(STYLE_TITLES)):
            return
        self.controller.set_display_style(STYLE_TITLES[index][0])

    def _handle_hide_toggled(self, switch: Gtk.Switch, _pspec) -> None:
        if not self._loading:
            self.controller.set_hide_when_disconnected(switch.get_active())

    def _handle_autostart_toggled(self, switch: Gtk.Switch, _pspec) -> None:
        if self._loading:
            return
        try:
            autostart.set_enabled(switch.get_active())
        except OSError as e:
            mijia_log(f"無法設定開機自動啟動: {e}")
        self.reload_settings()

    def _handle_low_battery_toggled(self, switch: Gtk.Switch, _pspec) -> None:
        if not self._loading:
            notifications.set_enabled(switch.get_active())

    def _handle_humidity_toggled(self, switch: Gtk.Switch, _pspec) -> None:
        if self._loading:
            return
        notifications.set_humidity_enabled(switch.get_active())
        notifications.reset_humidity_monitor()
        self.reload_settings()

    def _handle_humidity_threshold_changed(self, _spin) -> None:
        if self._loading:
            return
        high = int(self.humidity_high_spin.get_value())
        low = int(self.humidity_low_spin.get_value())
        if not notifications.set_humidity_thresholds(high, low):
            mijia_log(f"濕度上下限無效 (上限 {high}%、下限 {low}%)，維持原設定")
        notifications.reset_humidity_monitor()
        self.reload_settings()
