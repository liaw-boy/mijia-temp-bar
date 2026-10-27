import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    var statusBarController: StatusBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        mijiaLog("applicationDidFinishLaunching 觸發，確保常駐模式生效...")
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // 使用者如果在桌面點擊 App 圖示，暫時喚起狀態列顯示
        statusBarController?.temporarilyShowStatusItem()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        mijiaLog("MijiaTempBar 正在退出...")
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)

mijiaLog("MijiaTempBar 正在啟動，建立 StatusBarController...")
let controller = StatusBarController()
delegate.statusBarController = controller

mijiaLog("進入 NSApplication 主迴圈...")
app.run()
