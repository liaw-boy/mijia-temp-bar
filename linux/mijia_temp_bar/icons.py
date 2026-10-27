"""狀態列影像 (Stats 雙行膠囊等樣式) 與 App 圖示的 Cairo / Pango 繪製。"""

import itertools
import math
import os
from pathlib import Path
from typing import List, Optional, Tuple

import cairo
import gi

gi.require_version("Pango", "1.0")
gi.require_version("PangoCairo", "1.0")
from gi.repository import Pango, PangoCairo  # noqa: E402

PANEL_HEIGHT = 24
PANEL_TEXT_COLOR = (1.0, 1.0, 1.0)  # GNOME 頂部面板為深色底

TEMP_BADGE_COLOR = (0.92, 0.35, 0.10)  # 熱能暖橙 #EA580C
HUM_BADGE_COLOR = (0.05, 0.55, 0.88)   # 濕度湛藍 #0284C7


# MARK: - 文字工具 (儀表板圖表也共用)

_ui_font_family: Optional[str] = None


def ui_font_family() -> str:
    """桌面環境的介面字型 (例如 Ubuntu Sans)，取不到時使用 Sans。"""
    global _ui_font_family
    if _ui_font_family is None:
        _ui_font_family = "Sans"
        try:
            gi.require_version("Gtk", "3.0")
            from gi.repository import Gtk
            settings = Gtk.Settings.get_default()
            if settings is not None:
                family = Pango.FontDescription.from_string(settings.props.gtk_font_name).get_family()
                if family:
                    _ui_font_family = family
        except (ImportError, ValueError):
            pass
    return _ui_font_family


_font_options = cairo.FontOptions()
_font_options.set_antialias(cairo.ANTIALIAS_GRAY)  # 透明底影像不能用次像素反鋸齒，否則字緣會出現彩邊
_font_options.set_hint_style(cairo.HINT_STYLE_SLIGHT)


def make_layout(cr: cairo.Context, text: str, size: float, weight: Pango.Weight = Pango.Weight.NORMAL,
                tabular: bool = False, family: Optional[str] = None) -> Pango.Layout:
    layout = PangoCairo.create_layout(cr)
    PangoCairo.context_set_font_options(layout.get_context(), _font_options)
    layout.context_changed()
    desc = Pango.FontDescription()
    desc.set_family(family or ui_font_family())
    desc.set_weight(weight)
    desc.set_absolute_size(size * Pango.SCALE)
    layout.set_font_description(desc)
    if tabular:
        attrs = Pango.AttrList()
        attrs.insert(Pango.attr_font_features_new("tnum"))
        layout.set_attributes(attrs)
    layout.set_text(text, -1)
    return layout


def layout_size(layout: Pango.Layout) -> Tuple[int, int]:
    _, logical = layout.get_pixel_extents()
    return logical.width, logical.height


def digit_center(layout: Pango.Layout) -> float:
    """數字字形的垂直中心 (相對於 layout 頂端)，用來把數字精準置中。"""
    probe = layout.copy()
    probe.set_attributes(None)
    probe.set_text("0", -1)
    ink, _ = probe.get_pixel_extents()
    return ink.y + ink.height / 2.0


def show_layout(cr: cairo.Context, layout: Pango.Layout, x: float, y: float, rgba) -> None:
    cr.save()
    cr.set_source_rgba(*rgba)
    cr.move_to(x, y)
    PangoCairo.show_layout(cr, layout)
    cr.restore()


def rounded_rect(cr: cairo.Context, x: float, y: float, w: float, h: float, r: float) -> None:
    r = min(r, w / 2.0, h / 2.0)
    cr.new_sub_path()
    cr.arc(x + w - r, y + r, r, -math.pi / 2, 0)
    cr.arc(x + w - r, y + h - r, r, 0, math.pi / 2)
    cr.arc(x + r, y + h - r, r, math.pi / 2, math.pi)
    cr.arc(x + r, y + r, r, math.pi, 3 * math.pi / 2)
    cr.close_path()


