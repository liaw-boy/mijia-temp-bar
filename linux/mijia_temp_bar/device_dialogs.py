"""裝置相關視窗：搜尋新裝置 (掃描 → 勾選加入)、重新命名、移除確認。"""

import time
from typing import Callable, Collection, List, Optional, Tuple

import gi

gi.require_version("Gtk", "3.0")
from gi.repository import GLib, Gtk, Pango  # noqa: E402

from .devices import MAX_NAME_LENGTH  # noqa: E402
from .discovery import Candidate, candidate_label, new_candidates  # noqa: E402

PROGRESS_TICK_MS = 200
NOTHING_FOUND_HINT = (
    "沒有找到新的溫濕度計。請確認溫濕度計在電腦附近、電池有電，"
    "而且沒有被手機米家 App 等其他裝置連線佔用。"
)


def ask_rename(parent: Optional[Gtk.Window], current: str) -> Optional[str]:
    """輸入新名稱；取消回傳 None (名稱合法性由呼叫端檢查)。"""
    dialog = Gtk.MessageDialog(transient_for=parent, modal=True, message_type=Gtk.MessageType.QUESTION,
                               buttons=Gtk.ButtonsType.NONE, text="重新命名裝置")
    dialog.format_secondary_text(f"例如「客廳」「臥室」，最多 {MAX_NAME_LENGTH} 個字。")
    dialog.add_buttons("取消", Gtk.ResponseType.CANCEL, "確定", Gtk.ResponseType.OK)
    dialog.set_default_response(Gtk.ResponseType.OK)
    dialog.set_keep_above(True)

    entry = Gtk.Entry()
    entry.set_text(current)
    entry.set_max_length(MAX_NAME_LENGTH)
    entry.set_activates_default(True)
    dialog.get_message_area().pack_start(entry, False, False, 0)
    entry.show()

    response = dialog.run()
    text = entry.get_text()
    dialog.destroy()
    return text if response == Gtk.ResponseType.OK else None


def confirm_remove(parent: Optional[Gtk.Window], name: str) -> bool:
    dialog = Gtk.MessageDialog(transient_for=parent, modal=True, message_type=Gtk.MessageType.WARNING,
                               buttons=Gtk.ButtonsType.NONE, text=f"移除「{name}」？")
    dialog.format_secondary_text("只會從清單移除，這台的歷史紀錄檔會保留在電腦上；之後重新加入即可看到原本的紀錄。")
    dialog.add_buttons("取消", Gtk.ResponseType.CANCEL, "移除", Gtk.ResponseType.OK)
    dialog.set_default_response(Gtk.ResponseType.CANCEL)
    dialog.set_keep_above(True)
    response = dialog.run()
    dialog.destroy()
    return response == Gtk.ResponseType.OK


def show_error(parent: Optional[Gtk.Window], title: str, message: str) -> None:
    dialog = Gtk.MessageDialog(transient_for=parent, modal=True, message_type=Gtk.MessageType.ERROR,
                               buttons=Gtk.ButtonsType.OK, text=title)
    dialog.format_secondary_text(message)
    dialog.set_keep_above(True)
    dialog.run()
    dialog.destroy()


