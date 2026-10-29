"""依 LYWSD03MMC 外觀繪製的即時示意圖：白色圓角機身、灰綠 LCD、七段顯示溫濕度。

純邏輯 (七段對照、顏文字、數值格式) 與 GTK 繪製分開，前者可單元測試。
"""

from typing import Dict, Optional, Sequence, Tuple

# 七段順序: a(上) b(右上) c(右下) d(下) e(左下) f(左上) g(中)
SEGMENTS: Dict[str, Tuple[bool, ...]] = {
    "0": (True, True, True, True, True, True, False),
    "1": (False, True, True, False, False, False, False),
    "2": (True, True, False, True, True, False, True),
    "3": (True, True, True, True, False, False, True),
    "4": (False, True, True, False, False, True, True),
    "5": (True, False, True, True, False, True, True),
    "6": (True, False, True, True, True, True, True),
    "7": (True, True, True, False, False, False, False),
    "8": (True, True, True, True, True, True, True),
    "9": (True, True, True, True, False, True, True),
    "-": (False, False, False, False, False, False, True),
}


def face_for_humidity(humidity: Optional[float]) -> str:
    """舒適 (40~65%) 顯示笑臉，偏乾、偏濕各有不同表情。"""
    if humidity is None or humidity < 40:
        return "(-_-)"
    if humidity > 65:
        return "(>_<)"
    return "(^_^)"


def format_temperature(temp: Optional[float]) -> str:
    return "--.-" if temp is None else f"{temp:.1f}"


def format_humidity(hum: Optional[float]) -> str:
    return "--" if hum is None else f"{hum:.0f}"


def digit_units(char: str) -> float:
    """字元寬度 (以字高為 1)：小數點較窄。"""
    return 0.28 if char == "." else 0.62


def should_show_low_battery(percent: Optional[int]) -> bool:
    return percent is not None and percent <= 15


