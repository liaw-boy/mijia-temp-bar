import AppKit

/// 單一實例保護：以檔案鎖確保同時只有一個 MijiaTempBar 在跑
/// (例如手動加過登入項目又開啟「登入時自動啟動」，或用 open -n 重複開啟)。
enum SingleInstance {
    private static var lockFD: Int32 = -1

    /// 取得鎖；已有另一個在執行時回傳 false。無法建立鎖檔時不阻擋啟動。
    static func acquire() -> Bool {
        let path = AppPaths.supportDir.appendingPathComponent("instance.lock").path
        let fd = open(path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { return true }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            close(fd)
            return false
        }
        lockFD = fd  // 保持開啟直到程式結束，系統會自動釋放
        return true
    }

    static func activateOtherInstance() {
        guard let id = Bundle.main.bundleIdentifier else { return }
        let me = ProcessInfo.processInfo.processIdentifier
        NSRunningApplication.runningApplications(withBundleIdentifier: id)
            .first { $0.processIdentifier != me }?
            .activate(options: [])
    }
}
