"""歷史趨勢折線圖 (Cairo)：綜合總覽雙 Y 軸、單一指標模式與滑鼠懸停提示。"""

import bisect
import math
from datetime import datetime
from enum import IntEnum
from typing import List, NamedTuple, Optional, Sequence, Tuple

import cairo
import gi

gi.require_version("Gdk", "3.0")
gi.require_version("Gtk", "3.0")
from gi.repository import Gdk, Gtk, Pango  # noqa: E402

from .history import HistoryPoint  # noqa: E402
from .icons import layout_size, make_layout, rounded_rect, show_layout  # noqa: E402

TEMP_COLOR = (1.0, 0.48, 0.12)  # 暖橙
HUM_COLOR = (0.05, 0.68, 1.0)   # 湛藍
VOLT_COLOR = (0.10, 0.88, 0.52)

Point = Tuple[float, float]

BAT_COLOR = (0.10, 0.88, 0.52)  # 翠綠 (電池電量)

# X 軸刻度可選間距 (秒)
_STEP_CANDIDATES = (600.0, 1800.0, 3600.0, 7200.0, 14400.0, 21600.0, 43200.0, 86400.0, 172800.0, 604800.0)


def choose_time_step(span: float, plot_width: float) -> float:
    """依時間跨度與繪圖寬度挑選刻度間距，讓標籤數量不超過寬度能容納的量 (約每 80px 一個)。"""
    max_labels = max(2.0, plot_width / 80.0)
    for step in _STEP_CANDIDATES:
        if span / step <= max_labels:
            return step
    return _STEP_CANDIDATES[-1]


def filter_recent(points: Sequence[HistoryPoint], seconds: Optional[float]) -> List[HistoryPoint]:
    """只保留最後一筆往前 seconds 秒內的點；seconds 為 None 表示全部。"""
    if seconds is None or not points:
        return list(points)
    cutoff = points[-1].timestamp - seconds
    return [p for p in points if p.timestamp >= cutoff]


class ChartDataType(IntEnum):
    OVERVIEW = 0
    TEMPERATURE = 1
    HUMIDITY = 2
    VOLTAGE = 3


class Rect(NamedTuple):
    x: float
    y: float
    w: float
    h: float

    @property
    def right(self) -> float:
        return self.x + self.w

    @property
    def bottom(self) -> float:
        return self.y + self.h

    def contains(self, px: float, py: float) -> bool:
        return self.x <= px <= self.right and self.y <= py <= self.bottom


