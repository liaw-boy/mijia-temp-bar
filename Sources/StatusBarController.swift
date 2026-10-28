import AppKit

enum DisplayStyle: Int {
    case statsBadge = 0 // 雙行微型膠囊風格 (TMP / HUM 雙行對齊)
    case stacked = 1    // 純數字雙行堆疊 (26.1° / 63%)
    case horizontal = 2 // 橫向完整 (🌡️ 26.1°C  💧 65%)
    case tempOnly = 3   // 僅溫度 (🌡️ 26.1°C)
    case compact = 4    // 緊湊單行 (26.1° 65%)
}

final class StatusBarController: NSObject {
    private var statusItem: NSStatusItem!
    private var bluetoothManager: BluetoothManager!
    private var displayStyle: DisplayStyle = .statsBadge

    // 「僅連線時顯示」功能開關
    private var hideWhenDisconnected: Bool = true
    private var isConnected: Bool = false
    private var tempShowTimer: Timer?

    // 選單項目參照
    private var headerMenuItem: NSMenuItem!
    private var tempMenuItem: NSMenuItem!
    private var humMenuItem: NSMenuItem!
    private var batMenuItem: NSMenuItem!
    private var statusMenuItem: NSMenuItem!
    private var timeMenuItem: NSMenuItem!
    private var modeMenuItem: NSMenuItem!
    private var hideWhenDisconnectedMenuItem: NSMenuItem!
    private var intervalSubMenu: NSMenu!
    private var customIntervalMenuItem: NSMenuItem!
    private var dashboardController: DashboardWindowController?
    private var latestReading: SensorReading?

    // 居家大範圍地理圍欄選單項目
    private var geofenceSubMenu: NSMenu!
    private var geofenceToggleMenuItem: NSMenuItem!
    private var geofenceStatusMenuItem: NSMenuItem!
    private var geofenceRadiusMenuItems: [NSMenuItem] = []

    override init() {
        super.init()

        // 讀取偏好設定
        if UserDefaults.standard.object(forKey: "HideWhenDisconnected") != nil {
            hideWhenDisconnected = UserDefaults.standard.bool(forKey: "HideWhenDisconnected")
        } else {
            hideWhenDisconnected = true
            UserDefaults.standard.set(true, forKey: "HideWhenDisconnected")
        }

        if let savedStyle = UserDefaults.standard.object(forKey: "DisplayStyle") as? Int,
           let style = DisplayStyle(rawValue: savedStyle) {
            displayStyle = style
        } else {
            displayStyle = .statsBadge
            UserDefaults.standard.set(DisplayStyle.statsBadge.rawValue, forKey: "DisplayStyle")
        }

        setupStatusItem()
        setupMenu()

        bluetoothManager = BluetoothManager()
        bluetoothManager.delegate = self

        LocationGatekeeper.shared.bluetoothManager = bluetoothManager
        LocationGatekeeper.shared.delegate = self

        // 啟動時立刻恢復最近一次讀取的數據 (避免圖示閃爍或意外消失)
        if let last = HistoryManager.shared.points.last {
            isConnected = true
            statusItem.isVisible = true
            let cachedReading = SensorReading(
                temperature: last.temperature,
                humidity: last.humidity,
                batteryPercent: last.batteryPercent,
                voltage: last.voltage,
                rssi: nil,
                deviceName: "LYWSD03MMC",
                lastUpdated: last.timestamp,
                mode: "原廠直連 (秒讀休眠)"
            )
            latestReading = cachedReading
            updateTitle()
            applyReadingToMenu(cachedReading)
        } else if hideWhenDisconnected {
            // 首次全新安裝無快取數據時，若超過 45 秒未連線才依設定隱藏
            tempShowTimer = Timer.scheduledTimer(withTimeInterval: 45.0, repeats: false) { [weak self] _ in
                guard let self = self else { return }
                if !self.isConnected {
                    self.statusItem.isVisible = false
                    mijiaLog("尚未連線，依設定自動隱藏狀態列圖示")
                }
            }
        }

        bluetoothManager.startScan()
        refreshIntervalMenuChecks()
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.isVisible = true
        if let button = statusItem.button {
            button.title = "🌡️ 搜尋中..."
            button.toolTip = "米家藍牙溫濕度計 2"
        }
    }

