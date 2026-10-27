"""即時儀表板視窗：設備資訊、三大指標卡片與歷史趨勢折線圖。"""

import time
from pathlib import Path
from typing import Callable, Optional, Tuple

import gi

gi.require_version("Gdk", "3.0")
gi.require_version("GdkPixbuf", "2.0")
gi.require_version("Gtk", "3.0")
from gi.repository import Gdk, GdkPixbuf, GLib, Gtk, Pango  # noqa: E402

from .chart import ChartDataType, ChartView  # noqa: E402
from .history import HistoryManager  # noqa: E402
from .icons import render_app_icon  # noqa: E402
from .parsers import SensorReading  # noqa: E402

_PACKAGE_DIR = Path(__file__).resolve().parent
# 從原始碼執行時位於 <repo>/Resources，安裝後位於安裝目錄的 Resources
DEVICE_IMAGE_CANDIDATES = [
    _PACKAGE_DIR.parent / "Resources" / "device.png",
    _PACKAGE_DIR.parent.parent / "Resources" / "device.png",
]

CSS = b"""
.mijia-dashboard { background-color: #15171c; }
.mijia-dashboard .header-title { font-size: 15px; font-weight: bold; }
.mijia-dashboard .model-badge { font-family: monospace; font-size: 10px; font-weight: 600; color: rgb(89, 191, 255); }
.mijia-dashboard .status-dot { font-size: 11px; font-weight: 500; color: rgb(64, 224, 128); }
.mijia-dashboard .last-update { font-size: 11px; color: rgb(140, 140, 140); }
.mijia-dashboard .img-box {
    background-color: rgba(31, 31, 31, 0.8);
    border: 1px solid rgba(255, 255, 255, 0.12);
    border-radius: 8px;
}
.mijia-dashboard .metric-card { border-radius: 14px; border: 1px solid; }
.mijia-dashboard .metric-card.temp { background-color: rgba(255, 115, 26, 0.08); border-color: rgba(255, 122, 31, 0.25); }
.mijia-dashboard .metric-card.hum { background-color: rgba(13, 153, 242, 0.08); border-color: rgba(13, 173, 255, 0.25); }
.mijia-dashboard .metric-card.bat { background-color: rgba(26, 204, 115, 0.08); border-color: rgba(26, 224, 133, 0.25); }
.mijia-dashboard .card-header { font-size: 10.5px; font-weight: bold; }
.mijia-dashboard .temp .card-header { color: rgba(255, 122, 31, 0.9); }
.mijia-dashboard .hum .card-header { color: rgba(13, 173, 255, 0.9); }
.mijia-dashboard .bat .card-header { color: rgba(26, 224, 133, 0.9); }
.mijia-dashboard .card-value { font-size: 32px; font-weight: bold; }
.mijia-dashboard .temp .card-value { color: rgb(255, 122, 31); }
.mijia-dashboard .hum .card-value { color: rgb(13, 173, 255); }
.mijia-dashboard .bat .card-value { color: rgb(26, 224, 133); }
.mijia-dashboard .card-sub { font-size: 11px; font-weight: 500; color: rgb(179, 179, 179); }
.mijia-dashboard .chart-title { font-size: 14px; font-weight: bold; }
.mijia-dashboard .points-count { font-size: 11px; font-weight: 500; color: rgb(153, 153, 153); }
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


class DashboardWindow(Gtk.Window):
    def __init__(self, on_refresh_requested: Optional[Callable[[], None]] = None):
        super().__init__(title="米家溫濕度計 2 (LYWSD03MMC) - 即時儀表板")
        _install_css()
        self.on_refresh_requested = on_refresh_requested

        self.set_resizable(False)
        self.set_position(Gtk.WindowPosition.CENTER)
        self.set_icon(_pixbuf_from_surface(render_app_icon(128)))
        self.get_style_context().add_class("mijia-dashboard")
        # 關閉時只隱藏視窗，保留狀態以便再次開啟
        self.connect("delete-event", lambda *_: self.hide() or True)

        header_bar = Gtk.HeaderBar(title="即時儀表板", show_close_button=True)
        header_bar.set_decoration_layout("menu:minimize,close")
        header_bar.show_all()
        self.set_titlebar(header_bar)

        container = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=0)
        container.set_margin_start(24)
        container.set_margin_end(24)
        container.set_margin_top(14)
        container.set_margin_bottom(20)
        self.add(container)

        container.pack_start(self._build_header(), False, False, 0)

        # 中間三大指標卡片
        cards = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=11, homogeneous=True)
        cards.set_margin_top(18)
        self.temp_value, self.temp_sub = self._add_metric_card(cards, "temp", "🌡️", "TEMPERATURE · 溫度")
        self.hum_value, self.hum_sub = self._add_metric_card(cards, "hum", "💧", "HUMIDITY · 相對濕度")
        self.bat_value, self.bat_sub = self._add_metric_card(cards, "bat", "🔋", "BATTERY · 電池狀態")
        container.pack_start(cards, False, False, 0)

        # 底部圖表區塊
        chart_header = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=12)
        chart_header.set_margin_top(16)
        chart_header.set_margin_bottom(10)
        chart_header.pack_start(_label("歷史趨勢折線圖", "chart-title"), False, False, 2)

        segments = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=0)
        segments.get_style_context().add_class("linked")
        group = None
        for data_type, title in (
            (ChartDataType.OVERVIEW, "📊 綜合總覽"),
            (ChartDataType.TEMPERATURE, "🌡️ 溫度走勢"),
            (ChartDataType.HUMIDITY, "💧 濕度走勢"),
            (ChartDataType.VOLTAGE, "🔋 電壓回彈"),
        ):
            button = Gtk.RadioButton.new_with_label_from_widget(group, title)
            button.set_mode(False)
            button.connect("toggled", self._handle_segment_changed, data_type)
            segments.pack_start(button, False, False, 0)
            group = button
        chart_header.pack_start(segments, False, False, 0)

        self.points_count_label = _label("共 0 個採樣點", "points-count", xalign=1.0, tabular=True)
        chart_header.pack_end(self.points_count_label, False, False, 0)
        container.pack_start(chart_header, False, False, 0)

        self.chart_view = ChartView()
        self.chart_view.set_size_request(682, 316)
        container.pack_start(self.chart_view, True, True, 0)

        container.show_all()
        self.reload_data()

    def _build_header(self) -> Gtk.Box:
        header = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=10)

        # 硬體縮圖 (34x34)
        img_box = Gtk.Box()
        img_box.get_style_context().add_class("img-box")
        img_box.set_size_request(34, 34)
        img_box.set_valign(Gtk.Align.CENTER)
        device_image = self._load_device_image(30)
        if device_image is not None:
            device_image.set_margin_start(2)
            device_image.set_margin_end(2)
            device_image.set_margin_top(2)
            device_image.set_margin_bottom(2)
            img_box.pack_start(device_image, True, True, 0)
        header.pack_start(img_box, False, False, 0)

        # 標題與標籤
        titles = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=2)
        titles.set_valign(Gtk.Align.CENTER)
        title_row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
        title_row.pack_start(_label("米家藍牙溫濕度計 2", "header-title"), False, False, 0)
        model_badge = _label("LYWSD03MMC", "model-badge")
        model_badge.set_valign(Gtk.Align.CENTER)
        title_row.pack_start(model_badge, False, False, 0)
        titles.pack_start(title_row, False, False, 0)
        titles.pack_start(_label("● 連線正常 (省電輪詢模式)", "status-dot"), False, False, 0)
        header.pack_start(titles, False, False, 0)

        # 右側按鈕與最後讀取時間
        refresh_button = Gtk.Button(label="⟳ 立即刷新")
        refresh_button.set_valign(Gtk.Align.CENTER)
        refresh_button.connect("clicked", self._handle_refresh_clicked)
        header.pack_end(refresh_button, False, False, 0)

        export_button = Gtk.Button(label="⤓ 匯出 CSV")
        export_button.set_valign(Gtk.Align.CENTER)
        export_button.connect("clicked", self._handle_export_csv)
        header.pack_end(export_button, False, False, 0)

        self.last_update_label = _label("最後讀取: --:--", "last-update", xalign=1.0, tabular=True)
        header.pack_end(self.last_update_label, False, False, 6)
        return header

    def _load_device_image(self, size: int) -> Optional[Gtk.Image]:
        scale = self.get_scale_factor()
        for path in DEVICE_IMAGE_CANDIDATES:
            if path.is_file():
                try:
                    pixbuf = GdkPixbuf.Pixbuf.new_from_file_at_scale(str(path), size * scale, size * scale, True)
                except GLib.Error:
                    continue
                surface = Gdk.cairo_surface_create_from_pixbuf(pixbuf, scale, None)
                return Gtk.Image.new_from_surface(surface)
        return None

    def _add_metric_card(self, parent: Gtk.Box, css_class: str, icon: str, category: str) -> Tuple[Gtk.Label, Gtk.Label]:
        card = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=0)
        card.get_style_context().add_class("metric-card")
        card.get_style_context().add_class(css_class)
        card.set_size_request(220, 100)

        header = _label(f"{icon} {category}", "card-header")
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
        self.temp_sub.set_text(f"↓ 最低 {min_t:.1f}°    ↑ 最高 {max_t:.1f}°")

        self.hum_value.set_text(f"{r.humidity:.0f}%")
        if 40 <= r.humidity <= 65:
            comfort = "舒適度：適宜 (Comfortable) 😊"
        elif r.humidity > 65:
            comfort = "濕度偏高 (Humid) 💧"
        else:
            comfort = "空氣乾燥 (Dry) 🏜️"
        self.hum_sub.set_text(comfort)

        self.bat_value.set_text(f"{r.battery_percent}%")
        self.bat_sub.set_text(f"即時電壓 {r.voltage:.3f} V · 狀態穩定")

        self.last_update_label.set_text(f"最後讀取: {r.last_updated:%H:%M:%S}")
        self.reload_data()

    def reload_data(self) -> None:
        points = HistoryManager.shared().points
        self.points_count_label.set_text(f"共 {len(points)} 個採樣點")
        self.chart_view.update_points(points)

    def _handle_segment_changed(self, button: Gtk.RadioButton, data_type: ChartDataType) -> None:
        if button.get_active():
            self.chart_view.data_type = data_type

    def _handle_refresh_clicked(self, _button) -> None:
        if self.on_refresh_requested is not None:
            self.on_refresh_requested()

    def _handle_export_csv(self, _button) -> None:
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
