import AppKit

/// 選單、儀表板與設定分頁共用的裝置操作介面 (由 StatusBarController 實作)
protocol DeviceCoordinator: AnyObject {
    var devices: [DeviceRecord] { get }
    var primaryID: String? { get }
    /// 藍牙關閉、離家停機等全域狀態；正常時為 nil
    var globalStatus: String? { get }
    func state(for id: String) -> DeviceState
    func setPrimary(_ id: String)
    func refresh(_ id: String?)
    func renameDevice(_ id: String)
    func removeDevice(_ id: String)
    func openDeviceSearch()
    func openSettings()
    func quit()
}

/// 以閉包處理點擊的選單項目 (不必為每個項目寫 @objc 方法)
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, keyEquivalent: String = "", handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: keyEquivalent)
        target = self
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func fire() { handler() }
}

/// 右鍵選單：每台裝置一列 (主裝置打勾)，子選單可切換主裝置、立即更新、改名、移除
enum DeviceMenuBuilder {
    static func contextMenu(for c: DeviceCoordinator) -> NSMenu {
        let menu = deviceMenu(for: c)
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: "設定…", keyEquivalent: ",") { c.openSettings() })
        menu.addItem(ClosureMenuItem(title: "結束 MijiaTempBar", keyEquivalent: "q") { c.quit() })
        return menu
    }

    /// 只有裝置區段 (設定分頁的「管理…」按鈕也用這份)
    static func deviceMenu(for c: DeviceCoordinator) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for device in c.devices {
            menu.addItem(deviceRow(device, c))
        }
        if c.devices.isEmpty {
            menu.addItem(disabled("尚未加入裝置"))
        }
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: "搜尋新裝置…") { c.openDeviceSearch() })
        if c.devices.contains(where: { $0.kind == .stock }) {
            menu.addItem(ClosureMenuItem(title: "全部立即更新") { c.refresh(nil) })
        }
        return menu
    }

    private static func deviceRow(_ device: DeviceRecord, _ c: DeviceCoordinator) -> NSMenuItem {
        let state = c.state(for: device.id)
        let isPrimary = device.id == c.primaryID
        let row = NSMenuItem(title: DisplayRules.summaryText(name: device.name, state: state), action: nil, keyEquivalent: "")
        row.state = isPrimary ? .on : .off

        let sub = NSMenu()
        sub.autoenablesItems = false
        for line in detailLines(device, state) { sub.addItem(disabled(line)) }
        sub.addItem(.separator())
        if isPrimary {
            sub.addItem(disabled("✓ 目前顯示在狀態列"))
        } else {
            sub.addItem(ClosureMenuItem(title: "顯示在狀態列") { c.setPrimary(device.id) })
        }
        if device.kind == .stock {
            sub.addItem(ClosureMenuItem(title: "立即更新這台") { c.refresh(device.id) })
        }
        sub.addItem(ClosureMenuItem(title: "重新命名…") { c.renameDevice(device.id) })
        sub.addItem(ClosureMenuItem(title: "移除此裝置…") { c.removeDevice(device.id) })
        row.submenu = sub
        return row
    }

    static func detailLines(_ device: DeviceRecord, _ state: DeviceState) -> [String] {
        var lines: [String]
        if let r = state.reading {
            let df = DateFormatter()
            df.dateFormat = "MM/dd HH:mm:ss"
            lines = [String(format: "電量: %d %% (%.2fV)", r.batteryPercent, r.voltage),
                     "最後更新: \(df.string(from: r.lastUpdated))" + (state.cached ? " (上次紀錄)" : "")]
        } else {
            lines = ["電量: --", "最後更新: --"]
        }
        lines.append("狀態: \(state.status)")
        lines.append("連線模式: \(device.kind.title)")
        return lines
    }

    private static func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }
}

/// 改名、移除確認等小對話框
enum DeviceDialogs {
    static func askRename(current: String) -> String? {
        let alert = NSAlert()
        alert.messageText = "重新命名裝置"
        alert.informativeText = "例如「客廳」「臥室」，最多 \(DeviceList.maxNameLength) 個字。"
        alert.addButton(withTitle: "確定")
        alert.addButton(withTitle: "取消")
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        input.stringValue = current
        alert.accessoryView = input
        alert.window.initialFirstResponder = input
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn ? input.stringValue : nil
    }

    static func confirmRemove(name: String) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "移除「\(name)」？"
        alert.informativeText = "只會從清單移除，這台的歷史紀錄檔會保留在電腦上；之後重新加入即可看到原本的紀錄。"
        alert.addButton(withTitle: "移除")
        alert.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }

    static func showError(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
