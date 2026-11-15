import AppKit
import ServiceManagement

/// 登入時自動啟動：macOS 13 以上用系統內建登入項目 (SMAppService)；
/// macOS 12 改用 ~/Library/LaunchAgents 的設定檔 (開關只建立或移除這一個檔)。
enum LoginItemManager {
    enum State {
        case enabled
        case disabled
        case requiresApproval
        case unavailable(String)

        var isOn: Bool {
            switch self {
            case .enabled, .requiresApproval: return true
            default: return false
            }
        }

        var caption: String {
            switch self {
            case .enabled: return "已開啟：登入後自動在狀態列顯示。"
            case .disabled: return "登入後自動在狀態列顯示。"
            case .requiresApproval: return "請在「系統設定 > 一般 > 登入項目」允許 MijiaTempBar。"
            case .unavailable(let reason): return reason
            }
        }
    }

    private static var agentLabel: String { "\(Bundle.main.bundleIdentifier ?? "com.boywei.MijiaTempBar").login" }

    private static var agentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(agentLabel).plist")
    }

    /// App 不在「應用程式」資料夾 (或被系統暫時搬移) 時，登入項目會指到錯誤的位置
    static var bundleLocationProblem: String? {
        let path = Bundle.main.bundleURL.resolvingSymlinksInPath().path
        if path.contains("/AppTranslocation/") {
            return "App 正在系統暫時搬移的位置執行：請先把 MijiaTempBar.app 拖到「應用程式」資料夾再開啟。"
        }
        let userApps = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path + "/"
        if !path.hasPrefix("/Applications/") && !path.hasPrefix(userApps) {
            return "請先把 MijiaTempBar.app 放到「應用程式」資料夾再開啟，開機時才找得到它。"
        }
        return nil
    }

    static func currentState() -> State {
        if #available(macOS 13.0, *) {
            switch SMAppService.mainApp.status {
            case .enabled: return .enabled
            case .requiresApproval: return .requiresApproval
            // 從 macOS 12 升級上來時，舊的 LaunchAgent 檔仍會讓 App 自動啟動，要顯示為開啟才關得掉
            default: return FileManager.default.fileExists(atPath: agentURL.path) ? .enabled : .disabled
            }
        }
        return FileManager.default.fileExists(atPath: agentURL.path) ? .enabled : .disabled
    }

    /// 開啟或關閉；回傳結果狀態 (失敗時以 .unavailable 說明原因)。關閉永遠允許。
    @discardableResult
    static func setEnabled(_ enabled: Bool) -> State {
        if enabled, let problem = bundleLocationProblem {
            return .unavailable(problem)
        }
        if !enabled, case .disabled = currentState() {
            return .disabled
        }
        do {
            if #available(macOS 13.0, *) {
                try? setLaunchAgent(false)  // 從 macOS 12 升級上來時留下的舊設定檔，避免重複啟動
                if enabled {
                    try SMAppService.mainApp.register()
                } else if SMAppService.mainApp.status != .notRegistered {
                    try SMAppService.mainApp.unregister()
                }
            } else {
                try setLaunchAgent(enabled)
            }
        } catch {
            mijiaLog("設定登入時自動啟動失敗: \(error.localizedDescription)")
            return .unavailable("無法設定：\(error.localizedDescription)")
        }
        let state = currentState()
        let summary: String
        switch state {
        case .enabled: summary = "已開啟"
        case .disabled: summary = "已關閉"
        case .requiresApproval: summary = "需要在系統設定核准"
        case .unavailable(let reason): summary = "無法設定 (\(reason))"
        }
        mijiaLog("登入時自動啟動: \(summary)")
        return state
    }

    static func openLoginItemsSettings() {
        if #available(macOS 13.0, *) {
            SMAppService.openSystemSettingsLoginItems()
        }
    }

    /// macOS 12：以 open -g -a 啟動 App (不加 KeepAlive，open 會立刻結束)
    private static func setLaunchAgent(_ enabled: Bool) throws {
        let fm = FileManager.default
        guard enabled else {
            if fm.fileExists(atPath: agentURL.path) { try fm.removeItem(at: agentURL) }
            return
        }
        let plist: [String: Any] = [
            "Label": agentLabel,
            "ProgramArguments": ["/usr/bin/open", "-g", "-a", Bundle.main.bundleURL.path],
            "RunAtLoad": true,
            "LimitLoadToSessionType": "Aqua"
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try fm.createDirectory(at: agentURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: agentURL, options: .atomic)
    }
}