    private func setupMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false

        headerMenuItem = NSMenuItem(title: "米家藍牙溫濕度計 2", action: #selector(showDashboard), keyEquivalent: "")
        headerMenuItem.target = self
        headerMenuItem.isEnabled = true
        headerMenuItem.attributedTitle = NSAttributedString(
            string: "米家藍牙溫濕度計 2",
            attributes: [.font: NSFont.boldSystemFont(ofSize: 13)]
        )
        menu.addItem(headerMenuItem)

        let openDashboardItem = NSMenuItem(title: "📊 開啟即時儀表板與歷史圖表 (⌘D)...", action: #selector(showDashboard), keyEquivalent: "d")
        openDashboardItem.target = self
        menu.addItem(openDashboardItem)

        statusMenuItem = NSMenuItem(title: "狀態: 正在搜尋藍牙設備...", action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)

        menu.addItem(NSMenuItem.separator())

        tempMenuItem = NSMenuItem(title: "溫度: -- °C", action: nil, keyEquivalent: "")
        tempMenuItem.isEnabled = false
        menu.addItem(tempMenuItem)

        humMenuItem = NSMenuItem(title: "濕度: -- %", action: nil, keyEquivalent: "")
        humMenuItem.isEnabled = false
        menu.addItem(humMenuItem)

        batMenuItem = NSMenuItem(title: "電量: -- %", action: nil, keyEquivalent: "")
        batMenuItem.isEnabled = false
        menu.addItem(batMenuItem)

        modeMenuItem = NSMenuItem(title: "模式: --", action: nil, keyEquivalent: "")
        modeMenuItem.isEnabled = false
        menu.addItem(modeMenuItem)

        timeMenuItem = NSMenuItem(title: "最後更新: --", action: nil, keyEquivalent: "")
        timeMenuItem.isEnabled = false
        menu.addItem(timeMenuItem)

        menu.addItem(NSMenuItem.separator())

        let refreshItem = NSMenuItem(title: "重新整理 / 重新搜尋", action: #selector(handleRefresh), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)

        // 連線間隔 / 更新頻率子選單
        intervalSubMenu = NSMenu()
        let intervals: [(String, Double)] = [
            ("30 秒 (即時模式 - 較耗電)", 30.0),
            ("1 分鐘", 60.0),
            ("3 分鐘", 180.0),
            ("5 分鐘 (推薦平衡)", 300.0),
            ("10 分鐘", 600.0),
            ("15 分鐘", 900.0),
            ("30 分鐘 (極致省電)", 1800.0),
            ("1 小時 (超省電休眠，續航 1 年+)", 3600.0),
            ("2 小時", 7200.0)
        ]
        for (title, sec) in intervals {
            let item = NSMenuItem(title: title, action: #selector(handleSelectInterval(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = sec
            intervalSubMenu.addItem(item)
        }
        intervalSubMenu.addItem(NSMenuItem.separator())
        customIntervalMenuItem = NSMenuItem(title: "自訂時間 (分鐘)...", action: #selector(handleCustomInterval), keyEquivalent: "")
        customIntervalMenuItem.target = self
        intervalSubMenu.addItem(customIntervalMenuItem)

        let intervalParentItem = NSMenuItem(title: "連線間隔時間 (更新頻率)", action: nil, keyEquivalent: "")
        intervalParentItem.submenu = intervalSubMenu
        menu.addItem(intervalParentItem)

        // 僅連線時顯示開關
        hideWhenDisconnectedMenuItem = NSMenuItem(
            title: "僅連線時顯示 (斷線時自動隱藏圖示)",
            action: #selector(toggleHideWhenDisconnected),
            keyEquivalent: ""
        )
        hideWhenDisconnectedMenuItem.target = self
        hideWhenDisconnectedMenuItem.state = hideWhenDisconnected ? .on : .off
        menu.addItem(hideWhenDisconnectedMenuItem)

        // 低電量警示通知開關
        let lowBatteryMenuItem = NSMenuItem(
            title: "🔔 低電量警示通知 (電量 ≤ 15%)",
            action: #selector(toggleLowBatteryNotification),
            keyEquivalent: ""
        )
        lowBatteryMenuItem.target = self
        lowBatteryMenuItem.state = NotificationManager.shared.isEnabled ? .on : .off
        menu.addItem(lowBatteryMenuItem)

        // 樣式切換子選單
        let styleSubMenu = NSMenu()
        let styleItemStats = NSMenuItem(title: "雙行微型膠囊樣式 ([TMP] / [HUM])", action: #selector(setDisplayStatsBadge), keyEquivalent: "")
        styleItemStats.target = self
        styleItemStats.state = (displayStyle == .statsBadge) ? .on : .off
        styleSubMenu.addItem(styleItemStats)

        let styleItemStacked = NSMenuItem(title: "純數字雙行堆疊 (26.1° / 63%)", action: #selector(setDisplayStacked), keyEquivalent: "")
        styleItemStacked.target = self
        styleItemStacked.state = (displayStyle == .stacked) ? .on : .off
        styleSubMenu.addItem(styleItemStacked)

        let styleItemHorizontal = NSMenuItem(title: "橫向完整 (🌡️ 26°C  💧 65%)", action: #selector(setDisplayHorizontal), keyEquivalent: "")
        styleItemHorizontal.target = self
        styleItemHorizontal.state = (displayStyle == .horizontal) ? .on : .off
        styleSubMenu.addItem(styleItemHorizontal)

        let styleItemTemp = NSMenuItem(title: "僅溫度 (🌡️ 26°C)", action: #selector(setDisplayTempOnly), keyEquivalent: "")
        styleItemTemp.target = self
        styleItemTemp.state = (displayStyle == .tempOnly) ? .on : .off
        styleSubMenu.addItem(styleItemTemp)

        let styleItemCompact = NSMenuItem(title: "緊湊單行 (26.1° 65%)", action: #selector(setDisplayCompact), keyEquivalent: "")
        styleItemCompact.target = self
        styleItemCompact.state = (displayStyle == .compact) ? .on : .off
        styleSubMenu.addItem(styleItemCompact)

        let styleParentItem = NSMenuItem(title: "狀態列樣式", action: nil, keyEquivalent: "")
        styleParentItem.submenu = styleSubMenu
        menu.addItem(styleParentItem)

        // 居家大範圍感應子選單 (離家徹底關閉藍牙)
        setupGeofenceMenu(parentMenu: menu)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "結束 MijiaTempBar", action: #selector(handleQuit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    private func updateTitle() {
        guard let button = statusItem.button else { return }

        guard let r = latestReading ?? bluetoothManager?.currentReading else {
            button.image = nil
            button.title = "🌡️ 搜尋中..."
            return
        }

        switch displayStyle {
        case .statsBadge:
            button.title = ""
            button.image = makeStatsBadgeImage(temp: r.temperature, hum: r.humidity)
            button.imagePosition = .imageOnly

        case .stacked:
            button.title = ""
            button.image = makeStackedImage(temp: r.temperature, hum: r.humidity)
            button.imagePosition = .imageOnly

        case .horizontal:
            button.image = nil
            button.title = String(format: "🌡️ %.1f°C  💧 %.0f%%", r.temperature, r.humidity)

        case .tempOnly:
            button.image = nil
            button.title = String(format: "🌡️ %.1f°C", r.temperature)

        case .compact:
            button.image = nil
            button.title = String(format: "%.1f° %.0f%%", r.temperature, r.humidity)
        }

        button.toolTip = String(
            format: "%@\n溫度: %.1f°C\n濕度: %.0f%%\n電量: %d%%\n更新間隔: %d秒\n模式: %@",
            r.deviceName, r.temperature, r.humidity, r.batteryPercent, Int(bluetoothManager.refreshInterval), r.mode
        )
    }

    /// 產生 [TMP] / [HUM] 雙行微型膠囊影像 (上下完全貼滿 24pt 版)
    private func makeStatsBadgeImage(temp: Double, hum: Double) -> NSImage {
        let topLabel = "TMP"
        let bottomLabel = "HUM"
        let topVal = String(format: "%.1f°", temp)
        let bottomVal = String(format: "%.0f%%", hum)

        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let textColor = isDark ? NSColor.white : NSColor(white: 0.1, alpha: 1.0)

        // 徹底吃滿 Mac 狀態列 24pt 高度：
        // 數字放大至 11.2pt 粗黑體
        // 膠囊字體放大至 8.2pt 超粗黑體
        let badgeFont = NSFont.systemFont(ofSize: 8.2, weight: .black)
        let valFont = NSFont.monospacedDigitSystemFont(ofSize: 11.2, weight: .bold)

        let badgeAttrs: [NSAttributedString.Key: Any] = [
            .font: badgeFont,
            .foregroundColor: NSColor.white
        ]
        let valAttrs: [NSAttributedString.Key: Any] = [
            .font: valFont,
            .foregroundColor: textColor
        ]

        let topValSize = (topVal as NSString).size(withAttributes: valAttrs)
        let bottomValSize = (bottomVal as NSString).size(withAttributes: valAttrs)
        let maxValWidth = max(topValSize.width, bottomValSize.width)

        // 膠囊尺寸：高度放大到 10.5pt，完全貼滿上下半部
        let badgeWidth: CGFloat = 25.0
        let badgeHeight: CGFloat = 10.5
        let badgeRadius: CGFloat = 2.5
        let gap: CGFloat = 4.5

        let totalWidth = badgeWidth + gap + maxValWidth + 2.0
        let totalHeight: CGFloat = 24.0

        let image = NSImage(size: NSSize(width: totalWidth, height: totalHeight), flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }

            // 1. 上排 TMP 膠囊 (熱能暖橙：#EA580C) - 頂部貼近邊界
            let topBadgeY: CGFloat = 12.5
            let topBadgeRect = CGRect(x: 1.0, y: topBadgeY, width: badgeWidth, height: badgeHeight)
            let topBadgePath = CGPath(roundedRect: topBadgeRect, cornerWidth: badgeRadius, cornerHeight: badgeRadius, transform: nil)

            ctx.setFillColor(CGColor(red: 0.92, green: 0.35, blue: 0.10, alpha: 1.0))
            ctx.addPath(topBadgePath)
            ctx.fillPath()

            // TMP 縮寫文字居中
            let topLabelSize = (topLabel as NSString).size(withAttributes: badgeAttrs)
            let topLabelPt = CGPoint(
                x: topBadgeRect.midX - topLabelSize.width * 0.5,
                y: topBadgeRect.midY - topLabelSize.height * 0.5 + 0.5
            )
            (topLabel as NSString).draw(at: topLabelPt, withAttributes: badgeAttrs)

            // 上排溫度數值 (靠左對齊，飽滿大字)
            let topValPt = CGPoint(x: topBadgeRect.maxX + gap, y: topBadgeY - 1.2)
            (topVal as NSString).draw(at: topValPt, withAttributes: valAttrs)

            // 2. 下排 HUM 膠囊 (濕度湛藍：#0284C7) - 底部貼近邊界
            let bottomBadgeY: CGFloat = 1.0
            let bottomBadgeRect = CGRect(x: 1.0, y: bottomBadgeY, width: badgeWidth, height: badgeHeight)
            let bottomBadgePath = CGPath(roundedRect: bottomBadgeRect, cornerWidth: badgeRadius, cornerHeight: badgeRadius, transform: nil)

            ctx.setFillColor(CGColor(red: 0.05, green: 0.55, blue: 0.88, alpha: 1.0))
            ctx.addPath(bottomBadgePath)
            ctx.fillPath()

            // HUM 縮寫文字居中
            let bottomLabelSize = (bottomLabel as NSString).size(withAttributes: badgeAttrs)
            let bottomLabelPt = CGPoint(
                x: bottomBadgeRect.midX - bottomLabelSize.width * 0.5,
                y: bottomBadgeRect.midY - bottomLabelSize.height * 0.5 + 0.5
            )
            (bottomLabel as NSString).draw(at: bottomLabelPt, withAttributes: badgeAttrs)

            // 下排濕度數值 (靠左對齊，飽滿大字)
            let bottomValPt = CGPoint(x: bottomBadgeRect.maxX + gap, y: bottomBadgeY - 1.2)
            (bottomVal as NSString).draw(at: bottomValPt, withAttributes: valAttrs)

            return true
        }

        image.isTemplate = false
        return image
    }

    /// 純數字雙行堆疊 (上下吃滿版)
    private func makeStackedImage(temp: Double, hum: Double) -> NSImage {
        let topText = String(format: "%.1f°", temp)
        let bottomText = String(format: "%.0f%%", hum)

        let fontTop = NSFont.monospacedDigitSystemFont(ofSize: 11.0, weight: .bold)
        let fontBottom = NSFont.monospacedDigitSystemFont(ofSize: 11.0, weight: .bold)

        let attrsTop: [NSAttributedString.Key: Any] = [
            .font: fontTop,
            .foregroundColor: NSColor.black
        ]
        let attrsBottom: [NSAttributedString.Key: Any] = [
            .font: fontBottom,
            .foregroundColor: NSColor.black
        ]

        let sizeTop = (topText as NSString).size(withAttributes: attrsTop)
        let sizeBottom = (bottomText as NSString).size(withAttributes: attrsBottom)

        let textWidth = max(sizeTop.width, sizeBottom.width)
        let totalWidth = ceil(textWidth) + 6.0
        let totalHeight: CGFloat = 24.0

        let image = NSImage(size: NSSize(width: totalWidth, height: totalHeight), flipped: false) { rect in
            let topPoint = NSPoint(x: (totalWidth - sizeTop.width) / 2.0, y: 12.5)
            let bottomPoint = NSPoint(x: (totalWidth - sizeBottom.width) / 2.0, y: 1.0)

            (topText as NSString).draw(at: topPoint, withAttributes: attrsTop)
            (bottomText as NSString).draw(at: bottomPoint, withAttributes: attrsBottom)
            return true
        }

        image.isTemplate = true
        return image
    }

    func temporarilyShowStatusItem() {
        tempShowTimer?.invalidate()
        statusItem.isVisible = true
        if !isConnected && hideWhenDisconnected {
            tempShowTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: false) { [weak self] _ in
                guard let self = self else { return }
                if !self.isConnected {
                    self.statusItem.isVisible = false
                }
            }
        }
    }

    // MARK: - Actions
    @objc private func handleSelectInterval(_ sender: NSMenuItem) {
        guard let sec = sender.representedObject as? Double else { return }
        bluetoothManager.setRefreshInterval(sec)
        refreshIntervalMenuChecks()
    }

    @objc private func handleCustomInterval() {
        let alert = NSAlert()
        alert.messageText = "自訂更新間隔時間"
        alert.informativeText = "請輸入更新輪詢間隔（以分鐘為單位）：\n例如輸入 60 代表 1 小時，輸入 120 代表 2 小時。"
        alert.addButton(withTitle: "確定")
        alert.addButton(withTitle: "取消")

        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        let currentMinutes = Int(bluetoothManager.refreshInterval / 60.0)
        input.stringValue = "\(max(1, currentMinutes))"
        alert.accessoryView = input

        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            let text = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if let mins = Double(text), mins >= 0.5 {
                let seconds = mins * 60.0
                bluetoothManager.setRefreshInterval(seconds)
                refreshIntervalMenuChecks()
            }
        }
    }

    private func refreshIntervalMenuChecks() {
        guard let sub = intervalSubMenu else { return }
        let currentSec = bluetoothManager.refreshInterval
        var matchedPreset = false
        for item in sub.items {
            if let sec = item.representedObject as? Double {
                let isMatch = abs(sec - currentSec) < 0.1
                item.state = isMatch ? .on : .off
                if isMatch { matchedPreset = true }
            }
        }

        if let customItem = customIntervalMenuItem {
            customItem.state = matchedPreset ? .off : .on
            if !matchedPreset {
                if currentSec >= 3600.0 {
                    let hrs = currentSec / 3600.0
                    let formatted = (hrs.truncatingRemainder(dividingBy: 1.0) == 0) ? String(format: "%.0f", hrs) : String(format: "%.1f", hrs)
                    customItem.title = "自訂時間... (目前: \(formatted) 小時)"
                } else {
                    let mins = Int(round(currentSec / 60.0))
                    customItem.title = "自訂時間... (目前: \(mins) 分鐘)"
                }
            } else {
                customItem.title = "自訂時間 (分鐘)..."
            }
        }
    }

    @objc private func toggleHideWhenDisconnected() {
        hideWhenDisconnected.toggle()
        UserDefaults.standard.set(hideWhenDisconnected, forKey: "HideWhenDisconnected")
        hideWhenDisconnectedMenuItem.state = hideWhenDisconnected ? .on : .off

        if hideWhenDisconnected && !isConnected {
            statusItem.isVisible = false
        } else {
            statusItem.isVisible = true
        }
    }

    @objc private func showDashboard() {
        if dashboardController == nil {
            dashboardController = DashboardWindowController.shared
            dashboardController?.onRefreshRequested = { [weak self] in
                self?.bluetoothManager.manualRefresh()
            }
        }
        if let r = bluetoothManager.currentReading {
            dashboardController?.updateReading(r)
        } else {
            dashboardController?.reloadData()
        }
        NSApp.activate(ignoringOtherApps: true)
        dashboardController?.showWindow(nil)
        dashboardController?.window?.makeKeyAndOrderFront(nil)
    }

    @objc private func handleRefresh() {
        statusItem.isVisible = true
        statusMenuItem.title = "狀態: 正在連線重新整理..."
        bluetoothManager.manualRefresh()
    }

    @objc private func setDisplayStatsBadge() {
        displayStyle = .statsBadge
        UserDefaults.standard.set(DisplayStyle.statsBadge.rawValue, forKey: "DisplayStyle")
        updateTitle()
        refreshStyleMenuChecks()
    }

    @objc private func setDisplayStacked() {
        displayStyle = .stacked
        UserDefaults.standard.set(DisplayStyle.stacked.rawValue, forKey: "DisplayStyle")
        updateTitle()
        refreshStyleMenuChecks()
    }

    @objc private func setDisplayHorizontal() {
        displayStyle = .horizontal
        UserDefaults.standard.set(DisplayStyle.horizontal.rawValue, forKey: "DisplayStyle")
        updateTitle()
        refreshStyleMenuChecks()
    }

    @objc private func setDisplayTempOnly() {
        displayStyle = .tempOnly
        UserDefaults.standard.set(DisplayStyle.tempOnly.rawValue, forKey: "DisplayStyle")
        updateTitle()
        refreshStyleMenuChecks()
    }

    @objc private func setDisplayCompact() {
        displayStyle = .compact
        UserDefaults.standard.set(DisplayStyle.compact.rawValue, forKey: "DisplayStyle")
        updateTitle()
        refreshStyleMenuChecks()
    }

    private func refreshStyleMenuChecks() {
        if let styleMenu = statusItem.menu?.items.first(where: { $0.title == "狀態列樣式" })?.submenu {
            styleMenu.items[0].state = (displayStyle == .statsBadge) ? .on : .off
            styleMenu.items[1].state = (displayStyle == .stacked) ? .on : .off
            styleMenu.items[2].state = (displayStyle == .horizontal) ? .on : .off
            styleMenu.items[3].state = (displayStyle == .tempOnly) ? .on : .off
            styleMenu.items[4].state = (displayStyle == .compact) ? .on : .off
        }
    }

    @objc private func toggleLowBatteryNotification(_ sender: NSMenuItem) {
        NotificationManager.shared.isEnabled.toggle()
        sender.state = NotificationManager.shared.isEnabled ? .on : .off
        mijiaLog("低電量通知設定變更: \(NotificationManager.shared.isEnabled ? "開啟" : "關閉")")
    }

    // MARK: - 居家大範圍地理圍欄選單與互動
    private func setupGeofenceMenu(parentMenu: NSMenu) {
        geofenceSubMenu = NSMenu()

        geofenceToggleMenuItem = NSMenuItem(
            title: "啟用大範圍感應 (離家徹底停機)",
            action: #selector(handleToggleGeofence),
            keyEquivalent: ""
        )
        geofenceToggleMenuItem.target = self
        geofenceToggleMenuItem.state = LocationGatekeeper.shared.isEnabled ? .on : .off
        geofenceSubMenu.addItem(geofenceToggleMenuItem)

        geofenceSubMenu.addItem(NSMenuItem.separator())

        let recordItem = NSMenuItem(
            title: "📌 記錄目前位置為居家中心",
            action: #selector(handleRecordHomeLocation),
            keyEquivalent: ""
        )
        recordItem.target = self
        geofenceSubMenu.addItem(recordItem)

        // 半徑設定 (100m, 200m, 500m, 1000m)
        let radiusSubMenu = NSMenu()
        let radii: [Double] = [100.0, 200.0, 500.0, 1000.0]
        geofenceRadiusMenuItems.removeAll()
        for r in radii {
            let item = NSMenuItem(title: "\(Int(r)) 公尺", action: #selector(handleSelectRadius(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = r
            item.state = (abs(LocationGatekeeper.shared.geofenceRadius - r) < 1.0) ? .on : .off
            geofenceRadiusMenuItems.append(item)
            radiusSubMenu.addItem(item)
        }
        let radiusParent = NSMenuItem(title: "圍欄感應半徑", action: nil, keyEquivalent: "")
        radiusParent.submenu = radiusSubMenu
        geofenceSubMenu.addItem(radiusParent)

        geofenceSubMenu.addItem(NSMenuItem.separator())

        geofenceStatusMenuItem = NSMenuItem(title: "狀態: 尚未設定居家位置", action: nil, keyEquivalent: "")
        geofenceStatusMenuItem.isEnabled = false
        geofenceSubMenu.addItem(geofenceStatusMenuItem)

        let clearItem = NSMenuItem(
            title: "❌ 清除居家位置設定",
            action: #selector(handleClearHomeLocation),
            keyEquivalent: ""
        )
        clearItem.target = self
        geofenceSubMenu.addItem(clearItem)

        let geofenceParent = NSMenuItem(title: "📍 居家大範圍感應 (離家自動關閉)", action: nil, keyEquivalent: "")
        geofenceParent.submenu = geofenceSubMenu
        parentMenu.addItem(geofenceParent)

        updateGeofenceMenuState()
    }

    @objc private func handleToggleGeofence() {
        if !LocationGatekeeper.shared.hasHomeLocation {
            handleRecordHomeLocation()
            return
        }
        LocationGatekeeper.shared.isEnabled.toggle()
        updateGeofenceMenuState()
    }

    @objc private func handleRecordHomeLocation() {
        let alert = NSAlert()
        alert.messageText = "設定居家中心位置"
        alert.informativeText = "即將使用您目前的定位座標與連線網路作為「家」的大範圍參考中心。確定要將目前位置設為居家中心嗎？"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "確定設定")
        alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn {
            LocationGatekeeper.shared.recordCurrentAsHome { [weak self] success, msg in
                DispatchQueue.main.async {
                    self?.updateGeofenceMenuState()
                    let resultAlert = NSAlert()
                    resultAlert.messageText = success ? "居家位置設定成功" : "設定提示"
                    resultAlert.informativeText = msg
                    resultAlert.runModal()
                }
            }
        }
    }

    @objc private func handleSelectRadius(_ sender: NSMenuItem) {
        guard let r = sender.representedObject as? Double else { return }
        LocationGatekeeper.shared.geofenceRadius = r
        for item in geofenceRadiusMenuItems {
            if let ir = item.representedObject as? Double {
                item.state = (abs(ir - r) < 1.0) ? .on : .off
            }
        }
        updateGeofenceMenuState()
    }

    @objc private func handleClearHomeLocation() {
        LocationGatekeeper.shared.clearHomeLocation()
        updateGeofenceMenuState()
    }

    func updateGeofenceMenuState() {
        geofenceToggleMenuItem?.state = LocationGatekeeper.shared.isEnabled ? .on : .off

        if !LocationGatekeeper.shared.hasHomeLocation {
            geofenceStatusMenuItem?.title = "狀態: 尚未設定居家位置"
        } else if !LocationGatekeeper.shared.isEnabled {
            geofenceStatusMenuItem?.title = "狀態: 大範圍感應已暫停"
        } else {
            let isHome = LocationGatekeeper.shared.isInHomeArea
            if let dist = LocationGatekeeper.shared.lastKnownDistance {
                geofenceStatusMenuItem?.title = isHome ?
                    String(format: "狀態: 🏠 範圍內 (距家 %.0fm)", dist) :
                    String(format: "狀態: 🚗 範圍外 (距家 %.0fm · 停機)", dist)
            } else {
                geofenceStatusMenuItem?.title = isHome ? "狀態: 🏠 在家範圍內 (運行中)" : "狀態: 🚗 範圍外 (藍牙停機中)"
            }
        }
    }

    @objc private func handleQuit() {
        NSApplication.shared.terminate(nil)
    }
}

// MARK: - BluetoothManagerDelegate
extension StatusBarController: BluetoothManagerDelegate {
    func didUpdateStatus(_ status: String) {
        statusMenuItem.title = "狀態: \(status)"

        if status.contains("連線中斷") || status.contains("失敗") || status.contains("關閉") || status.contains("範圍") {
            isConnected = false
            if hideWhenDisconnected {
                statusItem.isVisible = false
            }
        } else if bluetoothManager.currentReading == nil {
            statusItem.button?.image = nil
            statusItem.button?.title = "🌡️ \(status)"
        }
    }

    func didUpdateReading(_ reading: SensorReading) {
        isConnected = true
        tempShowTimer?.invalidate()
        tempShowTimer = nil
        latestReading = reading

        statusItem.isVisible = true
        updateTitle()
        applyReadingToMenu(reading)

        // 記錄歷史數據並同步儀表板
        HistoryManager.shared.addPoint(
            temp: reading.temperature,
            hum: reading.humidity,
            volt: reading.voltage,
            battery: reading.batteryPercent
        )
        dashboardController?.updateReading(reading)
        NotificationManager.shared.checkReading(reading)
    }

    private func applyReadingToMenu(_ reading: SensorReading) {
        headerMenuItem.title = reading.deviceName
        tempMenuItem.title = String(format: "溫度: %.1f °C", reading.temperature)
        humMenuItem.title = String(format: "濕度: %.1f %%", reading.humidity)
        if reading.batteryPercent <= 15 || reading.voltage <= 2.60 {
            batMenuItem.title = String(format: "⚠️ 電量過低: %d %% (%.3fV) - 請換電池", reading.batteryPercent, reading.voltage)
        } else {
            batMenuItem.title = String(format: "電量: %d %% (%.3fV)", reading.batteryPercent, reading.voltage)
        }
        modeMenuItem.title = "連線模式: \(reading.mode)"

        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        timeMenuItem.title = "最後更新: \(formatter.string(from: reading.lastUpdated))"
        statusMenuItem.title = "狀態: 正常運作中"
    }

    func didFailWithError(_ error: String) {
        statusMenuItem.title = "提示: \(error)"
    }
}

// MARK: - LocationGatekeeperDelegate
extension StatusBarController: LocationGatekeeperDelegate {
    func locationGatekeeperDidChangeState(isHome: Bool, reason: String) {
        updateGeofenceMenuState()
    }
}