class ChartView(Gtk.DrawingArea):
    def __init__(self):
        super().__init__()
        self._data_type = ChartDataType.OVERVIEW
        self._all_points: List[HistoryPoint] = []
        self._time_range: Optional[float] = None
        self.points: List[HistoryPoint] = []
        self._timestamps: List[float] = []
        self.hovered_point: Optional[HistoryPoint] = None

        self.add_events(Gdk.EventMask.POINTER_MOTION_MASK | Gdk.EventMask.LEAVE_NOTIFY_MASK)
        self.connect("draw", self._on_draw)
        self.connect("motion-notify-event", self._on_motion)
        self.connect("leave-notify-event", self._on_leave)

    @property
    def data_type(self) -> ChartDataType:
        return self._data_type

    @data_type.setter
    def data_type(self, value: ChartDataType) -> None:
        self._data_type = value
        self.queue_draw()

    @property
    def time_range(self) -> Optional[float]:
        return self._time_range

    @time_range.setter
    def time_range(self, seconds: Optional[float]) -> None:
        self._time_range = seconds
        self._apply_range()

    def update_points(self, points: Sequence[HistoryPoint]) -> None:
        self._all_points = list(points)
        self._apply_range()

    def _apply_range(self) -> None:
        self.points = filter_recent(self._all_points, self._time_range)
        self._timestamps = [p.timestamp for p in self.points]
        self.hovered_point = None
        self.queue_draw()

    def _graph_rect(self, width: float, height: float) -> Rect:
        is_overview = self._data_type == ChartDataType.OVERVIEW
        return Rect(58.0, 20.0, width - (118.0 if is_overview else 82.0), height - 54.0)

    def _time_span(self) -> Tuple[float, float]:
        start = self.points[0].timestamp
        return start, max(60.0, self.points[-1].timestamp - start)

    @staticmethod
    def _x_for(timestamp: float, start: float, span: float, rect: Rect) -> float:
        ratio = max(0.0, min(1.0, (timestamp - start) / span))
        return rect.x + ratio * rect.w

    # MARK: - 滑鼠懸停

    def _on_motion(self, _widget, event) -> bool:
        if len(self.points) < 2:
            return False
        rect = self._graph_rect(self.get_allocated_width(), self.get_allocated_height())

        if rect.contains(event.x, event.y):
            start, span = self._time_span()
            target = start + (event.x - rect.x) / rect.w * span
            # 以二分搜尋找出時間最接近的點
            i = bisect.bisect_left(self._timestamps, target)
            candidates = [self.points[j] for j in (i - 1, i) if 0 <= j < len(self.points)]
            nearest = min(candidates, key=lambda p: abs(p.timestamp - target))
            if nearest is not self.hovered_point:
                self.hovered_point = nearest
                self.queue_draw()
        elif self.hovered_point is not None:
            self.hovered_point = None
            self.queue_draw()
        return False

    def _on_leave(self, _widget, _event) -> bool:
        self.hovered_point = None
        self.queue_draw()
        return False

    # MARK: - 繪製

    def _on_draw(self, _widget, cr: cairo.Context) -> bool:
        width = self.get_allocated_width()
        height = self.get_allocated_height()

        rounded_rect(cr, 0.5, 0.5, width - 1, height - 1, 14)
        cr.set_source_rgba(0.08, 0.09, 0.12, 0.95)
        cr.fill_preserve()
        cr.set_source_rgba(1, 1, 1, 0.08)
        cr.set_line_width(1.0)
        cr.stroke()

        rect = self._graph_rect(width, height)

        if not self.points:
            layout = make_layout(cr, "尚無採樣數據，設備連線後將自動繪製...", 13, Pango.Weight.MEDIUM)
            w, h = layout_size(layout)
            show_layout(cr, layout, (width - w) / 2, (height - h) / 2, (0.5, 0.5, 0.5))
            return False

        start, span = self._time_span()
        self._draw_x_axis(cr, rect, height, start, span)
        if self._data_type == ChartDataType.OVERVIEW:
            self._draw_overview(cr, rect, start, span)
        else:
            self._draw_single(cr, rect, start, span)
        return False

    def _draw_x_axis(self, cr: cairo.Context, rect: Rect, height: float, start: float, span: float) -> None:
        """X 軸整點時間刻度與垂直參考線 (基於真實時間分佈)。"""
        end = self.points[-1].timestamp
        label_color = (0.55, 0.55, 0.55)

        step = choose_time_step(span, rect.w)
        label_format = "%m/%d" if step >= 86400 else "%H:%M"

        # 對齊到最近的整點時間
        base = datetime.fromtimestamp(start).replace(minute=0, second=0, microsecond=0)
        if step >= 86400:
            base = base.replace(hour=0)
        current = base.timestamp()
        while current < start:
            current += step

        def draw_label(text: str, x: float, align: str) -> Tuple[float, float]:
            layout = make_layout(cr, text, 10.5, tabular=True)
            w, h = layout_size(layout)
            lx = {"center": x - w / 2, "left": x, "right": x - w}[align]
            show_layout(cr, layout, lx, height - 12 - h, label_color)
            return lx, lx + w

        # 始末兩端時間標記
        _, start_label_right = draw_label(datetime.fromtimestamp(start).strftime("%H:%M"), rect.x, "left")
        end_label_left, _ = draw_label(datetime.fromtimestamp(end).strftime("%H:%M"), rect.right, "right")

        cr.set_line_width(1.0)
        while current <= end:
            ratio = (current - start) / span
            if 0.12 <= ratio <= 0.88:
                x = rect.x + ratio * rect.w
                cr.set_source_rgba(1, 1, 1, 0.06)
                cr.set_dash([4, 4])
                cr.move_to(x, rect.y)
                cr.line_to(x, rect.bottom)
                cr.stroke()
                text = datetime.fromtimestamp(current).strftime(label_format)
                w, _ = layout_size(make_layout(cr, text, 10.5, tabular=True))
                # 避免與始末兩端的時間標記重疊
                if x - w / 2 > start_label_right + 6 and x + w / 2 < end_label_left - 6:
                    draw_label(text, x, "center")
            current += step
        cr.set_dash([])

    def _draw_grid_line(self, cr: cairo.Context, rect: Rect, y: float) -> None:
        cr.set_source_rgba(1, 1, 1, 0.07)
        cr.set_line_width(1.0)
        cr.set_dash([4, 4])
        cr.move_to(rect.x, y)
        cr.line_to(rect.right, y)
        cr.stroke()
        cr.set_dash([])

    def _draw_overview(self, cr: cairo.Context, rect: Rect, start: float, span: float) -> None:
        """綜合總覽模式 (雙 Y 軸)。"""
        temps = [p.temperature for p in self.points]
        hums = [p.humidity for p in self.points]
        bats = [float(p.batteryPercent) for p in self.points]

        min_t = math.floor(min(temps) * 2.0) / 2.0 - 0.5
        max_t = math.ceil(max(temps) * 2.0) / 2.0 + 0.5
        min_h = max(0.0, math.floor(min(hums + bats) / 5.0) * 5.0 - 5.0)
        max_h = min(100.0, math.ceil(max(hums + bats) / 5.0) * 5.0 + 5.0)

        def y_t(v: float) -> float:
            return rect.bottom - (v - min_t) / (max_t - min_t) * rect.h

        def y_h(v: float) -> float:
            return rect.bottom - (v - min_h) / (max_h - min_h) * rect.h

        # 1. 水平參考線與雙 Y 軸刻度
        grid_lines = 4
        for i in range(grid_lines + 1):
            ratio = i / grid_lines
            y = rect.bottom - ratio * rect.h
            self._draw_grid_line(cr, rect, y)

            lt = make_layout(cr, f"{min_t + ratio * (max_t - min_t):.1f}°", 10, Pango.Weight.BOLD, tabular=True)
            w, h = layout_size(lt)
            show_layout(cr, lt, rect.x - w - 14, y - h / 2, TEMP_COLOR)

            lh = make_layout(cr, f"{min_h + ratio * (max_h - min_h):.0f}%", 10, Pango.Weight.BOLD, tabular=True)
            w, h = layout_size(lh)
            show_layout(cr, lh, rect.right + 14, y - h / 2, HUM_COLOR)

        # 2. 基於真實時間計算座標點 (X 嚴格單調遞增，永不折返交叉)
        xs = [self._x_for(p.timestamp, start, span, rect) for p in self.points]
        coords_t = [(x, y_t(p.temperature)) for x, p in zip(xs, self.points)]
        coords_h = [(x, y_h(p.humidity)) for x, p in zip(xs, self.points)]
        coords_b = [(x, y_h(float(p.batteryPercent))) for x, p in zip(xs, self.points)]

        # 3. 底部光暈與主折線
        self._draw_gradient_area(cr, coords_b, rect.bottom, BAT_COLOR, 0.10)
        self._draw_gradient_area(cr, coords_t, rect.bottom, TEMP_COLOR, 0.18)
        self._draw_gradient_area(cr, coords_h, rect.bottom, HUM_COLOR, 0.18)
        self._draw_line(cr, coords_b, BAT_COLOR, 2.2)
        self._draw_line(cr, coords_t, TEMP_COLOR, 2.4)
        self._draw_line(cr, coords_h, HUM_COLOR, 2.4)

        # 4. 圖例
        for text, x, color in (("● 溫度 (°C)", rect.x + 4, TEMP_COLOR), ("● 濕度 (%)", rect.x + 85, HUM_COLOR),
                              ("● 電量 (%)", rect.x + 166, BAT_COLOR)):
            layout = make_layout(cr, text, 11, Pango.Weight.BOLD)
            _, h = layout_size(layout)
            show_layout(cr, layout, x, rect.y - 4 - h, color)

        # 5. 懸停提示
        p = self.hovered_point
        if p is not None:
            x = self._x_for(p.timestamp, start, span, rect)
            yt, yh, yb = y_t(p.temperature), y_h(p.humidity), y_h(float(p.batteryPercent))
            self._draw_crosshair(cr, x, rect)
            self._draw_glow_dot(cr, x, yb, BAT_COLOR)
            self._draw_glow_dot(cr, x, yh, HUM_COLOR)
            self._draw_glow_dot(cr, x, yt, TEMP_COLOR)
            text = (f"{datetime.fromtimestamp(p.timestamp):%H:%M:%S}  ·  溫度 {p.temperature:.1f}°C"
                    f"   濕度 {p.humidity:.0f}%   電量 {p.batteryPercent}%")
            self._draw_tooltip(cr, text, x, min(yt, yh, yb) - 14, rect)

    def _draw_single(self, cr: cairo.Context, rect: Rect, start: float, span: float) -> None:
        """單一指標模式 (溫度 / 濕度 / 電壓)。"""
        if self._data_type == ChartDataType.TEMPERATURE:
            values = [p.temperature for p in self.points]
            color, fmt = TEMP_COLOR, "{:.1f}°"
            span_min, pad_ratio = 0.8, 0.12
        elif self._data_type == ChartDataType.HUMIDITY:
            values = [p.humidity for p in self.points]
            color, fmt = HUM_COLOR, "{:.0f}%"
            span_min, pad_ratio = 3.0, 0.12
        else:
            values = [p.voltage for p in self.points]
            color, fmt = VOLT_COLOR, "{:.3f}V"
            span_min, pad_ratio = 0.02, 0.15

        raw_min, raw_max = min(values), max(values)
        pad = max(span_min, raw_max - raw_min) * pad_ratio
        min_v, max_v = raw_min - pad, raw_max + pad
        if self._data_type == ChartDataType.HUMIDITY:
            min_v, max_v = max(0.0, min_v), min(100.0, max_v)

        def y_for(v: float) -> float:
            return rect.bottom - (v - min_v) / (max_v - min_v) * rect.h

        # 1. 水平參考線與 Y 軸標籤
        grid_lines = 4
        for i in range(grid_lines + 1):
            ratio = i / grid_lines
            y = rect.bottom - ratio * rect.h
            self._draw_grid_line(cr, rect, y)
            layout = make_layout(cr, fmt.format(min_v + ratio * (max_v - min_v)), 10, Pango.Weight.SEMIBOLD, tabular=True)
            w, h = layout_size(layout)
            show_layout(cr, layout, rect.x - w - 14, y - h / 2, (0.6, 0.6, 0.6))

        # 2~3. 基於時間計算座標、漸層區域與主線
        coords = [(self._x_for(p.timestamp, start, span, rect), y_for(v)) for p, v in zip(self.points, values)]
        self._draw_gradient_area(cr, coords, rect.bottom, color, 0.25)
        self._draw_line(cr, coords, color, 2.6)

        # 4. 懸停提示
        p = self.hovered_point
        if p is not None:
            x = self._x_for(p.timestamp, start, span, rect)
            time_str = f"{datetime.fromtimestamp(p.timestamp):%H:%M:%S}"
            if self._data_type == ChartDataType.TEMPERATURE:
                value, text = p.temperature, f"{time_str}  ·  溫度 {p.temperature:.1f} °C"
            elif self._data_type == ChartDataType.HUMIDITY:
                value, text = p.humidity, f"{time_str}  ·  濕度 {p.humidity:.0f} %"
            else:
                value, text = p.voltage, f"{time_str}  ·  電壓 {p.voltage:.3f} V ({p.batteryPercent}%)"
            y = y_for(value)
            self._draw_crosshair(cr, x, rect)
            self._draw_glow_dot(cr, x, y, color)
            self._draw_tooltip(cr, text, x, y - 14, rect)

    # MARK: - 精確折線與漸層渲染

    @staticmethod
    def _trace(cr: cairo.Context, coords: Sequence[Point]) -> None:
        cr.move_to(*coords[0])
        for pt in coords[1:]:
            cr.line_to(*pt)

    def _draw_line(self, cr: cairo.Context, coords: Sequence[Point], color, line_width: float) -> None:
        if len(coords) < 2:
            return
        cr.save()
        cr.set_line_cap(cairo.LINE_CAP_ROUND)
        cr.set_line_join(cairo.LINE_JOIN_ROUND)
        # Cairo 沒有陰影模糊，以兩層加寬的半透明線條模擬霓虹光暈
        for extra, alpha in ((6.0, 0.10), (3.0, 0.18), (0.0, 1.0)):
            self._trace(cr, coords)
            cr.set_source_rgba(*color, alpha)
            cr.set_line_width(line_width + extra)
            cr.stroke()
        cr.restore()

    def _draw_gradient_area(self, cr: cairo.Context, coords: Sequence[Point], bottom: float, color, alpha: float) -> None:
        if len(coords) < 2:
            return
        # 多邊形嚴格封閉：左底角 -> 沿折線 -> 右底角 -> 閉合
        cr.save()
        cr.move_to(coords[0][0], bottom)
        for pt in coords:
            cr.line_to(*pt)
        cr.line_to(coords[-1][0], bottom)
        cr.close_path()
        cr.clip()

        gradient = cairo.LinearGradient(0, bottom - 180, 0, bottom)
        gradient.set_extend(cairo.EXTEND_NONE)
        gradient.add_color_stop_rgba(0.0, 0.1, 0.1, 0.1, 0.0)
        gradient.add_color_stop_rgba(1.0, *color, alpha)
        cr.set_source(gradient)
        cr.paint()
        cr.restore()

    @staticmethod
    def _draw_crosshair(cr: cairo.Context, x: float, rect: Rect) -> None:
        cr.set_source_rgba(1, 1, 1, 0.35)
        cr.set_line_width(1.0)
        cr.set_dash([3, 3])
        cr.move_to(x, rect.y)
        cr.line_to(x, rect.bottom)
        cr.stroke()
        cr.set_dash([])

    @staticmethod
    def _draw_glow_dot(cr: cairo.Context, x: float, y: float, color) -> None:
        cr.set_source_rgb(*color)
        cr.arc(x, y, 5, 0, 2 * math.pi)
        cr.fill()
        cr.set_source_rgb(1, 1, 1)
        cr.arc(x, y, 2.5, 0, 2 * math.pi)
        cr.fill()

    def _draw_tooltip(self, cr: cairo.Context, text: str, x: float, anchor_bottom: float, rect: Rect) -> None:
        layout = make_layout(cr, text, 11.5, Pango.Weight.BOLD, tabular=True)
        tw, th = layout_size(layout)
        bw, bh = tw + 20.0, 26.0
        bx = max(rect.x + 4, min(rect.right - bw - 4, x - bw / 2))
        by = max(rect.y + 4, min(rect.bottom - 4 - bh, anchor_bottom - bh))

        rounded_rect(cr, bx, by + 2, bw, bh, 7)
        cr.set_source_rgba(0, 0, 0, 0.35)
        cr.fill()

        rounded_rect(cr, bx, by, bw, bh, 7)
        cr.set_source_rgba(0.12, 0.14, 0.18, 0.95)
        cr.fill_preserve()
        cr.set_source_rgba(1, 1, 1, 0.20)
        cr.set_line_width(1.0)
        cr.stroke()

        show_layout(cr, layout, bx + 10, by + (bh - th) / 2, (1, 1, 1))