def _measure_context() -> cairo.Context:
    return cairo.Context(cairo.ImageSurface(cairo.FORMAT_ARGB32, 1, 1))


def _panel_surface(width: float) -> Tuple[cairo.ImageSurface, cairo.Context]:
    # 寬度至少為高度 1.5 倍，AppIndicator 擴充套件才會以原尺寸顯示 (不會被縮成正方形小圖示)
    w = max(int(math.ceil(width)), int(math.ceil(PANEL_HEIGHT * 1.5)) + 1)
    surface = cairo.ImageSurface(cairo.FORMAT_ARGB32, w, PANEL_HEIGHT)
    return surface, cairo.Context(surface)


# MARK: - 狀態列樣式

def render_stats_badge(temp: float, hum: float) -> cairo.ImageSurface:
    """如同 Stats / iStat Menus 風格的 [TMP] / [HUM] 雙行縮寫膠囊 (上下貼滿 24px)。"""
    top_val = f"{temp:.1f}°"
    bottom_val = f"{hum:.0f}%"

    badge_w, badge_h, badge_r, gap = 25.0, 10.5, 2.5, 4.5
    top_badge_y = 1.0
    bottom_badge_y = PANEL_HEIGHT - 1.0 - badge_h

    m = _measure_context()
    val_widths = [layout_size(make_layout(m, t, 11.2, Pango.Weight.BOLD, tabular=True))[0] for t in (top_val, bottom_val)]
    surface, cr = _panel_surface(1.0 + badge_w + gap + max(val_widths) + 1.5)

    for label, value, badge_y, color in (
        ("TMP", top_val, top_badge_y, TEMP_BADGE_COLOR),
        ("HUM", bottom_val, bottom_badge_y, HUM_BADGE_COLOR),
    ):
        center_y = badge_y + badge_h / 2.0

        rounded_rect(cr, 1.0, badge_y, badge_w, badge_h, badge_r)
        cr.set_source_rgb(*color)
        cr.fill()

        label_layout = make_layout(cr, label, 8.2, Pango.Weight.HEAVY)
        label_w, _ = layout_size(label_layout)
        show_layout(cr, label_layout, 1.0 + (badge_w - label_w) / 2.0, center_y - digit_center(label_layout), (1, 1, 1))

        val_layout = make_layout(cr, value, 11.2, Pango.Weight.BOLD, tabular=True)
        show_layout(cr, val_layout, 1.0 + badge_w + gap, center_y - digit_center(val_layout), PANEL_TEXT_COLOR)

    return surface


def render_stacked(temp: float, hum: float) -> cairo.ImageSurface:
    """純數字雙行堆疊 (上下吃滿版)。"""
    lines = (f"{temp:.1f}°", f"{hum:.0f}%")
    m = _measure_context()
    widths = [layout_size(make_layout(m, t, 11.0, Pango.Weight.BOLD, tabular=True))[0] for t in lines]
    surface, cr = _panel_surface(max(widths) + 6.0)
    total_w = surface.get_width()

    for text, center_y in zip(lines, (PANEL_HEIGHT * 0.25 + 0.5, PANEL_HEIGHT * 0.75 - 0.5)):
        layout = make_layout(cr, text, 11.0, Pango.Weight.BOLD, tabular=True)
        w, _ = layout_size(layout)
        show_layout(cr, layout, (total_w - w) / 2.0, center_y - digit_center(layout), PANEL_TEXT_COLOR)
    return surface


def render_text(text: str) -> cairo.ImageSurface:
    """單行文字樣式 (橫向完整 / 僅溫度 / 緊湊單行 / 狀態訊息)。"""
    m = _measure_context()
    w, _ = layout_size(make_layout(m, text, 13.5, Pango.Weight.BOLD, tabular=True))
    surface, cr = _panel_surface(w + 4.0)
    layout = make_layout(cr, text, 13.5, Pango.Weight.BOLD, tabular=True)
    lw, _ = layout_size(layout)
    show_layout(cr, layout, (surface.get_width() - lw) / 2.0, PANEL_HEIGHT / 2.0 - digit_center(layout), PANEL_TEXT_COLOR)
    return surface


