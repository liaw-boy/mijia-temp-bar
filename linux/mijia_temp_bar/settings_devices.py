"""儀表板「設定」分頁的「裝置」區塊：每台一列 (設為主裝置／改名／移除)，最後一列搜尋新裝置。"""

from typing import Dict

import gi

gi.require_version("Gtk", "3.0")
from gi.repository import Gtk  # noqa: E402

from .device_state import summary_text  # noqa: E402
from .devices import KIND_TITLES, Device  # noqa: E402


class DevicesSection:
    def __init__(self, dashboard, page: Gtk.Box):
        self.dashboard = dashboard
        self.controller = dashboard.controller
        self.card = dashboard._section(page, "裝置")
        self._captions: Dict[str, Gtk.Label] = {}

    def reload(self) -> None:
        """裝置清單變動時重建整個區塊。"""
        for child in self.card.get_children():
            child.destroy()
        self._captions = {}
        for device in self.controller.devices:
            self._add_device_row(device)
        self.dashboard._add_row(
            self.card, "搜尋新裝置", "掃描附近約 20 秒，勾選後加入；不會自動加入別人的溫濕度計。",
            [self._button("搜尋…", self.controller.open_discovery)],
        )
        self.card.show_all()

    def _add_device_row(self, device: Device) -> None:
        c = self.controller
        is_primary = device.id == c.primary_id
        controls = []
        if not is_primary:
            controls.append(self._button("設為狀態列", lambda: c.set_primary(device.id)))
        controls.append(self._button("改名", lambda: self.dashboard.run_busy(
            lambda: c.rename_device(device.id, self.dashboard))))
        controls.append(self._button("移除", lambda: self.dashboard.run_busy(
            lambda: c.remove_device(device.id, self.dashboard))))
        title = f"{device.name}  (狀態列)" if is_primary else device.name
        self.dashboard._add_row(self.card, title, self._caption_text(device), controls)
        self._captions[device.id] = self.dashboard._last_caption

    def _caption_text(self, device: Device) -> str:
        state = self.controller.state_for(device.id)
        summary = summary_text("", state).lstrip(" ·")
        return f"{device.id} · {KIND_TITLES.get(device.kind, device.kind)} · {summary}"

    def update_captions(self) -> None:
        """讀數或狀態更新時只改說明文字。"""
        for device in self.controller.devices:
            label = self._captions.get(device.id)
            if label is not None:
                text = self._caption_text(device)
                label.set_text(text)
                label.set_tooltip_text(text)

    @staticmethod
    def _button(label: str, callback) -> Gtk.Button:
        button = Gtk.Button(label=label)
        button.connect("clicked", lambda _b: callback())
        return button
