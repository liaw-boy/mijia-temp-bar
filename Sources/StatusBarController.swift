import AppKit
import CoreWLAN

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

    private let popover = NSPopover()
    private var outsideClickMonitor: Any?
    private var dashboardController: DashboardWindowController?
    private var latestReading: SensorReading?

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
        setupPopover()

        bluetoothManager = BluetoothManager()
        bluetoothManager.delegate = self

        LocationGatekeeper.shared.bluetoothManager = bluetoothManager
        LocationGatekeeper.shared.delegate = self
        LocationGatekeeper.shared.checkCurrentStatus()

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
            dashboardController?.updateReading(cachedReading)
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

        if LocationGatekeeper.shared.isInHomeArea {
            bluetoothManager.startScan()
        }

        // 啟動後稍等再檢查新版本，避免與藍牙初始化搶資源
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            UpdateChecker.shared.checkIfDue { status in
                self?.dashboardController?.showUpdateStatus(status)
            }
        }
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.isVisible = true
        if let button = statusItem.button {
            button.title = "🌡️ 搜尋中..."
            button.toolTip = "米家藍牙溫濕度計 2"
            button.target = self
            button.action = #selector(handleStatusButtonClick)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
    }

    private func setupPopover() {
        let dashboard = DashboardWindowController.shared
        dashboardController = dashboard
        dashboard.onRefreshRequested = { [weak self] in
            self?.handleRefresh()
        }
        dashboard.onIntervalChanged = { [weak self] sec in
            self?.bluetoothManager.setRefreshInterval(sec)
        }
        dashboard.onStyleChanged = { [weak self] style in
            self?.displayStyle = style
            UserDefaults.standard.set(style.rawValue, forKey: "DisplayStyle")
            self?.updateTitle()
        }
        dashboard.onHideWhenDisconnectedChanged = { [weak self] hide in
            guard let self = self else { return }
            self.hideWhenDisconnected = hide
            UserDefaults.standard.set(hide, forKey: "HideWhenDisconnected")
            self.statusItem.isVisible = !(hide && !self.isConnected)
        }
        dashboard.onSettingsChanged = { [weak self] in
            self?.updateTitle()
        }

        if let content = dashboard.detachContentView() {
            popover.contentViewController = DashboardPanelViewController(content: content)
        }
        popover.contentSize = DashboardPanelViewController.panelSize
        popover.behavior = .transient
        popover.delegate = self
        // 切換到其他 App (App 失去焦點) 時一併收起
        NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.popover.performClose(nil)
        }
        popover.animates = true
        popover.appearance = NSAppearance(named: .darkAqua)
    }

    // MARK: - 狀態列點擊

    @objc private func handleStatusButtonClick(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            popover.performClose(nil)
            showContextMenu()
        } else {
            togglePopover()
        }
    }

    private func togglePopover(tab: DashboardWindowController.WindowTab = .dashboard) {
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        guard let button = statusItem.button else { return }
        if let r = bluetoothManager.currentReading {
            dashboardController?.updateReading(r)
        } else {
            dashboardController?.reloadData()
        }
        dashboardController?.updatePresenceStatus()
        dashboardController?.switchTab(tab)
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()

        // 常駐型 (accessory) App 的 transient 面板不會因點擊其他 App 而收起，自行監聽外部點擊
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            self?.popover.performClose(nil)
        }
    }

    /// 右鍵只保留最精簡的選單
    private func showContextMenu() {
        let menu = NSMenu()
        let settings = NSMenuItem(title: "設定…", action: #selector(showSettingsAction), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(NSMenuItem.separator())
        let quit = NSMenuItem(title: "結束 MijiaTempBar", action: #selector(handleQuit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
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
    @objc private func showSettingsAction() {
        if popover.isShown {
            dashboardController?.switchTab(.settings)
        } else {
            togglePopover(tab: .settings)
        }
    }

    private func handleRefresh() {
        statusItem.isVisible = true
        dashboardController?.updateStatusText("正在連線重新整理...")
        bluetoothManager.manualRefresh()
    }

    @objc private func handleQuit() {
        NSApplication.shared.terminate(nil)
    }
}

// MARK: - BluetoothManagerDelegate
extension StatusBarController: BluetoothManagerDelegate {
    func didUpdateStatus(_ status: String) {
        dashboardController?.updateStatusText(status)

        if bluetoothManager.currentReading == nil && isConnected == false {
            statusItem.button?.image = nil
            statusItem.button?.title = "🌡️ \(status)"
        }
    }

    func didChangeReachability(_ reachable: Bool) {
        guard !reachable else { return }
        isConnected = false
        if hideWhenDisconnected {
            popover.performClose(nil)
            statusItem.isVisible = false
        }
    }

    func didUpdateReading(_ reading: SensorReading) {
        isConnected = true
        tempShowTimer?.invalidate()
        tempShowTimer = nil
        latestReading = reading

        statusItem.isVisible = true

        // 先寫入歷史，面板與儀表板重繪時才包含這一筆
        HistoryManager.shared.addPoint(
            temp: reading.temperature,
            hum: reading.humidity,
            volt: reading.voltage,
            battery: reading.batteryPercent
        )
        updateTitle()
        dashboardController?.updateReading(reading)
        NotificationManager.shared.checkReading(reading)
    }

    func didFailWithError(_ error: String) {
        dashboardController?.updateStatusText(error)
    }
}

// MARK: - LocationGatekeeperDelegate
extension StatusBarController: LocationGatekeeperDelegate {
    func locationGatekeeperDidChangeState(isHome: Bool, reason: String) {
        dashboardController?.updatePresenceStatus()
    }
}

// MARK: - NSPopoverDelegate
extension StatusBarController: NSPopoverDelegate {
    func popoverDidClose(_ notification: Notification) {
        if let monitor = outsideClickMonitor {
            NSEvent.removeMonitor(monitor)
            outsideClickMonitor = nil
        }
    }
}