class TrayIconWriter:
    """把影像寫成 PNG 給 AppIndicator 使用。

    AppIndicator 會依檔名快取圖示，因此每次更新都使用新檔名，並清掉較舊的檔案。
    """

    def __init__(self, directory: Path, keep: int = 3):
        self._dir = directory
        self._keep = keep
        self._counter = itertools.count()
        self._files: List[Path] = []
        directory.mkdir(parents=True, exist_ok=True)
        for old in directory.glob("tray-*.png"):
            old.unlink(missing_ok=True)

    def write(self, surface: cairo.ImageSurface) -> str:
        path = self._dir / f"tray-{os.getpid()}-{next(self._counter)}.png"
        surface.write_to_png(str(path))
        self._files.append(path)
        while len(self._files) > self._keep:
            self._files.pop(0).unlink(missing_ok=True)
        return str(path)


# MARK: - App 圖示 (移植自 generate_icon.swift 的 Google Stitch「Vibe Design」)

def _soft_shadow(cr: cairo.Context, x: float, y: float, w: float, h: float, r: float,
                 dy: float, blur: float, alpha: float) -> None:
    # Cairo 沒有內建陰影模糊：先在縮小的遮罩上畫出形狀，再以雙線性濾波放大，得到柔和邊緣
    k = max(1.0, blur)
    matrix = cr.get_matrix()
    width = int(math.ceil(cr.get_target().get_width() / k)) + 1
    height = int(math.ceil(cr.get_target().get_height() / k)) + 1
    mask = cairo.ImageSurface(cairo.FORMAT_A8, width, height)
    mcr = cairo.Context(mask)
    mcr.scale(1.0 / k, 1.0 / k)
    mcr.transform(matrix)
    rounded_rect(mcr, x, y + dy, w, h, r)
    mcr.fill()

    cr.save()
    cr.identity_matrix()
    cr.scale(k, k)
    pattern = cairo.SurfacePattern(mask)
    pattern.set_filter(cairo.FILTER_BILINEAR)
    cr.set_source_rgba(0.02, 0.03, 0.08, alpha)
    cr.mask(pattern)
    cr.restore()


