import AppKit
import CoreWLAN

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
    private var deviceImageView: NSImageView!
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
    private var pointsCountLabel: NSTextField!
    private var refreshButton: NSButton!
    private var exportButton: NSButton!

    // === 設定頁面元件 ===
    // 1. 網路與在席感應
    private var wifiCheckbox: NSButton!
    private var wifiSSIDTextField: NSTextField!
    private var wifiBindGatewayCheckbox: NSButton!
    private var wifiGatewayInfoLabel: NSTextField!
    private var geofenceCheckbox: NSButton!
    private var geofenceRadiusPopUp: NSPopUpButton!
    private var presenceStatusBadge: NSTextField!

    // 2. 頻率與省電
    private var intervalPopUp: NSPopUpButton!

    // 3. 外觀與通知
    private var stylePopUp: NSPopUpButton!
    private var hideWhenDisconnectedCheckbox: NSButton!
    private var lowBatteryCheckbox: NSButton!

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
        win.title = "米家藍牙溫濕度計 2 (LYWSD03MMC) - 即時儀表板與圖表"
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
        visualEffect.blendingMode = .behindWindow
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

        // 設備圖示外框 (34x34)
        let imgBox = NSView(frame: NSRect(x: 0, y: 6, width: 36, height: 36))
        imgBox.wantsLayer = true
        imgBox.layer?.cornerRadius = 8
        imgBox.layer?.backgroundColor = NSColor(white: 0.12, alpha: 0.8).cgColor
        imgBox.layer?.borderWidth = 1.0
        imgBox.layer?.borderColor = NSColor(white: 1.0, alpha: 0.12).cgColor
        headerBar.addSubview(imgBox)

        deviceImageView = NSImageView(frame: NSRect(x: 2, y: 2, width: 32, height: 32))
        deviceImageView.imageScaling = .scaleProportionallyUpOrDown
        if let bundledImgPath = Bundle.main.path(forResource: "device", ofType: "png"),
           let img = NSImage(contentsOfFile: bundledImgPath) {
            deviceImageView.image = img
        } else if let localImg = NSImage(contentsOfFile: "/Users/boywei/project_code/mijia-temp-bar/Resources/device.png") {
            deviceImageView.image = localImg
        }
        imgBox.addSubview(deviceImageView)

        // 標題與型號標章
        titleLabel = NSTextField(labelWithString: "米家藍牙溫濕度計 2")
        titleLabel.frame = NSRect(x: 46, y: 24, width: 150, height: 20)
        titleLabel.font = NSFont.systemFont(ofSize: 14.5, weight: .bold)
        headerBar.addSubview(titleLabel)

        modelBadgeLabel = NSTextField(labelWithString: "LYWSD03MMC")
        modelBadgeLabel.frame = NSRect(x: 198, y: 26, width: 85, height: 16)
        modelBadgeLabel.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .semibold)
        modelBadgeLabel.textColor = NSColor(red: 0.35, green: 0.75, blue: 1.0, alpha: 1.0)
        headerBar.addSubview(modelBadgeLabel)

        statusDotLabel = NSTextField(labelWithString: "● 連線正常 (省電輪詢模式)")
        statusDotLabel.frame = NSRect(x: 46, y: 6, width: 190, height: 16)
        statusDotLabel.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        statusDotLabel.textColor = NSColor(red: 0.25, green: 0.88, blue: 0.50, alpha: 1.0)
        headerBar.addSubview(statusDotLabel)

        // 中央頂部切換導覽分頁 (數據圖表 vs 偏好設定)
        topSegmentedControl = NSSegmentedControl(
            labels: ["📊 數據圖表", "⚙️ 偏好設定"],
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
            icon: "🌡️", category: "TEMPERATURE · 溫度",
            accentColor: NSColor(red: 1.0, green: 0.48, blue: 0.12, alpha: 1.0),
            bgTint: NSColor(red: 1.0, green: 0.45, blue: 0.10, alpha: 0.08),
            borderTint: NSColor(red: 1.0, green: 0.48, blue: 0.12, alpha: 0.25)
        )
        dashboardContainerView.addSubview(card1)
        tempValueLabel = tVal
        tempSubLabel = tSub

        // 卡片 2：濕度
        let (card2, hVal, hSub) = makeMetricCard(
            x: 242, y: cardY, w: cardW, h: cardH,
            icon: "💧", category: "HUMIDITY · 相對濕度",
            accentColor: NSColor(red: 0.05, green: 0.68, blue: 1.0, alpha: 1.0),
            bgTint: NSColor(red: 0.05, green: 0.60, blue: 0.95, alpha: 0.08),
            borderTint: NSColor(red: 0.05, green: 0.68, blue: 1.0, alpha: 0.25)
        )
        dashboardContainerView.addSubview(card2)
        humValueLabel = hVal
        humSubLabel = hSub

        // 卡片 3：電池電量
        let (card3, bVal, bSub) = makeMetricCard(
            x: 484, y: cardY, w: cardW, h: cardH,
            icon: "🔋", category: "BATTERY · 電池狀態",
            accentColor: NSColor(red: 0.10, green: 0.88, blue: 0.52, alpha: 1.0),
            bgTint: NSColor(red: 0.10, green: 0.80, blue: 0.45, alpha: 0.08),
            borderTint: NSColor(red: 0.10, green: 0.88, blue: 0.52, alpha: 0.25)
        )
        dashboardContainerView.addSubview(card3)
        batValueLabel = bVal
        batSubLabel = bSub

        // 2. 圖表操作列 (Y: 382)
        let chartHeaderY: CGFloat = 382
        let chartLabel = NSTextField(labelWithString: "歷史趨勢折線圖")
        chartLabel.frame = NSRect(x: 2, y: chartHeaderY, width: 110, height: 22)
        chartLabel.font = NSFont.systemFont(ofSize: 13.5, weight: .bold)
        dashboardContainerView.addSubview(chartLabel)

        chartSegmentedControl = NSSegmentedControl(
            labels: ["📊 綜合總覽", "🌡️ 溫度走勢", "💧 濕度走勢", "🔋 電壓回彈"],
            trackingMode: .selectOne,
            target: self,
            action: #selector(handleChartSegmentChanged)
        )
        chartSegmentedControl.frame = NSRect(x: 120, y: chartHeaderY - 2, width: 310, height: 26)
        chartSegmentedControl.selectedSegment = 0
        dashboardContainerView.addSubview(chartSegmentedControl)

        pointsCountLabel = NSTextField(labelWithString: "共 0 個採樣點")
        pointsCountLabel.frame = NSRect(x: 435, y: chartHeaderY + 2, width: 90, height: 18)
        pointsCountLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .medium)
        pointsCountLabel.alignment = .right
        pointsCountLabel.textColor = NSColor(white: 0.60, alpha: 1.0)
        dashboardContainerView.addSubview(pointsCountLabel)

        exportButton = NSButton(frame: NSRect(x: 532, y: chartHeaderY - 2, width: 86, height: 26))
        exportButton.title = "⤓ 匯出 CSV"
        exportButton.bezelStyle = .rounded
        exportButton.target = self
        exportButton.action = #selector(handleExportCSV)
        dashboardContainerView.addSubview(exportButton)

        refreshButton = NSButton(frame: NSRect(x: 622, y: chartHeaderY - 2, width: 88, height: 26))
        refreshButton.title = "⟳ 立即刷新"
        refreshButton.bezelStyle = .rounded
        refreshButton.target = self
        refreshButton.action = #selector(handleRefreshClicked)
        dashboardContainerView.addSubview(refreshButton)

        // 3. 向量折線圖 (Y: 0, Height: 370)
        chartView = ChartView(frame: NSRect(x: 0, y: 0, width: 710, height: 370))
        dashboardContainerView.addSubview(chartView)

        reloadData()
    }

    private func makeMetricCard(
        x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat,
        icon: String, category: String,
        accentColor: NSColor, bgTint: NSColor, borderTint: NSColor
    ) -> (NSView, NSTextField, NSTextField) {
        let card = NSView(frame: NSRect(x: x, y: y, width: w, height: h))
        card.wantsLayer = true
        card.layer?.cornerRadius = 12
        card.layer?.backgroundColor = bgTint.cgColor
        card.layer?.borderWidth = 1.0
        card.layer?.borderColor = borderTint.cgColor

        let headerLabel = NSTextField(labelWithString: "\(icon) \(category)")
        headerLabel.frame = NSRect(x: 14, y: h - 25, width: w - 28, height: 16)
        headerLabel.font = NSFont.systemFont(ofSize: 10.5, weight: .bold)
        headerLabel.textColor = accentColor.withAlphaComponent(0.9)
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
    private func setupSettingsView() {
        settingsScrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 710, height: 535))
        settingsScrollView.hasVerticalScroller = true
        settingsScrollView.autohidesScrollers = true
        settingsScrollView.drawsBackground = false
        mainContainer.addSubview(settingsScrollView)

        let totalH: CGFloat = 620
        settingsContentView = FlippedView(frame: NSRect(x: 0, y: 0, width: 692, height: totalH))
        settingsScrollView.documentView = settingsContentView

        // --- Card 1: 📶 網路與居家在席感應 ---
        let (card1, v1) = makeSettingsCard(y: 8, h: 220, title: "📶 網路與居家在席感應 (Wi-Fi SSID 綁定 & GPS 大範圍圍欄)")
        settingsContentView.addSubview(card1)

        wifiCheckbox = NSButton(checkboxWithTitle: "僅在連線至指定 Wi-Fi (SSID) 時啟用連線 (離網或切換網路徹底休眠停機 · 0 耗電)", target: self, action: #selector(handleToggleWiFiOnly))
        wifiCheckbox.frame = NSRect(x: 16, y: 36, width: 660, height: 20)
        v1.addSubview(wifiCheckbox)

        let wifiLabel = NSTextField(labelWithString: "指定 Wi-Fi 名稱 (SSID):")
        wifiLabel.frame = NSRect(x: 36, y: 64, width: 145, height: 18)
        wifiLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        v1.addSubview(wifiLabel)

        wifiSSIDTextField = NSTextField(frame: NSRect(x: 184, y: 62, width: 220, height: 22))
        wifiSSIDTextField.placeholderString = "例如: Home_5G"
        v1.addSubview(wifiSSIDTextField)

        let wifiSaveBtn = NSButton(frame: NSRect(x: 410, y: 61, width: 88, height: 24))
        wifiSaveBtn.title = "儲存 Wi-Fi"
        wifiSaveBtn.bezelStyle = .rounded
        wifiSaveBtn.target = self
        wifiSaveBtn.action = #selector(handleSaveWiFiSSID)
        v1.addSubview(wifiSaveBtn)

        let wifiClearBtn = NSButton(frame: NSRect(x: 502, y: 61, width: 64, height: 24))
        wifiClearBtn.title = "清除"
        wifiClearBtn.bezelStyle = .rounded
        wifiClearBtn.target = self
        wifiClearBtn.action = #selector(handleClearWiFiSSID)
        v1.addSubview(wifiClearBtn)

        wifiBindGatewayCheckbox = NSButton(checkboxWithTitle: "鎖定路由器硬體特徵 (MAC) 作為免定位權限雙重保險", target: nil, action: nil)
        wifiBindGatewayCheckbox.frame = NSRect(x: 36, y: 90, width: 450, height: 20)
        wifiBindGatewayCheckbox.state = .on
        v1.addSubview(wifiBindGatewayCheckbox)

        wifiGatewayInfoLabel = NSTextField(labelWithString: "閘道特徵檢測中...")
        wifiGatewayInfoLabel.frame = NSRect(x: 56, y: 110, width: 620, height: 16)
        wifiGatewayInfoLabel.font = NSFont.monospacedSystemFont(ofSize: 10.5, weight: .regular)
        wifiGatewayInfoLabel.textColor = NSColor(white: 0.65, alpha: 1.0)
        v1.addSubview(wifiGatewayInfoLabel)

        // 分隔線
        let sep1 = NSBox(frame: NSRect(x: 16, y: 132, width: 660, height: 1))
        sep1.boxType = .separator
        v1.addSubview(sep1)

        geofenceCheckbox = NSButton(checkboxWithTitle: "啟用 GPS 居家大範圍地理圍欄 (以 CoreLocation 100m 粗定位，極省電)", target: self, action: #selector(handleToggleGeofence))
        geofenceCheckbox.frame = NSRect(x: 16, y: 140, width: 660, height: 20)
        v1.addSubview(geofenceCheckbox)

        let radiusLabel = NSTextField(labelWithString: "感應半徑:")
        radiusLabel.frame = NSRect(x: 36, y: 165, width: 65, height: 18)
        radiusLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        v1.addSubview(radiusLabel)

        geofenceRadiusPopUp = NSPopUpButton(frame: NSRect(x: 105, y: 163, width: 115, height: 24), pullsDown: false)
        let radii: [Double] = [100.0, 200.0, 500.0, 1000.0]
        for r in radii {
            let item = NSMenuItem(title: "\(Int(r)) 公尺", action: #selector(handleSelectRadius), keyEquivalent: "")
            item.target = self
            item.representedObject = r
            geofenceRadiusPopUp.menu?.addItem(item)
        }
        v1.addSubview(geofenceRadiusPopUp)

        let recordBtn = NSButton(frame: NSRect(x: 228, y: 163, width: 165, height: 24))
        recordBtn.title = "📌 記錄目前位置為家"
        recordBtn.bezelStyle = .rounded
        recordBtn.target = self
        recordBtn.action = #selector(handleRecordHomeLocation)
        v1.addSubview(recordBtn)

        let clearCoordBtn = NSButton(frame: NSRect(x: 398, y: 163, width: 88, height: 24))
        clearCoordBtn.title = "清除座標"
        clearCoordBtn.bezelStyle = .rounded
        clearCoordBtn.target = self
        clearCoordBtn.action = #selector(handleClearHomeLocation)
        v1.addSubview(clearCoordBtn)

        // 即時在席狀態指示卡片 (底部)
        presenceStatusBadge = NSTextField(labelWithString: "  ⚡ 狀態：持續運作模式 (未開啟在席感應)")
        presenceStatusBadge.frame = NSRect(x: 16, y: 191, width: 660, height: 24)
        presenceStatusBadge.font = NSFont.systemFont(ofSize: 11.5, weight: .semibold)
        presenceStatusBadge.wantsLayer = true
        presenceStatusBadge.layer?.cornerRadius = 6
        presenceStatusBadge.layer?.borderWidth = 1.0
        v1.addSubview(presenceStatusBadge)

        // --- Card 2: ⏱️ 採樣頻率與省電策略 ---
        let (card2, v2) = makeSettingsCard(y: 238, h: 110, title: "⏱️ 連線頻率與省電策略 (Polling & Energy Saving)")
        settingsContentView.addSubview(card2)

        let intervalLabel = NSTextField(labelWithString: "連線更新間隔:")
        intervalLabel.frame = NSRect(x: 16, y: 36, width: 95, height: 18)
        intervalLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        v2.addSubview(intervalLabel)

        intervalPopUp = NSPopUpButton(frame: NSRect(x: 114, y: 34, width: 260, height: 24), pullsDown: false)
        let intervalPresets: [(String, Double)] = [
            ("30 秒 (即時模式 - 較耗電)", 30.0),
            ("1 分鐘", 60.0),
            ("3 分鐘", 180.0),
            ("5 分鐘 (推薦平衡 - 預設)", 300.0),
            ("10 分鐘", 600.0),
            ("15 分鐘", 900.0),
            ("30 分鐘 (極致省電)", 1800.0),
            ("1 小時 (超省電休眠，續航 1 年+)", 3600.0),
            ("2 小時", 7200.0),
            ("自訂時間 (分鐘)...", -1.0)
        ]
        for (t, s) in intervalPresets {
            let item = NSMenuItem(title: t, action: #selector(handleSelectInterval), keyEquivalent: "")
            item.target = self
            item.representedObject = s
            intervalPopUp.menu?.addItem(item)
        }
        v2.addSubview(intervalPopUp)

        let customBtn = NSButton(frame: NSRect(x: 380, y: 34, width: 80, height: 24))
        customBtn.title = "自訂..."
        customBtn.bezelStyle = .rounded
        customBtn.target = self
        customBtn.action = #selector(handleCustomInterval)
        v2.addSubview(customBtn)

        let note1 = NSTextField(labelWithString: "💡 原廠秒讀架構：每次僅連線約 1 秒讀取特徵值後即刻主動中斷，99.7% 時間處於 Deep Sleep 休眠。")
        note1.frame = NSRect(x: 16, y: 64, width: 660, height: 16)
        note1.font = NSFont.systemFont(ofSize: 11, weight: .regular)
        note1.textColor = NSColor(white: 0.65, alpha: 1.0)
        v2.addSubview(note1)

        let note2 = NSTextField(labelWithString: "💡 離線指數退避：設備超出範圍時，自動依 60 秒 ➔ 300 秒 ➔ 900 秒階梯退避，徹底杜絕藍牙空轉耗電。")
        note2.frame = NSRect(x: 16, y: 83, width: 660, height: 16)
        note2.font = NSFont.systemFont(ofSize: 11, weight: .regular)
        note2.textColor = NSColor(white: 0.65, alpha: 1.0)
        v2.addSubview(note2)

        // --- Card 3: 🎨 狀態列外觀與警示通知 ---
        let (card3, v3) = makeSettingsCard(y: 358, h: 150, title: "🎨 狀態列外觀與警示通知 (Menu Bar & Alerts)")
        settingsContentView.addSubview(card3)

        let styleLabel = NSTextField(labelWithString: "狀態列圖示樣式:")
        styleLabel.frame = NSRect(x: 16, y: 36, width: 105, height: 18)
        styleLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        v3.addSubview(styleLabel)

        stylePopUp = NSPopUpButton(frame: NSRect(x: 124, y: 34, width: 280, height: 24), pullsDown: false)
        let styles = [
            "雙行微型膠囊樣式 ([TMP] / [HUM])",
            "純數字雙行堆疊 (26.1° / 63%)",
            "橫向完整排列 (🌡️ 26°C  💧 65%)",
            "僅顯示溫度 (🌡️ 26°C)",
            "緊湊單行模式 (26.1° 65%)"
        ]
        for (i, s) in styles.enumerated() {
            let item = NSMenuItem(title: s, action: #selector(handleSelectStyle), keyEquivalent: "")
            item.target = self
            item.tag = i
            stylePopUp.menu?.addItem(item)
        }
        v3.addSubview(stylePopUp)

        hideWhenDisconnectedCheckbox = NSButton(checkboxWithTitle: "僅連線時顯示 (斷線或離家停機時自動隱藏狀態列圖示)", target: self, action: #selector(handleToggleHideWhenDisconnected))
        hideWhenDisconnectedCheckbox.frame = NSRect(x: 16, y: 66, width: 650, height: 20)
        v3.addSubview(hideWhenDisconnectedCheckbox)

        let hideNote = NSTextField(labelWithString: "啟用後，離開藍牙範圍或 Wi-Fi 時圖示自動隱藏保持桌面簡潔；連回時秒級重現。")
        hideNote.frame = NSRect(x: 36, y: 86, width: 630, height: 16)
        hideNote.font = NSFont.systemFont(ofSize: 11, weight: .regular)
        hideNote.textColor = NSColor(white: 0.60, alpha: 1.0)
        v3.addSubview(hideNote)

        lowBatteryCheckbox = NSButton(checkboxWithTitle: "🔔 低電量警示推播通知 (當電量 ≤ 15% 或電壓 ≤ 2.60V 時 macOS 原生推播)", target: self, action: #selector(handleToggleLowBatteryNotification))
        lowBatteryCheckbox.frame = NSRect(x: 16, y: 108, width: 650, height: 20)
        v3.addSubview(lowBatteryCheckbox)

        let batNote = NSTextField(labelWithString: "具備 24 小時防干擾冷卻機制，每日最多提醒一次，絕不轟炸通知。")
        batNote.frame = NSRect(x: 36, y: 128, width: 630, height: 16)
        batNote.font = NSFont.systemFont(ofSize: 11, weight: .regular)
        batNote.textColor = NSColor(white: 0.60, alpha: 1.0)
        v3.addSubview(batNote)

        // --- Card 4: ℹ️ 關於設備與軟體 ---
        let (card4, v4) = makeSettingsCard(y: 518, h: 90, title: "ℹ️ 設備與系統資訊 (Hardware & Info)")
        settingsContentView.addSubview(card4)

        let info1 = NSTextField(labelWithString: "設備型號: 小米 / 米家藍牙溫濕度計 2 (LYWSD03MMC)   |   韌體相容: 原廠出廠韌體 / 開源廣播雙模")
        info1.frame = NSRect(x: 16, y: 34, width: 660, height: 16)
        info1.font = NSFont.systemFont(ofSize: 11, weight: .regular)
        info1.textColor = NSColor(white: 0.70, alpha: 1.0)
        v4.addSubview(info1)

        let info2 = NSTextField(labelWithString: "軟體版本: v1.6.0 (Native Swift & AppKit)   |   專案開源: github.com/liaw-boy/mijia-temp-bar")
        info2.frame = NSRect(x: 16, y: 52, width: 660, height: 16)
        info2.font = NSFont.systemFont(ofSize: 11, weight: .regular)
        info2.textColor = NSColor(white: 0.70, alpha: 1.0)
        v4.addSubview(info2)

        let info3 = NSTextField(labelWithString: "膠囊樣式靈感源流: github.com/sgeric910601/macbookBatteryMonitor")
        info3.frame = NSRect(x: 16, y: 70, width: 660, height: 16)
        info3.font = NSFont.systemFont(ofSize: 11, weight: .regular)
        info3.textColor = NSColor(white: 0.50, alpha: 1.0)
        v4.addSubview(info3)
    }

    private func makeSettingsCard(y: CGFloat, h: CGFloat, title: String) -> (NSView, NSView) {
        let card = FlippedView(frame: NSRect(x: 0, y: y, width: 690, height: h))
        card.wantsLayer = true
        card.layer?.cornerRadius = 10
        card.layer?.backgroundColor = NSColor(white: 0.14, alpha: 0.55).cgColor
        card.layer?.borderWidth = 1.0
        card.layer?.borderColor = NSColor(white: 1.0, alpha: 0.08).cgColor

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.frame = NSRect(x: 16, y: 10, width: 660, height: 18)
        titleLabel.font = NSFont.systemFont(ofSize: 12.5, weight: .bold)
        titleLabel.textColor = NSColor(white: 0.95, alpha: 1.0)
        card.addSubview(titleLabel)

        return (card, card)
    }

    // MARK: - 分頁切換 (Tab Navigation)
    @objc private func handleTopTabChanged() {
        let tab = WindowTab(rawValue: topSegmentedControl.selectedSegment) ?? .dashboard
        switchTab(tab)
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
            window?.title = "米家藍牙溫濕度計 2 (LYWSD03MMC) - 即時儀表板與圖表"
            reloadData()
        case .settings:
            dashboardContainerView.isHidden = true
            settingsScrollView.isHidden = false
            lastUpdateLabel.isHidden = true
            window?.title = "米家藍牙溫濕度計 2 (LYWSD03MMC) - 偏好與進階設定"
            reloadSettingsValues()
        }
    }

    // MARK: - 設定頁面數值載入
    func reloadSettingsValues() {
        // Wi-Fi 狀態
        wifiCheckbox.state = LocationGatekeeper.shared.isWiFiOnlyEnabled ? .on : .off
        wifiSSIDTextField.stringValue = LocationGatekeeper.shared.targetWiFiSSID ?? ""
        if wifiSSIDTextField.stringValue.isEmpty, let curSSID = CWWiFiClient.shared().interface()?.ssid(), !curSSID.isEmpty {
            wifiSSIDTextField.placeholderString = "目前連線: \(curSSID) (可直接點儲存)"
        } else {
            wifiSSIDTextField.placeholderString = "例如: Home_5G"
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
        let currentSec = UserDefaults.standard.double(forKey: "RefreshInterval") > 0 ? UserDefaults.standard.double(forKey: "RefreshInterval") : 300.0
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
            let mins = Int(round(currentSec / 60.0))
            lastItem?.title = "自訂時間... (目前: \(mins) 分鐘)"
        } else {
            intervalPopUp.itemArray.last?.title = "自訂時間 (分鐘)..."
        }

        // 樣式
        let currentStyle = UserDefaults.standard.integer(forKey: "DisplayStyle")
        stylePopUp.selectItem(withTag: currentStyle)

        // 隱藏與通知
        hideWhenDisconnectedCheckbox.state = UserDefaults.standard.bool(forKey: "HideWhenDisconnected") ? .on : .off
        lowBatteryCheckbox.state = NotificationManager.shared.isEnabled ? .on : .off

        updatePresenceStatus()
    }

    func updatePresenceStatus() {
        guard presenceStatusBadge != nil else { return }

        if LocationGatekeeper.shared.isWiFiOnlyEnabled {
            let target = LocationGatekeeper.shared.targetWiFiSSID ?? "未指定"
            if LocationGatekeeper.shared.isInHomeArea {
                presenceStatusBadge.stringValue = "  📶 狀態：已連上指定 Wi-Fi [\(target)] · 藍牙輪詢正常運作中"
                presenceStatusBadge.layer?.backgroundColor = NSColor(red: 0.10, green: 0.55, blue: 0.25, alpha: 0.35).cgColor
                presenceStatusBadge.layer?.borderColor = NSColor(red: 0.20, green: 0.85, blue: 0.40, alpha: 0.6).cgColor
                presenceStatusBadge.textColor = NSColor(red: 0.35, green: 0.95, blue: 0.55, alpha: 1.0)
            } else {
                presenceStatusBadge.stringValue = "  🚗 狀態：未連線至指定 Wi-Fi [\(target)] · 已徹底休眠停機 (0 耗電)"
                presenceStatusBadge.layer?.backgroundColor = NSColor(red: 0.60, green: 0.35, blue: 0.05, alpha: 0.35).cgColor
                presenceStatusBadge.layer?.borderColor = NSColor(red: 0.95, green: 0.60, blue: 0.10, alpha: 0.6).cgColor
                presenceStatusBadge.textColor = NSColor(red: 1.0, green: 0.75, blue: 0.30, alpha: 1.0)
            }
        } else if LocationGatekeeper.shared.isEnabled {
            let isHome = LocationGatekeeper.shared.isInHomeArea
            if let dist = LocationGatekeeper.shared.lastKnownDistance {
                if isHome {
                    presenceStatusBadge.stringValue = String(format: "  🏠 狀態：已在居家大範圍內 (距家約 %.0fm) · 正常運作", dist)
                    presenceStatusBadge.layer?.backgroundColor = NSColor(red: 0.10, green: 0.55, blue: 0.25, alpha: 0.35).cgColor
                    presenceStatusBadge.layer?.borderColor = NSColor(red: 0.20, green: 0.85, blue: 0.40, alpha: 0.6).cgColor
                    presenceStatusBadge.textColor = NSColor(red: 0.35, green: 0.95, blue: 0.55, alpha: 1.0)
                } else {
                    presenceStatusBadge.stringValue = String(format: "  🚗 狀態：已超出居家大範圍 (距家約 %.0fm) · 藍牙停機休眠中", dist)
                    presenceStatusBadge.layer?.backgroundColor = NSColor(red: 0.60, green: 0.35, blue: 0.05, alpha: 0.35).cgColor
                    presenceStatusBadge.layer?.borderColor = NSColor(red: 0.95, green: 0.60, blue: 0.10, alpha: 0.6).cgColor
                    presenceStatusBadge.textColor = NSColor(red: 1.0, green: 0.75, blue: 0.30, alpha: 1.0)
                }
            } else {
                presenceStatusBadge.stringValue = isHome ? "  🏠 狀態：已在居家大範圍內 · 正常運作" : "  🚗 狀態：超出居家大範圍 · 藍牙停機休眠中"
                presenceStatusBadge.layer?.backgroundColor = NSColor(red: 0.10, green: 0.55, blue: 0.25, alpha: 0.35).cgColor
                presenceStatusBadge.layer?.borderColor = NSColor(red: 0.20, green: 0.85, blue: 0.40, alpha: 0.6).cgColor
                presenceStatusBadge.textColor = NSColor(red: 0.35, green: 0.95, blue: 0.55, alpha: 1.0)
            }
        } else {
            presenceStatusBadge.stringValue = "  ⚡ 狀態：持續運作模式 (未開啟在席感應，固定週期輪詢)"
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

    @objc private func handleSaveWiFiSSID() {
        var ssid = wifiSSIDTextField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if ssid.isEmpty, let curSSID = CWWiFiClient.shared().interface()?.ssid(), !curSSID.isEmpty {
            ssid = curSSID
            wifiSSIDTextField.stringValue = ssid
        }

        guard !ssid.isEmpty else {
            let alert = NSAlert()
            alert.messageText = "請輸入 Wi-Fi 名稱"
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
            handleCustomInterval()
            return
        }
        onIntervalChanged?(sec)
        reloadSettingsValues()
        onSettingsChanged?()
    }

    @objc private func handleCustomInterval() {
        let alert = NSAlert()
        alert.messageText = "自訂更新間隔時間"
        alert.informativeText = "請輸入更新輪詢間隔（以分鐘為單位）：\n例如輸入 60 代表 1 小時，輸入 120 代表 2 小時。"
        alert.addButton(withTitle: "確定")
        alert.addButton(withTitle: "取消")

        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        let currentSec = UserDefaults.standard.double(forKey: "RefreshInterval") > 0 ? UserDefaults.standard.double(forKey: "RefreshInterval") : 300.0
        let currentMinutes = Int(currentSec / 60.0)
        input.stringValue = "\(max(1, currentMinutes))"
        alert.accessoryView = input

        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            let text = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if let mins = Double(text), mins >= 0.5 {
                let seconds = mins * 60.0
                onIntervalChanged?(seconds)
                reloadSettingsValues()
                onSettingsChanged?()
            }
        } else {
            reloadSettingsValues()
        }
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

    @objc private func handleToggleLowBatteryNotification() {
        NotificationManager.shared.isEnabled = (lowBatteryCheckbox.state == .on)
        onSettingsChanged?()
    }

    // MARK: - 數據同步與更新 (Data Update)
    func updateReading(_ r: SensorReading) {
        tempValueLabel.stringValue = String(format: "%.1f°C", r.temperature)
        let minT = HistoryManager.shared.minTemperature ?? r.temperature
        let maxT = HistoryManager.shared.maxTemperature ?? r.temperature
        tempSubLabel.stringValue = String(format: "↓ 最低 %.1f°    ↑ 最高 %.1f°", minT, maxT)

        humValueLabel.stringValue = String(format: "%.0f%%", r.humidity)
        let comfort = (r.humidity >= 40 && r.humidity <= 65) ? "舒適度：適宜 (Comfortable) 😊" : (r.humidity > 65 ? "濕度偏高 (Humid) 💧" : "空氣乾燥 (Dry) 🏜️")
        humSubLabel.stringValue = comfort

        batValueLabel.stringValue = String(format: "%d%%", r.batteryPercent)
        if r.batteryPercent <= 15 || r.voltage <= 2.60 {
            batSubLabel.stringValue = String(format: "⚠️ 電壓 %.3f V · 電量過低請換電池", r.voltage)
            batSubLabel.textColor = NSColor(red: 1.0, green: 0.38, blue: 0.38, alpha: 1.0)
        } else {
            batSubLabel.stringValue = String(format: "即時電壓 %.3f V · 狀態穩定", r.voltage)
            batSubLabel.textColor = NSColor(white: 0.70, alpha: 1.0)
        }

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
        pointsCountLabel.stringValue = "共 \(pts.count) 個採樣點"
        chartView.updatePoints(pts)
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
