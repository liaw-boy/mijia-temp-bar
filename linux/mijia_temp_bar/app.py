"""GTK 應用程式生命週期與常駐 (單一實例) 模式進入點。"""

import signal
import sys

import gi
from gi.repository import GLib

from .settings import APP_DIR_NAME, APP_ID

# PyGObject 載入 Gtk 時就會初始化 GDK，程式名稱必須在這之前設定，
# 否則視窗的 WM_CLASS 會變成 "__main__.py"，桌面環境無法對應到 .desktop 圖示
GLib.set_prgname(APP_DIR_NAME)
GLib.set_application_name("米家溫濕度狀態列")

gi.require_version("Gtk", "3.0")
from gi.repository import Gtk  # noqa: E402

from .logger import mijia_log, setup_logging  # noqa: E402


class MijiaTempBarApp(Gtk.Application):
    def __init__(self):
        super().__init__(application_id=APP_ID)
        self.controller = None
        self._activated = False

    def do_startup(self):
        Gtk.Application.do_startup(self)
        Gtk.Settings.get_default().set_property("gtk-application-prefer-dark-theme", True)

        from .status_bar import StatusBarController

        mijia_log("MijiaTempBar 正在啟動，建立 StatusBarController...")
        # 沒有任何視窗時也保持常駐
        self.hold()
        self.controller = StatusBarController(self)

    def do_activate(self):
        # 第二次啟動 (例如從應用程式選單再點一次) 會轉送到已在執行的實例
        if self._activated and self.controller is not None:
            self.controller.handle_reopen()
        self._activated = True

    def do_shutdown(self):
        if self.controller is not None:
            self.controller.shutdown()
        Gtk.Application.do_shutdown(self)


def main(argv=None) -> int:
    setup_logging()
    app = MijiaTempBarApp()

    def quit_on_signal(*_args):
        app.quit()
        return GLib.SOURCE_REMOVE

    for sig in (signal.SIGINT, signal.SIGTERM):
        GLib.unix_signal_add(GLib.PRIORITY_DEFAULT, sig, quit_on_signal)

    mijia_log("進入 GTK 主迴圈...")
    return app.run(sys.argv if argv is None else argv)
