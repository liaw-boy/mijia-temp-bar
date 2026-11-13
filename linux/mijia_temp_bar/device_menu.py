"""系統匣選單：每台裝置一列 (主裝置打勾)，子選單可切換主裝置、改名、移除。

裝置清單變動時整份選單重建；收到讀數時只更新文字，避免選單開著時閃動。
"""

from typing import Callable, Dict, List, Optional, Tuple

import gi

gi.require_version("Gtk", "3.0")
from gi.repository import Gtk  # noqa: E402

from .device_state import DeviceState, summary_text  # noqa: E402
from .devices import KIND_STOCK, KIND_TITLES, Device  # noqa: E402

PRIMARY_MARK = "✓ "
OTHER_MARK = "　 "  # 全形空白，讓未打勾的名稱與打勾的對齊


def detail_lines(device: Device, state: DeviceState) -> List[str]:
    """子選單上方的唯讀資訊列。"""
    r = state.reading
    if r is not None:
        battery = f"電量: {r.battery_percent} % ({r.voltage:.2f}V)"
        updated = f"最後更新: {r.last_updated:%m/%d %H:%M:%S}" + (" (上次紀錄)" if state.cached else "")
    else:
        battery, updated = "電量: --", "最後更新: --"
    lines = [battery, updated]
    lines.append(f"狀態: {state.status}")
    lines.append(f"連線模式: {KIND_TITLES.get(device.kind, device.kind)}")
    lines.append(f"位址: {device.id}")
    return lines


def _item(menu: Gtk.Menu, label: str, callback: Optional[Callable[[], None]] = None) -> Gtk.MenuItem:
    item = Gtk.MenuItem.new_with_label(label)
    if callback is None:
        item.set_sensitive(False)
    else:
        item.connect("activate", lambda _item: callback())
    menu.append(item)
    return item


class DeviceMenu:
    def __init__(self, controller):
        self.controller = controller
        self._rows: Dict[str, Tuple[Gtk.MenuItem, List[Gtk.MenuItem]]] = {}

    def build(self) -> Tuple[Gtk.Menu, Gtk.MenuItem]:
        """建立整份選單，回傳 (選單, 「開啟儀表板」項目 — 給滑鼠中鍵使用)。"""
        c = self.controller
        menu = Gtk.Menu()
        self._rows = {}
        for device in c.devices:
            self._add_device_row(menu, device)
        if not c.devices:
            _item(menu, "尚未加入裝置")

        menu.append(Gtk.SeparatorMenuItem())
        _item(menu, "搜尋新裝置…", c.open_discovery)
        if any(d.kind == KIND_STOCK for d in c.devices):
            _item(menu, "全部立即更新", c.refresh_now)
        menu.append(Gtk.SeparatorMenuItem())
        open_dashboard = _item(menu, "開啟儀表板", c.show_dashboard)
        _item(menu, "結束 MijiaTempBar", c.app.quit)
        menu.show_all()
        return menu, open_dashboard

    def _add_device_row(self, menu: Gtk.Menu, device: Device) -> None:
        c = self.controller
        row = Gtk.MenuItem.new_with_label(self._row_label(device))
        submenu = Gtk.Menu()
        details = [_item(submenu, line) for line in detail_lines(device, c.state_for(device.id))]
        submenu.append(Gtk.SeparatorMenuItem())
        if device.id == c.primary_id:
            _item(submenu, "✓ 目前顯示在狀態列")
        else:
            _item(submenu, "顯示在狀態列", lambda: c.set_primary(device.id))
        if device.kind == KIND_STOCK:
            _item(submenu, "立即更新這台", lambda: c.refresh_now(device.id))
        _item(submenu, "重新命名…", lambda: c.rename_device(device.id))
        _item(submenu, "移除此裝置…", lambda: c.remove_device(device.id))
        row.set_submenu(submenu)
        menu.append(row)
        self._rows[device.id] = (row, details)

    def _row_label(self, device: Device) -> str:
        mark = PRIMARY_MARK if device.id == self.controller.primary_id else OTHER_MARK
        return mark + summary_text(device.name, self.controller.state_for(device.id))

    def update_labels(self) -> None:
        """讀數或狀態更新時只改文字 (資訊列行數固定，不必重建選單)。"""
        for device in self.controller.devices:
            row = self._rows.get(device.id)
            if row is None:
                continue
            item, details = row
            item.set_label(self._row_label(device))
            for detail, line in zip(details, detail_lines(device, self.controller.state_for(device.id))):
                detail.set_label(line)