def render_app_icon(px: int) -> cairo.ImageSurface:
    s = float(px)
    surface = cairo.ImageSurface(cairo.FORMAT_ARGB32, px, px)
    cr = cairo.Context(surface)
    # 以 CoreGraphics 座標系 (原點在左下、Y 軸向上) 繪製，與原版 Swift 腳本保持一致
    cr.translate(0, s)
    cr.scale(1, -1)

    pad = s * 0.095
    rx, ry, rw = pad, pad, s - pad * 2
    corner = rw * 0.225

    # 1. 外部柔和立體投影
    _soft_shadow(cr, rx, ry, rw, rw, corner, dy=-s * 0.03, blur=s * 0.06, alpha=0.65)

    # 2~3. 底板裁切 + 黑曜石漸層背景 (#131B2E -> #080A12)
    cr.save()
    rounded_rect(cr, rx, ry, rw, rw, corner)
    cr.clip()
    bg = cairo.LinearGradient(s * 0.1, s * 0.9, s * 0.9, s * 0.1)
    bg.add_color_stop_rgb(0.0, 0.08, 0.11, 0.18)
    bg.add_color_stop_rgb(1.0, 0.03, 0.04, 0.07)
    cr.set_source(bg)
    cr.paint()

    # 4. 微型點陣網格紋理
    step = rw / 10.0
    for xi in range(1, 10):
        for yi in range(1, 10):
            px_, py_ = rx + xi * step, ry + yi * step
            dist = math.hypot(px_ - s * 0.5, py_ - s * 0.5) / (s * 0.4)
            alpha = max(0.0, (1.0 - dist) * 0.10)
            if alpha > 0:
                cr.arc(px_, py_, s * 0.005, 0, math.pi * 2)
                cr.set_source_rgba(0.5, 0.65, 0.9, alpha)
                cr.fill()

    # 5. 暖橙 + 電光青雙向霓虹光暈
    for (cx, cy, radius, inner, outer) in (
        (0.35, 0.62, 0.38, (1.0, 0.35, 0.20, 0.35), (1.0, 0.20, 0.40, 0.0)),
        (0.65, 0.40, 0.40, (0.0, 0.85, 1.0, 0.30), (0.25, 0.40, 1.0, 0.0)),
    ):
        glow = cairo.RadialGradient(s * cx, s * cy, 0, s * cx, s * cy, s * radius)
        glow.add_color_stop_rgba(0.0, *inner)
        glow.add_color_stop_rgba(1.0, *outer)
        cr.set_source(glow)
        cr.paint()

    # 6. 懸浮氣候膠囊卡片
    card_w = s * 0.52
    card_x = (s - card_w) * 0.5
    card_y = (s - card_w) * 0.5 - s * 0.01
    card_r = card_w * 0.35
    _soft_shadow(cr, card_x, card_y, card_w, card_w, card_r, dy=-s * 0.02, blur=s * 0.045, alpha=0.55)
    rounded_rect(cr, card_x, card_y, card_w, card_w, card_r)
    cr.set_source_rgba(0.12, 0.15, 0.24, 0.75)
    cr.fill_preserve()
    cr.set_line_width(s * 0.016)
    cr.set_source_rgba(0.35, 0.60, 1.0, 0.35)
    cr.stroke()

    # 7. 雙環氣候指標 (左：溫度熱能環，右：濕度水漾環)
    icx, icy = card_x + card_w / 2, card_y + card_w / 2
    cr.set_line_width(s * 0.048)
    cr.set_line_cap(cairo.LINE_CAP_ROUND)
    cr.set_source_rgba(1.0, 0.40, 0.22, 0.95)
    cr.arc(icx - s * 0.04, icy + s * 0.03, s * 0.13, math.pi * 0.2, math.pi * 1.5)
    cr.stroke()
    cr.set_source_rgba(0.05, 0.88, 0.98, 0.95)
    cr.arc(icx + s * 0.04, icy - s * 0.03, s * 0.13, math.pi * 1.2, math.pi * 0.5)
    cr.stroke()

    # 7.3 中心平衡光點
    halo = cairo.RadialGradient(icx, icy, s * 0.015, icx, icy, s * 0.045)
    halo.add_color_stop_rgba(0.0, 1, 1, 1, 0.6)
    halo.add_color_stop_rgba(1.0, 1, 1, 1, 0.0)
    cr.set_source(halo)
    cr.arc(icx, icy, s * 0.045, 0, math.pi * 2)
    cr.fill()
    cr.set_source_rgba(1, 1, 1, 0.95)
    cr.arc(icx, icy, s * 0.022, 0, math.pi * 2)
    cr.fill()

    # 8. 角落十字標記
    mark, inset = s * 0.022, s * 0.16
    cr.set_line_width(s * 0.008)
    cr.set_line_cap(cairo.LINE_CAP_BUTT)
    cr.set_source_rgba(1, 1, 1, 0.22)
    for cx, cy in ((rx + inset, ry + inset), (rx + rw - inset, ry + inset),
                   (rx + inset, ry + rw - inset), (rx + rw - inset, ry + rw - inset)):
        cr.move_to(cx - mark / 2, cy)
        cr.line_to(cx + mark / 2, cy)
        cr.move_to(cx, cy - mark / 2)
        cr.line_to(cx, cy + mark / 2)
    cr.stroke()

    # 9. 頂層極細邊緣倒角光
    rounded_rect(cr, rx, ry, rw, rw, corner)
    cr.set_line_width(s * 0.014)
    cr.set_source_rgba(1, 1, 1, 0.18)
    cr.stroke()
    cr.restore()

    return surface


def save_app_icon(path: str, size: int = 256) -> None:
    Path(path).parent.mkdir(parents=True, exist_ok=True)
    render_app_icon(size).write_to_png(path)