def _build_widget():
    import cairo
    import gi

    gi.require_version("Gtk", "3.0")
    from gi.repository import Gtk, Pango

    from .icons import layout_size, make_layout, show_layout

    INK = (0.13, 0.15, 0.14)
    LEAN = 0.12

    class DeviceView(Gtk.DrawingArea):
        def __init__(self, size: int = 48):
            super().__init__()
            self.set_size_request(size, size)
            self.temperature: Optional[float] = None
            self.humidity: Optional[float] = None
            self.battery_percent: Optional[int] = None
            self.connect("draw", self._on_draw)

        def set_reading(self, temperature: Optional[float], humidity: Optional[float], battery_percent: Optional[int]) -> None:
            self.temperature, self.humidity, self.battery_percent = temperature, humidity, battery_percent
            self.queue_draw()

        # MARK: - 繪製

        def _on_draw(self, _widget, cr: "cairo.Context") -> bool:
            w, h = self.get_allocated_width(), self.get_allocated_height()
            s = float(min(w, h))
            bx, by = (w - s) / 2 + s * 0.04, (h - s) / 2 + s * 0.04
            bs = s * 0.92

            # 機身 (投影 + 漸層 + 外框)
            self._rounded(cr, bx, by + s * 0.02, bs, bs, s * 0.2)
            cr.set_source_rgba(0, 0, 0, 0.30)
            cr.fill()
            self._rounded(cr, bx, by, bs, bs, s * 0.2)
            grad = cairo.LinearGradient(0, by, 0, by + bs)
            grad.add_color_stop_rgb(0, 1.0, 1.0, 1.0)
            grad.add_color_stop_rgb(1, 0.90, 0.90, 0.90)
            cr.set_source(grad)
            cr.fill_preserve()
            cr.set_source_rgb(0.78, 0.78, 0.78)
            cr.set_line_width(max(0.5, s * 0.01))
            cr.stroke()

            # LCD
            lx, ly = bx + bs * 0.14, by + bs * 0.14
            lw, lh = bs * 0.72, bs * 0.72
            self._rounded(cr, lx, ly, lw, lh, s * 0.04)
            lcd = cairo.LinearGradient(0, ly, 0, ly + lh)
            lcd.add_color_stop_rgb(0, 0.80, 0.83, 0.80)
            lcd.add_color_stop_rgb(1, 0.72, 0.76, 0.72)
            cr.set_source(lcd)
            cr.fill_preserve()
            cr.set_source_rgba(0.45, 0.45, 0.45, 0.7)
            cr.set_line_width(max(0.5, s * 0.008))
            cr.stroke()

            # 上排：溫度 (大) + °C
            temp_h = lh * 0.36
            temp_x, temp_y = lx + lw * 0.08, ly + lh * 0.20
            self._segments(cr, format_temperature(self.temperature), temp_x, temp_y, lw * 0.72, temp_h)
            self._text(cr, "°C", temp_x + lw * 0.74, temp_y, lh * 0.10, bold=True)

            # 下排：顏文字 + 濕度 + %
            row_h = lh * 0.22
            row_y = ly + lh * 0.66
            self._text(cr, face_for_humidity(self.humidity), lx + lw * 0.08, row_y + row_h * 0.15, lh * 0.11, mono=True)
            hum_x = lx + lw * 0.08 + lw * 0.84 * 0.42
            hum_w = lw * 0.84 * 0.40
            self._segments(cr, format_humidity(self.humidity), hum_x, row_y, hum_w, row_h, align_right=True)
            self._text(cr, "%", hum_x + hum_w + lw * 0.03, row_y + row_h * 0.35, lh * 0.09, bold=True)

            # 電量偏低時顯示電池圖示
            if should_show_low_battery(self.battery_percent):
                bw, bh = lw * 0.16, lh * 0.08
                bxx, byy = lx + lw * 0.08, ly + lh * 0.06
                cr.set_source_rgb(*INK)
                cr.set_line_width(max(0.5, s * 0.01))
                cr.rectangle(bxx, byy, bw, bh)
                cr.stroke()
                cr.rectangle(bxx, byy, bw * 0.25, bh)
                cr.fill()
            return False

        @staticmethod
        def _rounded(cr, x: float, y: float, w: float, h: float, r: float) -> None:
            cr.new_sub_path()
            cr.arc(x + w - r, y + r, r, -1.5708, 0)
            cr.arc(x + w - r, y + h - r, r, 0, 1.5708)
            cr.arc(x + r, y + h - r, r, 1.5708, 3.14159)
            cr.arc(x + r, y + r, r, 3.14159, 4.71239)
            cr.close_path()

        @staticmethod
        def _text(cr, text: str, x: float, y: float, size: float, bold: bool = False, mono: bool = False) -> None:
            if size < 3:
                return
            weight = Pango.Weight.BOLD if bold or mono else Pango.Weight.SEMIBOLD
            layout = make_layout(cr, text, size, weight)
            show_layout(cr, layout, x, y, INK)

        def _segments(self, cr, text: str, x: float, y: float, max_w: float, h: float, align_right: bool = False) -> None:
            natural = sum(digit_units(c) for c in text) * h
            scale = min(1.0, max(0.0, (max_w - h * LEAN)) / max(natural, 1.0))
            dh = h * scale
            total = sum(digit_units(c) for c in text) * dh
            cx = x + max_w - total if align_right else x
            cy = y + (h - dh) / 2
            t = dh * 0.14

            cr.save()
            # 實機 LCD 數字微傾斜 (以數字基線為基準向右傾)
            cr.transform(cairo.Matrix(1, 0, -LEAN, 1, LEAN * (cy + dh), 0))
            cr.set_source_rgb(*INK)
            for c in text:
                w = digit_units(c) * dh
                if c == ".":
                    d = t * 1.1
                    cr.rectangle(cx + (w - d) / 2, cy + dh - d, d, d)
                    cr.fill()
                elif c in SEGMENTS:
                    self._digit(cr, SEGMENTS[c], cx, cy, w * 0.86, dh, t)
                cx += w
            cr.restore()

        @staticmethod
        def _digit(cr, segs: Sequence[bool], x: float, y: float, w: float, h: float, t: float) -> None:
            half = h / 2
            top, mid, bot = y + t / 2, y + half, y + h - t / 2
            left, right = x + t / 2, x + w - t / 2

            def hseg(yy: float) -> None:
                x0, x1 = x + t * 0.6, x + w - t * 0.6
                cr.move_to(x0, yy)
                cr.line_to(x0 + t * 0.5, yy - t / 2)
                cr.line_to(x1 - t * 0.5, yy - t / 2)
                cr.line_to(x1, yy)
                cr.line_to(x1 - t * 0.5, yy + t / 2)
                cr.line_to(x0 + t * 0.5, yy + t / 2)
                cr.close_path()

            def vseg(xx: float, y0: float, y1: float) -> None:
                cr.move_to(xx, y0 + t * 0.35)
                cr.line_to(xx + t / 2, y0 + t * 0.85)
                cr.line_to(xx + t / 2, y1 - t * 0.85)
                cr.line_to(xx, y1 - t * 0.35)
                cr.line_to(xx - t / 2, y1 - t * 0.85)
                cr.line_to(xx - t / 2, y0 + t * 0.85)
                cr.close_path()

            shapes = (
                lambda: hseg(top), lambda: vseg(right, y, mid), lambda: vseg(right, mid, y + h),
                lambda: hseg(bot), lambda: vseg(left, mid, y + h), lambda: vseg(left, y, mid), lambda: hseg(mid),
            )
            for on, draw in zip(segs, shapes):
                if on:
                    draw()
                    cr.fill()

    return DeviceView


def create_device_view(size: int = 48):
    """延遲載入 GTK，讓純邏輯部分可在沒有 GTK 的環境測試。"""
    return _build_widget()(size)
