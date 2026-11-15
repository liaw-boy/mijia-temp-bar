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

// 同時只允許一個實例 (避免兩個程式搶同一台溫濕度計的藍牙連線)
guard SingleInstance.acquire() else {
    mijiaLog("已有另一個 MijiaTempBar 在執行，這個實例直接結束")
    SingleInstance.activateOtherInstance()
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)

// 舊版單一裝置設定 → 裝置清單 (只新增資料，不覆寫舊檔與舊設定)
let deviceStore = DeviceStore(store: UserDefaults.standard,
                              historyDir: HistoryManager.historyDir,
                              legacyHistory: HistoryManager.legacyURL)
do {
    try Migration.run(store: UserDefaults.standard, deviceStore: deviceStore, logFile: AppPaths.logFile)
} catch {
    mijiaLog("遷移失敗，下次啟動會再試: \(error.localizedDescription)")
}

mijiaLog("MijiaTempBar 正在啟動，建立 StatusBarController...")
let controller = StatusBarController(deviceStore: deviceStore)
delegate.statusBarController = controller

mijiaLog("進入 NSApplication 主迴圈...")
app.run()
