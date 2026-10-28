import AppKit
import CoreWLAN

/// 文字垂直置中並保留左右內距的標籤 cell
private final class PaddedLabelCell: NSTextFieldCell {
    private let horizontalInset: CGFloat = 12

    override func titleRect(forBounds rect: NSRect) -> NSRect {
        var r = super.titleRect(forBounds: rect)
        let h = cellSize(forBounds: rect).height
        r.origin.x = rect.origin.x + horizontalInset
        r.origin.y = rect.origin.y + (rect.height - h) / 2
        r.size.width = rect.width - horizontalInset * 2
        r.size.height = h
        return r
    }

    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        super.drawInterior(withFrame: titleRect(forBounds: cellFrame), in: controlView)
    }
}

private class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

final class DashboardWindowController: NSWindowController {
    static let shared = DashboardWindowController()

    enum WindowTab: Int {
        case dashboard = 0
        case settings = 1
    }

    // 頂部列元件
    private var topSegmentedControl: NSSegmentedControl!
    private var deviceView: DeviceView!
    private var titleLabel: NSTextField!
    private var modelBadgeLabel: NSTextField!
    private var statusDotLabel: NSTextField!
    private var lastUpdateLabel: NSTextField!

    // 容器分頁檢視
    private var mainContainer: NSView!
    private var dashboardContainerView: NSView!
    private var settingsScrollView: NSScrollView!
    private var settingsContentView: FlippedView!

    // === 儀表板頁面元件 ===
    private var tempValueLabel: NSTextField!
    private var tempSubLabel: NSTextField!
    private var humValueLabel: NSTextField!
    private var humSubLabel: NSTextField!
    private var batValueLabel: NSTextField!
    private var batSubLabel: NSTextField!

    private var chartSegmentedControl: NSSegmentedControl!
    private var chartView: ChartView!
    private var rangePopUp: NSPopUpButton!
    private var refreshButton: NSButton!
    private var exportButton: NSButton!

    // === 設定頁面元件 ===
    // 1. 網路與在席感應
    private var wifiCheckbox: NSButton!
    private var wifiSSIDTextField: NSTextField!
    private var wifiBindGatewayCheckbox: NSButton!
    private var wifiGatewayInfoLabel: NSTextField!
    private var wifiHintLabel: NSTextField!
    private var updateStatusLabel: NSTextField!
    private var updateButton: NSButton!
    private var autoUpdateCheckbox: NSButton!
    private var availableUpdateURL: URL?
    private var geofenceCheckbox: NSButton!
    private var geofenceRadiusPopUp: NSPopUpButton!
    private var presenceStatusBadge: NSTextField!

    // 2. 頻率與省電
    private var intervalPopUp: NSPopUpButton!
    private var customIntervalField: NSTextField!

    // 3. 外觀與通知
    private var stylePopUp: NSPopUpButton!
    private var hideWhenDisconnectedCheckbox: NSButton!
    private var lowBatteryCheckbox: NSButton!
    private var humidityAlertCheckbox: NSButton!
    private var humidityHighField: NSTextField!
    private var humidityLowField: NSTextField!

    // 回呼閉包 (與 StatusBarController 連動)
    var onRefreshRequested: (() -> Void)?
    var onIntervalChanged: ((Double) -> Void)?
    var onStyleChanged: ((DisplayStyle) -> Void)?
    var onHideWhenDisconnectedChanged: ((Bool) -> Void)?
    var onSettingsChanged: (() -> Void)?

    convenience init() {
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 750, height: 630),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        win.title = "米家藍牙溫濕度計 2 (LYWSD03MMC) - 數據圖表"
        win.titlebarAppearsTransparent = true
        win.titleVisibility = .hidden
        win.isReleasedWhenClosed = false
        win.center()

