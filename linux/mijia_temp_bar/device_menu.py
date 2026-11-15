"""系統匣選單：第一層每台裝置一列，直接點就切換「狀態列顯示這台」(主裝置打勾)；
每台的詳細資訊與立即更新、改名、移除放在「管理裝置」子選單。

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
SHOWING_NOTE = "  (主裝置不在附近，狀態列顯示這台)"


def detail_lines(device: Device, state: DeviceState) -> List[str]:
    """「管理裝置」子選單中每台的唯讀資訊列 (行數固定，更新時只改文字)。"""
    r = state.reading
    if r is not None:
        battery = f"電量: {r.battery_percent} % ({r.voltage:.2f}V)"
        updated = f"最後更新: {r.last_updated:%m/%d %H:%M:%S}" + (" (上次紀錄)" if state.cached else "")
    else:
        battery, updated = "電量: --", "最後更新: --"
    return [battery, updated, f"狀態: {state.status}",
            f"連線模式: {KIND_TITLES.get(device.kind, device.kind)}", f"位址: {device.id}"]


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
        self._rows: Dict[str, Gtk.MenuItem] = {}
        self._manage_rows: Dict[str, Tuple[Gtk.MenuItem, List[Gtk.MenuItem]]] = {}

    def build(self) -> Tuple[Gtk.Menu, Gtk.MenuItem]:
        """建立整份選單，回傳 (選單, 「開啟儀表板」項目 — 給滑鼠中鍵使用)。"""
        c = self.controller
        menu = Gtk.Menu()
        self._rows, self._manage_rows = {}, {}
        for device in c.devices:
            self._rows[device.id] = _item(menu, self._row_label(device), lambda d=device: c.set_primary(d.id))
        if not c.devices:
            _item(menu, "尚未加入裝置")
        else:
            manage = Gtk.MenuItem.new_with_label("管理裝置")
            manage.set_submenu(self._build_manage_menu())
            menu.append(manage)

        menu.append(Gtk.SeparatorMenuItem())
        _item(menu, "搜尋新裝置…", c.open_discovery)
        if any(d.kind == KIND_STOCK for d in c.devices):
            _item(menu, "全部立即更新", c.refresh_now)
        menu.append(Gtk.SeparatorMenuItem())
        open_dashboard = _item(menu, "開啟儀表板", c.show_dashboard)
        _item(menu, "結束 MijiaTempBar", c.app.quit)
        menu.show_all()
        return menu, open_dashboard

    def _build_manage_menu(self) -> Gtk.Menu:
        c = self.controller
        menu = Gtk.Menu()
        for device in c.devices:
            row = Gtk.MenuItem.new_with_label(device.name)
            sub = Gtk.Menu()
            details = [_item(sub, line) for line in detail_lines(device, c.state_for(device.id))]
            sub.append(Gtk.SeparatorMenuItem())
            if device.kind == KIND_STOCK:
                _item(sub, "立即更新這台", lambda d=device: c.refresh_now(d.id))
            _item(sub, "重新命名…", lambda d=device: c.rename_device(d.id))
            _item(sub, "移除此裝置…", lambda d=device: c.remove_device(d.id))
            row.set_submenu(sub)
            menu.append(row)
            self._manage_rows[device.id] = (row, details)
        return menu

    def _row_label(self, device: Device) -> str:
        c = self.controller
        mark = PRIMARY_MARK if device.id == c.primary_id else OTHER_MARK
        note = SHOWING_NOTE if device.id == c.displayed_id and device.id != c.primary_id else ""
        return mark + summary_text(device.name, c.state_for(device.id)) + note

    def update_labels(self) -> None:
        """讀數或狀態更新時只改文字。"""
        for device in self.controller.devices:
            row = self._rows.get(device.id)
            if row is not None:
                row.set_label(self._row_label(device))
            manage = self._manage_rows.get(device.id)
            if manage is not None:
                for detail, line in zip(manage[1], detail_lines(device, self.controller.state_for(device.id))):
                    detail.set_label(line)