class DiscoveryDialog(Gtk.Dialog):
    """兩階段：掃描中 (進度條) → 勾選清單。關閉視窗即取消搜尋。"""

    RESPONSE_ADD = 1
    RESPONSE_RETRY = 2

    def __init__(self, existing_ids: Callable[[], Collection[str]], duration: float,
                 on_add: Callable[[List[Candidate]], None], on_retry: Callable[[], None],
                 on_closed: Callable[[], None]):
        super().__init__(title="搜尋新裝置")
        self.set_default_size(520, -1)
        self.set_keep_above(True)
        self.set_position(Gtk.WindowPosition.CENTER)
        self._existing_ids = existing_ids
        self._duration = duration
        self._on_add = on_add
        self._on_retry = on_retry
        self._on_closed = on_closed
        self._checks: List[Tuple[Gtk.CheckButton, Candidate]] = []
        self._started = 0.0
        self._tick_source: Optional[int] = None

        # 自己的內容盒子：對話框的內容區也包含按鈕列，清空時不能動到它
        self._body = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=10)
        for side in ("start", "end", "top", "bottom"):
            getattr(self._body, f"set_margin_{side}")(16)
        self.get_content_area().pack_start(self._body, True, True, 0)
        self.connect("response", self._handle_response)
        self.connect("destroy", self._handle_destroy)

    # MARK: - 階段一：掃描中

    def show_searching(self) -> None:
        self._clear()
        row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=10)
        spinner = Gtk.Spinner()
        spinner.start()
        row.pack_start(spinner, False, False, 0)
        row.pack_start(Gtk.Label(label=f"正在搜尋附近的溫濕度計… (約 {int(self._duration)} 秒)", xalign=0), True, True, 0)
        self._body.pack_start(row, False, False, 0)

        self._progress = Gtk.ProgressBar()
        self._body.pack_start(self._progress, False, False, 0)
        self._count_label = Gtk.Label(label="等待目前的連線結束後開始掃描…", xalign=0)
        self._body.pack_start(self._count_label, False, False, 0)

        self.add_button("取消", Gtk.ResponseType.CANCEL)
        self._started = time.monotonic()
        self._tick_source = GLib.timeout_add(PROGRESS_TICK_MS, self._tick)
        self.show_all()
        self.present()

    def _tick(self) -> bool:
        fraction = (time.monotonic() - self._started) / max(self._duration, 1.0)
        self._progress.set_fraction(min(1.0, fraction))
        return GLib.SOURCE_CONTINUE

    def update(self, candidates: List[Candidate]) -> None:
        """掃描中的進度回報 (GTK 主執行緒)。"""
        if self._tick_source is None:
            return
        count = len(new_candidates(candidates, self._existing_ids()))
        self._count_label.set_text(f"已找到 {count} 台尚未加入的溫濕度計")

    # MARK: - 階段二：勾選清單

    def finish(self, candidates: List[Candidate]) -> None:
        self._stop_tick()
        self._clear()
        fresh = new_candidates(candidates, self._existing_ids())
        if not fresh:
            label = Gtk.Label(label=NOTHING_FOUND_HINT, xalign=0)
            label.set_line_wrap(True)
            self._body.pack_start(label, False, False, 0)
            self.add_button("重新搜尋", self.RESPONSE_RETRY)
            self.add_button("關閉", Gtk.ResponseType.CLOSE)
        else:
            self._body.pack_start(Gtk.Label(label="勾選要加入的溫濕度計 (訊號越強越靠近)：", xalign=0), False, False, 0)
            for candidate in fresh:
                check = Gtk.CheckButton(label=candidate_label(candidate))
                check.get_child().set_ellipsize(Pango.EllipsizeMode.END)
                check.set_active(len(fresh) == 1)
                self._body.pack_start(check, False, False, 0)
                self._checks.append((check, candidate))
            self.add_button("重新搜尋", self.RESPONSE_RETRY)
            self.add_button("取消", Gtk.ResponseType.CANCEL)
            self.add_button("加入所選", self.RESPONSE_ADD)
            self.set_default_response(self.RESPONSE_ADD)
        self.show_all()
        self.present()

    # MARK: - 事件

    def _handle_response(self, _dialog, response: int) -> None:
        if response == self.RESPONSE_ADD:
            chosen = [candidate for check, candidate in self._checks if check.get_active()]
            self.destroy()
            if chosen:
                self._on_add(chosen)
        elif response == self.RESPONSE_RETRY:
            self._on_retry()
        else:
            self.destroy()

    def _handle_destroy(self, _widget) -> None:
        self._stop_tick()
        self._on_closed()

    def _stop_tick(self) -> None:
        if self._tick_source is not None:
            GLib.source_remove(self._tick_source)
            self._tick_source = None

    def _clear(self) -> None:
        self._checks = []
        for child in self._body.get_children():
            child.destroy()
        for button in self.get_action_area().get_children():
            button.destroy()