        self.init(window: win)
        setupUI()
    }

    private func setupUI() {
        guard let win = window else { return }

        // 底層深色霧面毛玻璃效果
        let visualEffect = NSVisualEffectView(frame: win.contentView!.bounds)
        visualEffect.autoresizingMask = [.width, .height]
        visualEffect.material = .hudWindow
        visualEffect.blendingMode = .withinWindow
        visualEffect.state = .active
        win.contentView = visualEffect

        mainContainer = NSView(frame: NSRect(x: 20, y: 15, width: 710, height: 595))
        visualEffect.addSubview(mainContainer)

        setupHeaderBar()
        setupDashboardView()
        setupSettingsView()

        switchTab(.dashboard)
    }

    // MARK: - 頂部導覽列 (Header Bar)
    private func setupHeaderBar() {
        let headerBar = NSView(frame: NSRect(x: 0, y: 545, width: 710, height: 48))
        mainContainer.addSubview(headerBar)

        // 設備示意圖：依實機樣式繪製，數值隨感測數據更新
        deviceView = DeviceView(frame: NSRect(x: 0, y: 2, width: 46, height: 46))
        headerBar.addSubview(deviceView)

        // 標題與型號標章
        titleLabel = NSTextField(labelWithString: "米家藍牙溫濕度計 2")
        titleLabel.frame = NSRect(x: 58, y: 24, width: 150, height: 20)
        titleLabel.font = NSFont.systemFont(ofSize: 14.5, weight: .bold)
        headerBar.addSubview(titleLabel)

        modelBadgeLabel = NSTextField(labelWithString: "LYWSD03MMC")
        modelBadgeLabel.frame = NSRect(x: 210, y: 26, width: 85, height: 16)
        modelBadgeLabel.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .semibold)
        modelBadgeLabel.textColor = NSColor(red: 0.35, green: 0.75, blue: 1.0, alpha: 1.0)
        headerBar.addSubview(modelBadgeLabel)

        statusDotLabel = NSTextField(labelWithString: "● 連線正常 (省電輪詢模式)")
        statusDotLabel.frame = NSRect(x: 58, y: 6, width: 190, height: 16)
        statusDotLabel.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        statusDotLabel.textColor = NSColor(red: 0.25, green: 0.88, blue: 0.50, alpha: 1.0)
        headerBar.addSubview(statusDotLabel)

        // 中央頂部切換導覽分頁 (數據圖表 vs 偏好設定)
        topSegmentedControl = NSSegmentedControl(
            labels: ["數據圖表", "設定"],
            trackingMode: .selectOne,
            target: self,
            action: #selector(handleTopTabChanged)
        )
        topSegmentedControl.frame = NSRect(x: 295, y: 10, width: 200, height: 28)
        topSegmentedControl.selectedSegment = 0
        headerBar.addSubview(topSegmentedControl)

        // 最右側最後更新時間
        lastUpdateLabel = NSTextField(labelWithString: "最後讀取: --:--")
        lastUpdateLabel.frame = NSRect(x: 510, y: 16, width: 198, height: 16)
        lastUpdateLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        lastUpdateLabel.alignment = .right
        lastUpdateLabel.textColor = NSColor(white: 0.55, alpha: 1.0)
        headerBar.addSubview(lastUpdateLabel)
    }

    // MARK: - 儀表板視圖 (Dashboard View)
    private func setupDashboardView() {
        dashboardContainerView = NSView(frame: NSRect(x: 0, y: 0, width: 710, height: 535))
        mainContainer.addSubview(dashboardContainerView)

        // 1. 三大指標卡片 (Y: 425, Height: 100, Width: 226 each)
        let cardW: CGFloat = 226
        let cardH: CGFloat = 100
        let cardY: CGFloat = 425

        // 卡片 1：溫度
        let (card1, tVal, tSub) = makeMetricCard(
            x: 0, y: cardY, w: cardW, h: cardH,
            category: "溫度",
            accentColor: NSColor(red: 1.0, green: 0.48, blue: 0.12, alpha: 1.0)
        )
        dashboardContainerView.addSubview(card1)
        tempValueLabel = tVal
        tempSubLabel = tSub

        // 卡片 2：濕度
        let (card2, hVal, hSub) = makeMetricCard(
            x: 242, y: cardY, w: cardW, h: cardH,
            category: "相對濕度",
            accentColor: NSColor(red: 0.05, green: 0.68, blue: 1.0, alpha: 1.0)
        )
        dashboardContainerView.addSubview(card2)
        humValueLabel = hVal
        humSubLabel = hSub

        // 卡片 3：電池電量
        let (card3, bVal, bSub) = makeMetricCard(
            x: 484, y: cardY, w: cardW, h: cardH,
            category: "電池狀態",
            accentColor: NSColor(red: 0.10, green: 0.88, blue: 0.52, alpha: 1.0)
        )
        dashboardContainerView.addSubview(card3)
        batValueLabel = bVal
        batSubLabel = bSub

        // 2. 圖表操作列 (Y: 382)
        let chartHeaderY: CGFloat = 382
        let chartLabel = NSTextField(labelWithString: "歷史趨勢")
        chartLabel.frame = NSRect(x: 2, y: chartHeaderY, width: 110, height: 22)
        chartLabel.font = NSFont.systemFont(ofSize: 13.5, weight: .bold)
        dashboardContainerView.addSubview(chartLabel)

        chartSegmentedControl = NSSegmentedControl(
            labels: ["總覽", "溫度", "濕度", "電壓"],
            trackingMode: .selectOne,
            target: self,
            action: #selector(handleChartSegmentChanged)
        )
        chartSegmentedControl.frame = NSRect(x: 120, y: chartHeaderY - 2, width: 310, height: 26)
        chartSegmentedControl.selectedSegment = 0
        dashboardContainerView.addSubview(chartSegmentedControl)

        rangePopUp = NSPopUpButton(frame: NSRect(x: 436, y: chartHeaderY - 2, width: 90, height: 26), pullsDown: false)
        rangePopUp.addItems(withTitles: ["6 小時", "24 小時", "7 天", "全部"])
        rangePopUp.selectItem(at: 1)
        rangePopUp.target = self
        rangePopUp.action = #selector(handleRangeChanged)
        dashboardContainerView.addSubview(rangePopUp)

        exportButton = NSButton(frame: NSRect(x: 532, y: chartHeaderY - 2, width: 86, height: 26))
        exportButton.title = "匯出 CSV"
        exportButton.bezelStyle = .rounded
        exportButton.target = self
        exportButton.action = #selector(handleExportCSV)
        dashboardContainerView.addSubview(exportButton)

        refreshButton = NSButton(frame: NSRect(x: 622, y: chartHeaderY - 2, width: 88, height: 26))
        refreshButton.title = "立即更新"
        refreshButton.bezelStyle = .rounded
        refreshButton.target = self
        refreshButton.action = #selector(handleRefreshClicked)
        dashboardContainerView.addSubview(refreshButton)

        // 3. 向量折線圖 (Y: 0, Height: 370)
        chartView = ChartView(frame: NSRect(x: 0, y: 0, width: 710, height: 370))
        chartView.timeRange = 24 * 3600
        dashboardContainerView.addSubview(chartView)

        reloadData()
    }

    private func makeMetricCard(
        x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat,
        category: String,
        accentColor: NSColor
    ) -> (NSView, NSTextField, NSTextField) {
        let card = NSView(frame: NSRect(x: x, y: y, width: w, height: h))
        card.wantsLayer = true
        card.layer?.cornerRadius = 12
        card.layer?.backgroundColor = NSColor(white: 1.0, alpha: 0.05).cgColor
        card.layer?.borderWidth = 1.0
        card.layer?.borderColor = NSColor(white: 1.0, alpha: 0.08).cgColor

        let headerLabel = NSTextField(labelWithString: category)
        headerLabel.frame = NSRect(x: 14, y: h - 25, width: w - 28, height: 16)
        headerLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        headerLabel.textColor = NSColor(white: 0.70, alpha: 1.0)
        card.addSubview(headerLabel)

        let valLabel = NSTextField(labelWithString: "--")
        valLabel.frame = NSRect(x: 12, y: 30, width: w - 24, height: 38)
        valLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 32, weight: .bold)
        valLabel.textColor = accentColor
        card.addSubview(valLabel)

        let subLabel = NSTextField(labelWithString: "載入中...")
        subLabel.frame = NSRect(x: 14, y: 10, width: w - 28, height: 16)
        subLabel.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        subLabel.textColor = NSColor(white: 0.70, alpha: 1.0)
        card.addSubview(subLabel)

        return (card, valLabel, subLabel)
    }

    // MARK: - 設定視圖 (Settings View)
    private let settingsWidth: CGFloat = 692

    private func setupSettingsView() {
        settingsScrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 710, height: 535))
        settingsScrollView.hasVerticalScroller = true
        settingsScrollView.autohidesScrollers = true
        settingsScrollView.drawsBackground = false
        mainContainer.addSubview(settingsScrollView)

        settingsContentView = FlippedView(frame: NSRect(x: 0, y: 0, width: settingsWidth, height: 700))
        settingsScrollView.documentView = settingsContentView

        var cursor: CGFloat = 4

        func button(_ title: String, _ width: CGFloat, _ action: Selector) -> NSButton {
            let b = NSButton(title: title, target: self, action: action)
            b.bezelStyle = .rounded
            b.frame.size = NSSize(width: width, height: 24)
            return b
        }
        func checkbox(_ action: Selector?) -> NSButton {
            let c = NSButton(checkboxWithTitle: "", target: action == nil ? nil : self, action: action)
            c.frame.size = NSSize(width: 18, height: 18)
            return c
        }
        func popUp(_ width: CGFloat) -> NSPopUpButton {
            let p = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: width, height: 24), pullsDown: false)
            return p
        }

        // 1. 更新與省電
        var card = beginSection("更新與省電", at: &cursor)
        intervalPopUp = popUp(200)
        let intervalPresets: [(String, Double)] = [
            ("30 秒", 30.0), ("1 分鐘", 60.0), ("3 分鐘", 180.0), ("5 分鐘 (預設)", 300.0),
            ("10 分鐘", 600.0), ("15 分鐘", 900.0), ("30 分鐘", 1800.0), ("1 小時", 3600.0),
            ("2 小時", 7200.0), ("自訂...", -1.0)
        ]
        for (t, sec) in intervalPresets {
            let item = NSMenuItem(title: t, action: #selector(handleSelectInterval), keyEquivalent: "")
            item.target = self
            item.representedObject = sec
            intervalPopUp.menu?.addItem(item)
        }
        customIntervalField = NSTextField(frame: NSRect(x: 0, y: 0, width: 96, height: 22))
        customIntervalField.placeholderString = "自訂分鐘"
        customIntervalField.alignment = .center
        customIntervalField.target = self
        customIntervalField.action = #selector(handleCustomIntervalEntered)
        addRow(to: card, title: "更新間隔", caption: "間隔越長越省電；自訂請輸入分鐘後按 Enter。",
               controls: [intervalPopUp, customIntervalField])
        endSection(card, at: &cursor)

        // 2. 狀態列
        card = beginSection("狀態列", at: &cursor)
        stylePopUp = popUp(200)
        let styles = ["雙行膠囊 (TMP / HUM)", "純數字雙行 (26.1° / 63%)", "橫向完整 (26°C  65%)", "僅溫度 (26°C)", "緊湊單行 (26.1° 65%)"]
        for (i, st) in styles.enumerated() {
            let item = NSMenuItem(title: st, action: #selector(handleSelectStyle), keyEquivalent: "")
            item.target = self
            item.tag = i
            stylePopUp.menu?.addItem(item)
        }
        addRow(to: card, title: "圖示樣式", caption: nil, controls: [stylePopUp])
        hideWhenDisconnectedCheckbox = checkbox(#selector(handleToggleHideWhenDisconnected))
        addRow(to: card, title: "僅連線時顯示", caption: "斷線或離家停機時隱藏狀態列圖示。", controls: [hideWhenDisconnectedCheckbox])
        endSection(card, at: &cursor)

        // 通知
        card = beginSection("通知", at: &cursor)
        lowBatteryCheckbox = checkbox(#selector(handleToggleLowBatteryNotification))
        addRow(to: card, title: "低電量通知", caption: "電量 ≤ 15% 或電壓 ≤ 2.60V 時提醒，每天最多一次。", controls: [lowBatteryCheckbox])

        humidityAlertCheckbox = checkbox(#selector(handleToggleHumidityAlert))
        addRow(to: card, title: "濕度警示", caption: "超出下方設定範圍時通知，持續超標每 3 小時再提醒。", controls: [humidityAlertCheckbox])

        func percentField() -> NSTextField {
            let f = NSTextField(frame: NSRect(x: 0, y: 0, width: 64, height: 22))
            f.alignment = .center
            f.target = self
            f.action = #selector(handleHumidityThresholdEntered)
            return f
        }
        humidityHighField = percentField()
        addRow(to: card, title: "濕度上限 (%)", caption: "高於此值時通知。輸入後按 Enter。", controls: [humidityHighField])
        humidityLowField = percentField()
        addRow(to: card, title: "濕度下限 (%)", caption: "低於此值時通知。輸入後按 Enter。", controls: [humidityLowField])
        endSection(card, at: &cursor)

        // 3. 居家感應
        card = beginSection("居家感應", at: &cursor)
        wifiCheckbox = checkbox(#selector(handleToggleWiFiOnly))
        addRow(to: card, title: "僅在指定 Wi-Fi 時連線", caption: "離開該網路時完全停止藍牙輪詢。", controls: [wifiCheckbox])

        wifiSSIDTextField = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 22))
        wifiSSIDTextField.placeholderString = "Wi-Fi 名稱 (SSID)"
        addRow(to: card, title: "Wi-Fi 名稱", caption: nil,
               controls: [wifiSSIDTextField, button("儲存", 56, #selector(handleSaveWiFiSSID)), button("清除", 56, #selector(handleClearWiFiSSID))])

        addRow(to: card, title: "使用目前連線的 Wi-Fi", caption: "將目前連上的 Wi-Fi 設為指定網路。",
               controls: [button("使用目前 Wi-Fi", 108, #selector(handleUseCurrentWiFi))])
        wifiHintLabel = card.lastCaption

        wifiBindGatewayCheckbox = checkbox(nil)
        wifiBindGatewayCheckbox.state = .on
        addRow(to: card, title: "同時比對路由器 MAC", caption: "閘道特徵檢測中...", controls: [wifiBindGatewayCheckbox])
        wifiGatewayInfoLabel = card.lastCaption

        geofenceCheckbox = checkbox(#selector(handleToggleGeofence))
        addRow(to: card, title: "GPS 地理圍欄", caption: "以粗略定位判斷是否在家，離家時停機。", controls: [geofenceCheckbox])

        geofenceRadiusPopUp = popUp(100)
        for r in [100.0, 200.0, 500.0, 1000.0] {
            let item = NSMenuItem(title: "\(Int(r)) 公尺", action: #selector(handleSelectRadius), keyEquivalent: "")
            item.target = self
            item.representedObject = r
            geofenceRadiusPopUp.menu?.addItem(item)
        }
        addRow(to: card, title: "感應半徑", caption: nil,
               controls: [geofenceRadiusPopUp, button("設為目前位置", 100, #selector(handleRecordHomeLocation)), button("清除", 56, #selector(handleClearHomeLocation))])

        presenceStatusBadge = NSTextField(frame: NSRect(x: 16, y: card.nextY + 6, width: settingsWidth - 32, height: 32))
        presenceStatusBadge.cell = PaddedLabelCell(textCell: "狀態：持續運作 (未啟用居家感應)")
        presenceStatusBadge.isEditable = false
        presenceStatusBadge.isSelectable = false
        presenceStatusBadge.isBordered = false
        presenceStatusBadge.drawsBackground = false
        presenceStatusBadge.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        presenceStatusBadge.wantsLayer = true
        presenceStatusBadge.layer?.cornerRadius = 8
        presenceStatusBadge.layer?.borderWidth = 1.0
        card.addSubview(presenceStatusBadge)
        card.nextY += 46
        endSection(card, at: &cursor)

        // 4. 版本更新
        card = beginSection("版本更新", at: &cursor)
        updateButton = button("檢查更新", 108, #selector(handleUpdateButton))
        addRow(to: card, title: "目前版本 \(UpdateChecker.shared.currentVersion)", caption: "查詢 GitHub 上是否有新版本。",
               controls: [updateButton])
        updateStatusLabel = card.lastCaption
        autoUpdateCheckbox = checkbox(#selector(handleToggleAutoUpdate))
        autoUpdateCheckbox.state = UpdateChecker.shared.autoCheckEnabled ? .on : .off
        addRow(to: card, title: "自動檢查更新", caption: "每天啟動時檢查一次，有新版本會標示在「設定」。", controls: [autoUpdateCheckbox])
        endSection(card, at: &cursor)

        // 5. 關於
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "-"
        let about = NSTextField(labelWithString: "MijiaTempBar v\(version)  ·  米家藍牙溫濕度計 2 (LYWSD03MMC)  ·  github.com/liaw-boy/mijia-temp-bar")
        about.frame = NSRect(x: 16, y: cursor + 2, width: settingsWidth - 32, height: 16)
        about.font = NSFont.systemFont(ofSize: 11)
        about.textColor = NSColor(white: 0.5, alpha: 1.0)
        settingsContentView.addSubview(about)
        cursor += 28

        settingsContentView.frame.size.height = max(cursor, 535)
    }

    /// 設定區塊容器：標題 + 圓角卡片，列由上往下排
    private final class SettingsSection: FlippedView {
        var nextY: CGFloat = 4
        var lastCaption: NSTextField?
    }

    private func beginSection(_ title: String, at cursor: inout CGFloat) -> SettingsSection {
        let header = NSTextField(labelWithString: title)
        header.frame = NSRect(x: 16, y: cursor, width: 300, height: 16)
        header.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        header.textColor = NSColor(white: 0.62, alpha: 1.0)
        settingsContentView.addSubview(header)
        cursor += 22

        let card = SettingsSection(frame: NSRect(x: 0, y: cursor, width: settingsWidth, height: 40))
        card.wantsLayer = true
        card.layer?.cornerRadius = 10
        card.layer?.backgroundColor = NSColor(white: 1.0, alpha: 0.05).cgColor
        card.layer?.borderWidth = 1.0
        card.layer?.borderColor = NSColor(white: 1.0, alpha: 0.08).cgColor
        settingsContentView.addSubview(card)
        return card
    }

    private func endSection(_ card: SettingsSection, at cursor: inout CGFloat) {
        card.frame.size.height = card.nextY + 4
        cursor += card.frame.height + 18
    }

    /// 單列 (統一規格)：左側標題 + 一行說明，右側控制項由右往左靠齊。
    /// 說明只佔控制項左側的剩餘寬度，一律單行；訊息過長以「…」截斷並放進 tooltip。
    private func addRow(to card: SettingsSection, title: String, caption: String?, controls: [NSView]) {
        let rowH: CGFloat = 52
        let inset: CGFloat = 16
        let y = card.nextY
        if card.nextY > 4 {
            let sep = NSBox(frame: NSRect(x: inset, y: y, width: settingsWidth - inset * 2, height: 1))
            sep.boxType = .separator
            card.addSubview(sep)
        }

        let controlsWidth = controls.reduce(0) { $0 + $1.frame.width } + CGFloat(max(0, controls.count - 1)) * 8
        let textWidth = settingsWidth - inset * 2 - controlsWidth - 16

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        titleLabel.textColor = NSColor(white: 0.95, alpha: 1.0)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.frame = NSRect(x: inset, y: y + (caption == nil ? (rowH - 18) / 2 : 9), width: textWidth, height: 18)
        card.addSubview(titleLabel)

        let captionLabel = NSTextField(labelWithString: caption ?? "")
        captionLabel.font = NSFont.systemFont(ofSize: 11)
        captionLabel.textColor = NSColor(white: 0.58, alpha: 1.0)
        captionLabel.lineBreakMode = .byTruncatingTail
        captionLabel.frame = NSRect(x: inset, y: y + 28, width: textWidth, height: 16)
        captionLabel.isHidden = (caption == nil)
        card.addSubview(captionLabel)
        card.lastCaption = captionLabel

        var right = settingsWidth - inset
        for c in controls.reversed() {
            let w = c.frame.width
            right -= w
            c.frame.origin = NSPoint(x: right, y: y + (rowH - c.frame.height) / 2)
            card.addSubview(c)
            right -= 8
        }
        card.nextY += rowH
    }

    // MARK: - 分頁切換 (Tab Navigation)
    @objc private func handleTopTabChanged() {
        let tab = WindowTab(rawValue: topSegmentedControl.selectedSegment) ?? .dashboard
        switchTab(tab)
    }

    /// 取出視窗內容，改由狀態列面板承載 (視窗本身不再顯示)
    func detachContentView() -> NSView? {
        guard let content = window?.contentView else { return nil }
        window?.contentView = NSView()
        return content
    }

    func show(tab: WindowTab = .dashboard) {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        switchTab(tab)
    }

    func switchTab(_ tab: WindowTab) {
        topSegmentedControl.selectedSegment = tab.rawValue
        switch tab {
        case .dashboard:
            dashboardContainerView.isHidden = false
            settingsScrollView.isHidden = true
            lastUpdateLabel.isHidden = false
            window?.title = "米家藍牙溫濕度計 2 (LYWSD03MMC) - 數據圖表"
            reloadData()
        case .settings:
            dashboardContainerView.isHidden = true
            settingsScrollView.isHidden = false
            lastUpdateLabel.isHidden = true
            window?.title = "米家藍牙溫濕度計 2 (LYWSD03MMC) - 設定"
            reloadSettingsValues()
        }
    }

    // MARK: - 設定頁面數值載入
    func reloadSettingsValues() {
        // Wi-Fi 狀態
        wifiCheckbox.state = LocationGatekeeper.shared.isWiFiOnlyEnabled ? .on : .off
        wifiSSIDTextField.stringValue = LocationGatekeeper.shared.targetWiFiSSID ?? ""
        if wifiSSIDTextField.stringValue.isEmpty, let curSSID = CWWiFiClient.shared().interface()?.ssid(), !curSSID.isEmpty {
            wifiSSIDTextField.placeholderString = "Wi-Fi 名稱 (SSID)"
        } else {
            wifiSSIDTextField.placeholderString = "Wi-Fi 名稱 (SSID)"
        }

        let gateway = LocationGatekeeper.shared.getCurrentGatewayInfo()
        if let mac = gateway.mac {
            wifiGatewayInfoLabel.stringValue = "目前偵測到的閘道 MAC: \(mac) (IP: \(gateway.ip ?? "未知"))"
        } else {
            wifiGatewayInfoLabel.stringValue = "目前閘道: 尚未連上區域網路"
        }
        wifiBindGatewayCheckbox.state = (LocationGatekeeper.shared.homeGatewayMAC != nil) ? .on : .off

        // GPS 地理圍欄
        geofenceCheckbox.state = LocationGatekeeper.shared.isEnabled ? .on : .off
        let currentRadius = LocationGatekeeper.shared.geofenceRadius
        if let idx = geofenceRadiusPopUp.menu?.items.firstIndex(where: { abs(($0.representedObject as? Double ?? 0) - currentRadius) < 1.0 }) {
            geofenceRadiusPopUp.selectItem(at: idx)
        }

        // 間隔頻率
        let savedSec = UserDefaults.standard.double(forKey: "RefreshIntervalSeconds")
        let currentSec = savedSec > 0 ? savedSec : 300.0
        var matched = false
        for item in intervalPopUp.itemArray {
            if let s = item.representedObject as? Double, abs(s - currentSec) < 0.1 {
                intervalPopUp.select(item)
                matched = true
                break
            }
        }
        if !matched {
            let lastItem = intervalPopUp.itemArray.last
            intervalPopUp.select(lastItem)
            let mins = currentSec / 60.0
            let text = mins.truncatingRemainder(dividingBy: 1) == 0 ? String(format: "%.0f", mins) : String(format: "%.1f", mins)
            lastItem?.title = "自訂 (\(text) 分鐘)"
            customIntervalField.stringValue = text
        } else {
            intervalPopUp.itemArray.last?.title = "自訂..."
            customIntervalField.stringValue = ""
        }

        // 樣式
        let currentStyle = UserDefaults.standard.integer(forKey: "DisplayStyle")
        stylePopUp.selectItem(withTag: currentStyle)

        // 隱藏與通知
        hideWhenDisconnectedCheckbox.state = UserDefaults.standard.bool(forKey: "HideWhenDisconnected") ? .on : .off
        lowBatteryCheckbox.state = NotificationManager.shared.isEnabled ? .on : .off
        humidityAlertCheckbox.state = NotificationManager.shared.isHumidityAlertEnabled ? .on : .off
        humidityHighField.stringValue = "\(NotificationManager.shared.humidityHigh)"
        humidityLowField.stringValue = "\(NotificationManager.shared.humidityLow)"
        humidityHighField.isEnabled = NotificationManager.shared.isHumidityAlertEnabled
        humidityLowField.isEnabled = NotificationManager.shared.isHumidityAlertEnabled

        updatePresenceStatus()
    }

    func updatePresenceStatus() {
        guard presenceStatusBadge != nil else { return }

        if LocationGatekeeper.shared.isWiFiOnlyEnabled {
            let target = LocationGatekeeper.shared.targetWiFiSSID ?? "未指定"
            if LocationGatekeeper.shared.isInHomeArea {
                presenceStatusBadge.stringValue = "狀態：已連上指定 Wi-Fi [\(target)] · 藍牙輪詢正常運作中"
                presenceStatusBadge.layer?.backgroundColor = NSColor(red: 0.10, green: 0.55, blue: 0.25, alpha: 0.35).cgColor
                presenceStatusBadge.layer?.borderColor = NSColor(red: 0.20, green: 0.85, blue: 0.40, alpha: 0.6).cgColor
                presenceStatusBadge.textColor = NSColor(red: 0.35, green: 0.95, blue: 0.55, alpha: 1.0)
            } else {
                presenceStatusBadge.stringValue = "狀態：未連線至指定 Wi-Fi [\(target)] · 已徹底休眠停機 (0 耗電)"
                presenceStatusBadge.layer?.backgroundColor = NSColor(red: 0.60, green: 0.35, blue: 0.05, alpha: 0.35).cgColor
                presenceStatusBadge.layer?.borderColor = NSColor(red: 0.95, green: 0.60, blue: 0.10, alpha: 0.6).cgColor
                presenceStatusBadge.textColor = NSColor(red: 1.0, green: 0.75, blue: 0.30, alpha: 1.0)
            }
        } else if LocationGatekeeper.shared.isEnabled {
            let isHome = LocationGatekeeper.shared.isInHomeArea
            if let dist = LocationGatekeeper.shared.lastKnownDistance {
                if isHome {
                    presenceStatusBadge.stringValue = String(format: "狀態：已在居家大範圍內 (距家約 %.0fm) · 正常運作", dist)
                    presenceStatusBadge.layer?.backgroundColor = NSColor(red: 0.10, green: 0.55, blue: 0.25, alpha: 0.35).cgColor
                    presenceStatusBadge.layer?.borderColor = NSColor(red: 0.20, green: 0.85, blue: 0.40, alpha: 0.6).cgColor
                    presenceStatusBadge.textColor = NSColor(red: 0.35, green: 0.95, blue: 0.55, alpha: 1.0)
                } else {
                    presenceStatusBadge.stringValue = String(format: "狀態：已超出居家大範圍 (距家約 %.0fm) · 藍牙停機休眠中", dist)
                    presenceStatusBadge.layer?.backgroundColor = NSColor(red: 0.60, green: 0.35, blue: 0.05, alpha: 0.35).cgColor
                    presenceStatusBadge.layer?.borderColor = NSColor(red: 0.95, green: 0.60, blue: 0.10, alpha: 0.6).cgColor
                    presenceStatusBadge.textColor = NSColor(red: 1.0, green: 0.75, blue: 0.30, alpha: 1.0)
                }
            } else {
                presenceStatusBadge.stringValue = isHome ? "狀態：已在居家大範圍內 · 正常運作" : "狀態：超出居家大範圍 · 藍牙停機休眠中"
                presenceStatusBadge.layer?.backgroundColor = NSColor(red: 0.10, green: 0.55, blue: 0.25, alpha: 0.35).cgColor
                presenceStatusBadge.layer?.borderColor = NSColor(red: 0.20, green: 0.85, blue: 0.40, alpha: 0.6).cgColor
                presenceStatusBadge.textColor = NSColor(red: 0.35, green: 0.95, blue: 0.55, alpha: 1.0)
            }
        } else {
            presenceStatusBadge.stringValue = "狀態：持續運作模式 (未開啟在席感應，固定週期輪詢)"
            presenceStatusBadge.layer?.backgroundColor = NSColor(white: 0.20, alpha: 0.35).cgColor
            presenceStatusBadge.layer?.borderColor = NSColor(white: 0.50, alpha: 0.4).cgColor
            presenceStatusBadge.textColor = NSColor(white: 0.80, alpha: 1.0)
        }
    }

    // MARK: - 設定頁面動作處理
    @objc private func handleToggleWiFiOnly() {
        if LocationGatekeeper.shared.targetWiFiSSID == nil {
            handleSaveWiFiSSID()
            return
        }
        LocationGatekeeper.shared.isWiFiOnlyEnabled.toggle()
        wifiCheckbox.state = LocationGatekeeper.shared.isWiFiOnlyEnabled ? .on : .off
        updatePresenceStatus()
        onSettingsChanged?()
    }

    /// 以目前連線的 Wi-Fi 直接綁定 (不跳額外視窗，訊息顯示在該列說明)
    @objc private func handleUseCurrentWiFi() {
        wifiHintLabel.textColor = NSColor(white: 0.58, alpha: 1.0)
        wifiHintLabel.stringValue = "讀取目前 Wi-Fi 中..."
        LocationGatekeeper.shared.readCurrentSSID { [weak self] ssid, error in
            guard let self = self else { return }
            guard let ssid = ssid else {
                self.wifiHintLabel.stringValue = error ?? "讀不到目前的 Wi-Fi"
                self.wifiHintLabel.textColor = NSColor(red: 1.0, green: 0.65, blue: 0.20, alpha: 1.0)
                return
            }
            self.wifiSSIDTextField.stringValue = ssid
            LocationGatekeeper.shared.setTargetWiFi(ssid: ssid, bindCurrentGateway: self.wifiBindGatewayCheckbox.state == .on)
            self.wifiHintLabel.stringValue = "已綁定目前的 Wi-Fi：\(ssid)"
            self.reloadSettingsValues()
            self.onSettingsChanged?()
        }
    }

    // MARK: - 版本更新
    @objc private func handleUpdateButton() {
        if let url = availableUpdateURL {
            NSWorkspace.shared.open(url)
            return
        }
        updateStatusLabel.textColor = NSColor(white: 0.58, alpha: 1.0)
        updateStatusLabel.stringValue = "檢查中..."
        updateButton.isEnabled = false
        UpdateChecker.shared.check { [weak self] status in
            self?.showUpdateStatus(status)
        }
    }

    @objc private func handleToggleAutoUpdate() {
        UpdateChecker.shared.autoCheckEnabled = (autoUpdateCheckbox.state == .on)
    }

    func showUpdateStatus(_ status: UpdateStatus) {
        updateButton.isEnabled = true
        switch status {
        case .upToDate(let current):
            availableUpdateURL = nil
            updateButton.title = "檢查更新"
            updateStatusLabel.stringValue = "已是最新版本 (\(current))。"
            updateStatusLabel.textColor = NSColor(red: 0.25, green: 0.88, blue: 0.50, alpha: 1.0)
            topSegmentedControl.setLabel("設定", forSegment: 1)
        case .available(let version, let url):
            availableUpdateURL = url
            updateButton.title = "前往下載"
            updateStatusLabel.stringValue = "有新版本 \(version)，請前往 GitHub 下載。"
            updateStatusLabel.textColor = NSColor(red: 1.0, green: 0.65, blue: 0.20, alpha: 1.0)
            topSegmentedControl.setLabel("設定 ●", forSegment: 1)
        case .failed(let message):
            availableUpdateURL = nil
            updateButton.title = "檢查更新"
            updateStatusLabel.stringValue = message
            updateStatusLabel.textColor = NSColor(red: 1.0, green: 0.65, blue: 0.20, alpha: 1.0)
        }
    }

    @objc private func handleSaveWiFiSSID() {
        var ssid = wifiSSIDTextField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if ssid.isEmpty, let curSSID = CWWiFiClient.shared().interface()?.ssid(), !curSSID.isEmpty {
            ssid = curSSID
            wifiSSIDTextField.stringValue = ssid
        }

        guard !ssid.isEmpty, ssid.utf8.count <= 32 else {
            let alert = NSAlert()
            alert.messageText = "請輸入有效的 Wi-Fi 名稱"
            alert.informativeText = "請在輸入框填入您家中的 Wi-Fi 名稱 (SSID)。"
            alert.runModal()
            return
        }

        let bindGateway = (wifiBindGatewayCheckbox.state == .on)
        LocationGatekeeper.shared.setTargetWiFi(ssid: ssid, bindCurrentGateway: bindGateway)
        reloadSettingsValues()
        onSettingsChanged?()

        let alert = NSAlert()
        alert.messageText = "Wi-Fi 綁定成功"
        alert.informativeText = "已綁定 Wi-Fi: \(ssid)\n現在僅在連上該 Wi-Fi 時才會與溫濕度計連線；離網或切換其他網路時將徹底休眠停機。"
        alert.runModal()
    }

    @objc private func handleClearWiFiSSID() {
        LocationGatekeeper.shared.clearWiFiSettings()
        wifiSSIDTextField.stringValue = ""
        reloadSettingsValues()
        onSettingsChanged?()
    }

    @objc private func handleToggleGeofence() {
        if !LocationGatekeeper.shared.hasHomeLocation {
            handleRecordHomeLocation()
            return
        }
        LocationGatekeeper.shared.isEnabled.toggle()
        geofenceCheckbox.state = LocationGatekeeper.shared.isEnabled ? .on : .off
        updatePresenceStatus()
        onSettingsChanged?()
    }

    @objc private func handleRecordHomeLocation() {
        LocationGatekeeper.shared.recordCurrentAsHome { [weak self] success, msg in
            DispatchQueue.main.async {
                self?.reloadSettingsValues()
                self?.onSettingsChanged?()
                let alert = NSAlert()
                alert.messageText = success ? "居家位置設定成功" : "設定提示"
                alert.informativeText = msg
                alert.runModal()
            }
        }
    }

    @objc private func handleClearHomeLocation() {
        LocationGatekeeper.shared.clearHomeLocation()
        reloadSettingsValues()
        onSettingsChanged?()
    }

    @objc private func handleSelectRadius() {
        guard let r = geofenceRadiusPopUp.selectedItem?.representedObject as? Double else { return }
        LocationGatekeeper.shared.geofenceRadius = r
        onSettingsChanged?()
    }

    @objc private func handleSelectInterval() {
        guard let sec = intervalPopUp.selectedItem?.representedObject as? Double else { return }
        if sec < 0 {
            // 自訂：游標移到同列的輸入欄，不開額外視窗
            customIntervalField.window?.makeFirstResponder(customIntervalField)
            return
        }
        onIntervalChanged?(sec)
        reloadSettingsValues()
        onSettingsChanged?()
    }

    @objc private func handleCustomIntervalEntered() {
        let text = customIntervalField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        // 0.5 分鐘 ~ 24 小時；無效輸入就還原成目前設定
        if let mins = Double(text), mins >= 0.5, mins <= 1440 {
            onIntervalChanged?(mins * 60.0)
            onSettingsChanged?()
        }
        reloadSettingsValues()
        customIntervalField.window?.makeFirstResponder(nil)
    }

    @objc private func handleSelectStyle() {
        let tag = stylePopUp.selectedTag()
        if let style = DisplayStyle(rawValue: tag) {
            onStyleChanged?(style)
            onSettingsChanged?()
        }
    }

    @objc private func handleToggleHideWhenDisconnected() {
        let hide = (hideWhenDisconnectedCheckbox.state == .on)
        onHideWhenDisconnectedChanged?(hide)
        onSettingsChanged?()
    }

    @objc private func handleToggleHumidityAlert() {
        NotificationManager.shared.isHumidityAlertEnabled = (humidityAlertCheckbox.state == .on)
        reloadSettingsValues()
        onSettingsChanged?()
    }

    /// 上限需大於下限且皆在 0~100；輸入無效就還原成目前設定
    @objc private func handleHumidityThresholdEntered() {
        let high = Int(humidityHighField.stringValue.trimmingCharacters(in: .whitespaces))
        let low = Int(humidityLowField.stringValue.trimmingCharacters(in: .whitespaces))
        if let h = high, let l = low, (0...100).contains(h), (0...100).contains(l), l < h {
            NotificationManager.shared.humidityHigh = h
            NotificationManager.shared.humidityLow = l
        }
        reloadSettingsValues()
        humidityHighField.window?.makeFirstResponder(nil)
    }

    @objc private func handleToggleLowBatteryNotification() {
        NotificationManager.shared.isEnabled = (lowBatteryCheckbox.state == .on)
        onSettingsChanged?()
    }

    // MARK: - 數據同步與更新 (Data Update)
    func updateReading(_ r: SensorReading) {
        tempValueLabel.stringValue = String(format: "%.1f°C", r.temperature)
        let minT = HistoryManager.shared.minTemperature ?? r.temperature
        let maxT = HistoryManager.shared.maxTemperature ?? r.temperature
        tempSubLabel.stringValue = String(format: "今日 %.1f° ~ %.1f°", minT, maxT)

        humValueLabel.stringValue = String(format: "%.0f%%", r.humidity)
        let comfort = (r.humidity >= 40 && r.humidity <= 65) ? "舒適" : (r.humidity > 65 ? "偏濕" : "偏乾")
        humSubLabel.stringValue = comfort

        batValueLabel.stringValue = String(format: "%d%%", r.batteryPercent)
        if r.batteryPercent <= 15 || r.voltage <= 2.60 {
            batSubLabel.stringValue = String(format: "%.3f V · 電量過低，請更換電池", r.voltage)
            batSubLabel.textColor = NSColor(red: 1.0, green: 0.38, blue: 0.38, alpha: 1.0)
        } else {
            batSubLabel.stringValue = String(format: "%.3f V · 正常", r.voltage)
            batSubLabel.textColor = NSColor(white: 0.70, alpha: 1.0)
        }

        deviceView.temperature = r.temperature
        deviceView.humidity = r.humidity
        deviceView.batteryPercent = r.batteryPercent

        let df = DateFormatter()
        df.dateFormat = "HH:mm:ss"
        lastUpdateLabel.stringValue = "最後讀取: \(df.string(from: r.lastUpdated))"

        reloadData()
    }

    func updateStatusText(_ status: String) {
        statusDotLabel.stringValue = "● \(status)"
        if status.contains("正常") || status.contains("休眠") {
            statusDotLabel.textColor = NSColor(red: 0.25, green: 0.88, blue: 0.50, alpha: 1.0)
        } else if status.contains("連線中") || status.contains("搜尋") {
            statusDotLabel.textColor = NSColor(red: 0.35, green: 0.75, blue: 1.0, alpha: 1.0)
        } else {
            statusDotLabel.textColor = NSColor(red: 1.0, green: 0.65, blue: 0.20, alpha: 1.0)
        }
    }

    func reloadData() {
        let pts = HistoryManager.shared.points
        chartView.updatePoints(pts)
    }

    @objc private func handleRangeChanged() {
        let ranges: [TimeInterval?] = [6 * 3600, 24 * 3600, 7 * 86400, nil]
        let i = rangePopUp.indexOfSelectedItem
        if ranges.indices.contains(i) { chartView.timeRange = ranges[i] }
    }

    @objc private func handleChartSegmentChanged() {
        switch chartSegmentedControl.selectedSegment {
        case 0: chartView.dataType = .overview
        case 1: chartView.dataType = .temperature
        case 2: chartView.dataType = .humidity
        case 3: chartView.dataType = .voltage
        default: break
        }
    }

    @objc private func handleRefreshClicked() {
        onRefreshRequested?()
    }

    @objc private func handleExportCSV() {
        let savePanel = NSSavePanel()
        savePanel.title = "匯出溫濕度歷史數據"
        savePanel.allowedContentTypes = [.commaSeparatedText]
        savePanel.nameFieldStringValue = "mijia_temp_history_\(Int(Date().timeIntervalSince1970)).csv"

        savePanel.begin { response in
            guard response == .OK, let url = savePanel.url else { return }
            do {
                try HistoryManager.shared.exportCSV(to: url)
                let alert = NSAlert()
                alert.messageText = "匯出成功"
                alert.informativeText = "數據已成功儲存至:\n\(url.path)"
                alert.runModal()
            } catch {
                let alert = NSAlert()
                alert.messageText = "匯出失敗"
                alert.informativeText = error.localizedDescription
                alert.runModal()
            }
        }
    }
}

/// 狀態列面板：直接承載儀表板內容
final class DashboardPanelViewController: NSViewController {
    /// 內容以 750x630 的座標排版，整體縮放成較小的面板
    static let contentSize = NSSize(width: 750, height: 630)
    static let panelScale: CGFloat = 0.84
    static let panelSize = NSSize(width: contentSize.width * panelScale, height: contentSize.height * panelScale)

    private let content: NSView

    init(content: NSView) {
        self.content = content
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        content.frame = NSRect(origin: .zero, size: Self.panelSize)
        content.setBoundsSize(Self.contentSize)
        view = content
    }
}
