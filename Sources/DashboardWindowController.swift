import AppKit

final class DashboardWindowController: NSWindowController {
    static let shared = DashboardWindowController()

    // UI 元件
    private var deviceImageView: NSImageView!
    private var titleLabel: NSTextField!
    private var modelBadgeLabel: NSTextField!
    private var statusDotLabel: NSTextField!
    private var lastUpdateLabel: NSTextField!

    // 數值卡片元件
    private var tempValueLabel: NSTextField!
    private var tempSubLabel: NSTextField!
    private var humValueLabel: NSTextField!
    private var humSubLabel: NSTextField!
    private var batValueLabel: NSTextField!
    private var batSubLabel: NSTextField!

    // 圖表區
    private var segmentedControl: NSSegmentedControl!
    private var chartView: ChartView!
    private var pointsCountLabel: NSTextField!

    var onRefreshRequested: (() -> Void)?

    convenience init() {
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 750, height: 650),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        win.title = "米家溫濕度計 2 (LYWSD03MMC) - 即時儀表板"
        win.titlebarAppearsTransparent = true
        win.titleVisibility = .hidden
        win.isReleasedWhenClosed = false
        win.center()

        self.init(window: win)
        setupUI()
    }

    private func setupUI() {
        guard let win = window else { return }

        // 底層深色霧面毛玻璃
        let visualEffect = NSVisualEffectView(frame: win.contentView!.bounds)
        visualEffect.autoresizingMask = [.width, .height]
        visualEffect.material = .hudWindow
        visualEffect.blendingMode = .behindWindow
        visualEffect.state = .active
        win.contentView = visualEffect

        let container = NSView(frame: NSRect(x: 24, y: 20, width: 702, height: 605))
        visualEffect.addSubview(container)

        // 1. 頂部設備卡片 (Hero Card: 702 x 100)
        let headerCard = NSView(frame: NSRect(x: 0, y: 505, width: 702, height: 100))
        headerCard.wantsLayer = true
        headerCard.layer?.cornerRadius = 16
        headerCard.layer?.backgroundColor = NSColor(red: 0.11, green: 0.12, blue: 0.16, alpha: 0.85).cgColor
        headerCard.layer?.borderWidth = 1.0
        headerCard.layer?.borderColor = NSColor(white: 1.0, alpha: 0.10).cgColor
        container.addSubview(headerCard)

        // 設備圖片 (透明懸浮投影卡片: 78x78)
        let imgPedestal = NSView(frame: NSRect(x: 12, y: 11, width: 78, height: 78))
        imgPedestal.wantsLayer = true
        imgPedestal.layer?.cornerRadius = 14
        imgPedestal.layer?.backgroundColor = NSColor(white: 0.05, alpha: 0.6).cgColor
        imgPedestal.layer?.borderWidth = 1.0
        imgPedestal.layer?.borderColor = NSColor(white: 1.0, alpha: 0.12).cgColor
        headerCard.addSubview(imgPedestal)

        deviceImageView = NSImageView(frame: NSRect(x: 4, y: 4, width: 70, height: 70))
        deviceImageView.imageScaling = .scaleProportionallyUpOrDown
        if let bundledImgPath = Bundle.main.path(forResource: "device", ofType: "png"),
           let img = NSImage(contentsOfFile: bundledImgPath) {
            deviceImageView.image = img
        } else if let localImg = NSImage(contentsOfFile: "/Users/boywei/project_code/mijia-temp-bar/Resources/device.png") {
            deviceImageView.image = localImg
        }
        imgPedestal.addSubview(deviceImageView)

        // 設備標題與型號
        titleLabel = NSTextField(labelWithString: "米家藍牙溫濕度計 2")
        titleLabel.frame = NSRect(x: 104, y: 62, width: 280, height: 24)
        titleLabel.font = NSFont.systemFont(ofSize: 18, weight: .bold)
        headerCard.addSubview(titleLabel)

        // 膠囊標籤 (Model & Mode)
        modelBadgeLabel = NSTextField(labelWithString: "LYWSD03MMC  ·  原廠直連 (秒讀休眠)")
        modelBadgeLabel.frame = NSRect(x: 104, y: 38, width: 340, height: 18)
        modelBadgeLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold)
        modelBadgeLabel.textColor = NSColor(red: 0.35, green: 0.75, blue: 1.0, alpha: 1.0)
        headerCard.addSubview(modelBadgeLabel)

        statusDotLabel = NSTextField(labelWithString: "● 正常運作中 (休眠省電模式)")
        statusDotLabel.frame = NSRect(x: 104, y: 16, width: 260, height: 16)
        statusDotLabel.font = NSFont.systemFont(ofSize: 11.5, weight: .medium)
        statusDotLabel.textColor = NSColor(red: 0.25, green: 0.88, blue: 0.50, alpha: 1.0)
        headerCard.addSubview(statusDotLabel)

        // 右側功能按鈕
        let refreshButton = NSButton(frame: NSRect(x: 574, y: 54, width: 116, height: 32))
        refreshButton.title = "⟳ 立即刷新 (⌘R)"
        refreshButton.bezelStyle = .rounded
        refreshButton.target = self
        refreshButton.action = #selector(handleRefreshClicked)
        headerCard.addSubview(refreshButton)

        let exportButton = NSButton(frame: NSRect(x: 574, y: 16, width: 116, height: 32))
        exportButton.title = "⤓ 匯出 CSV..."
        exportButton.bezelStyle = .rounded
        exportButton.target = self
        exportButton.action = #selector(handleExportCSV)
        headerCard.addSubview(exportButton)

        lastUpdateLabel = NSTextField(labelWithString: "最後讀取: --:--:--")
        lastUpdateLabel.frame = NSRect(x: 370, y: 16, width: 190, height: 16)
        lastUpdateLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .regular)
        lastUpdateLabel.alignment = .right
        lastUpdateLabel.textColor = NSColor(white: 0.6, alpha: 1.0)
        headerCard.addSubview(lastUpdateLabel)

        // 2. 中間三大指標卡片 (3 Cards: Temp, Hum, Bat: 226 x 112)
        let cardW: CGFloat = 226
        let cardH: CGFloat = 112
        let cardY: CGFloat = 378

        // 卡片 1：溫度
        let (card1, tVal, tSub) = makeMetricCard(
            x: 0, y: cardY, w: cardW, h: cardH,
            icon: "🌡️", category: "TEMPERATURE · 溫度",
            accentColor: NSColor(red: 1.0, green: 0.48, blue: 0.12, alpha: 1.0),
            bgTint: NSColor(red: 1.0, green: 0.45, blue: 0.10, alpha: 0.08),
            borderTint: NSColor(red: 1.0, green: 0.48, blue: 0.12, alpha: 0.28)
        )
        container.addSubview(card1)
        tempValueLabel = tVal
        tempSubLabel = tSub

        // 卡片 2：濕度
        let (card2, hVal, hSub) = makeMetricCard(
            x: 238, y: cardY, w: cardW, h: cardH,
            icon: "💧", category: "HUMIDITY · 相對濕度",
            accentColor: NSColor(red: 0.05, green: 0.68, blue: 1.0, alpha: 1.0),
            bgTint: NSColor(red: 0.05, green: 0.60, blue: 0.95, alpha: 0.08),
            borderTint: NSColor(red: 0.05, green: 0.68, blue: 1.0, alpha: 0.28)
        )
        container.addSubview(card2)
        humValueLabel = hVal
        humSubLabel = hSub

        // 卡片 3：電池電量
        let (card3, bVal, bSub) = makeMetricCard(
            x: 476, y: cardY, w: cardW, h: cardH,
            icon: "🔋", category: "BATTERY · 電池狀態",
            accentColor: NSColor(red: 0.10, green: 0.88, blue: 0.52, alpha: 1.0),
            bgTint: NSColor(red: 0.10, green: 0.80, blue: 0.45, alpha: 0.08),
            borderTint: NSColor(red: 0.10, green: 0.88, blue: 0.52, alpha: 0.28)
        )
        container.addSubview(card3)
        batValueLabel = bVal
        batSubLabel = bSub

        // 3. 底部圖表區塊 (702 x 365)
        let chartHeaderY: CGFloat = 338
        let chartLabel = NSTextField(labelWithString: "歷史趨勢折線圖")
        chartLabel.frame = NSRect(x: 2, y: chartHeaderY, width: 140, height: 22)
        chartLabel.font = NSFont.systemFont(ofSize: 14.5, weight: .bold)
        container.addSubview(chartLabel)

        segmentedControl = NSSegmentedControl(
            labels: ["📊 綜合總覽", "🌡️ 溫度走勢", "💧 濕度走勢", "🔋 電壓回彈"],
            trackingMode: .selectOne,
            target: self,
            action: #selector(handleSegmentChanged)
        )
        segmentedControl.frame = NSRect(x: 146, y: chartHeaderY - 2, width: 390, height: 26)
        segmentedControl.selectedSegment = 0
        container.addSubview(segmentedControl)

        pointsCountLabel = NSTextField(labelWithString: "共 0 個採樣點")
        pointsCountLabel.frame = NSRect(x: 546, y: chartHeaderY, width: 154, height: 20)
        pointsCountLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .medium)
        pointsCountLabel.alignment = .right
        pointsCountLabel.textColor = NSColor(white: 0.65, alpha: 1.0)
        container.addSubview(pointsCountLabel)

        chartView = ChartView(frame: NSRect(x: 0, y: 0, width: 702, height: 326))
        container.addSubview(chartView)

        reloadData()
    }

    private func makeMetricCard(
        x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat,
        icon: String, category: String,
        accentColor: NSColor, bgTint: NSColor, borderTint: NSColor
    ) -> (NSView, NSTextField, NSTextField) {
        let card = NSView(frame: NSRect(x: x, y: y, width: w, height: h))
        card.wantsLayer = true
        card.layer?.cornerRadius = 16
        card.layer?.backgroundColor = bgTint.cgColor
        card.layer?.borderWidth = 1.0
        card.layer?.borderColor = borderTint.cgColor

        // 頂部分類微標籤
        let headerLabel = NSTextField(labelWithString: "\(icon) \(category)")
        headerLabel.frame = NSRect(x: 16, y: h - 28, width: w - 32, height: 18)
        headerLabel.font = NSFont.systemFont(ofSize: 11, weight: .bold)
        headerLabel.textColor = accentColor.withAlphaComponent(0.9)
        card.addSubview(headerLabel)

        // 核心巨型數值 (34pt)
        let valLabel = NSTextField(labelWithString: "--")
        valLabel.frame = NSRect(x: 14, y: 38, width: w - 28, height: 42)
        valLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 34, weight: .bold)
        valLabel.textColor = accentColor
        card.addSubview(valLabel)

        // 底部輔助指標
        let subLabel = NSTextField(labelWithString: "載入中...")
        subLabel.frame = NSRect(x: 16, y: 12, width: w - 32, height: 18)
        subLabel.font = NSFont.systemFont(ofSize: 11.5, weight: .medium)
        subLabel.textColor = NSColor(white: 0.75, alpha: 1.0)
        card.addSubview(subLabel)

        return (card, valLabel, subLabel)
    }

    func updateReading(_ r: SensorReading) {
        // 溫度數值 (無多餘空格)
        tempValueLabel.stringValue = String(format: "%.1f°C", r.temperature)
        let minT = HistoryManager.shared.minTemperature ?? r.temperature
        let maxT = HistoryManager.shared.maxTemperature ?? r.temperature
        tempSubLabel.stringValue = String(format: "↓ 最低 %.1f°    ↑ 最高 %.1f°", minT, maxT)

        // 濕度數值
        humValueLabel.stringValue = String(format: "%.0f%%", r.humidity)
        let comfort = (r.humidity >= 40 && r.humidity <= 65) ? "舒適度：適宜 (Comfortable) 😊" : (r.humidity > 65 ? "濕度偏高 (Humid) 💧" : "空氣乾燥 (Dry) 🏜️")
        humSubLabel.stringValue = comfort

        // 電池電量
        batValueLabel.stringValue = String(format: "%d%%", r.batteryPercent)
        batSubLabel.stringValue = String(format: "即時電壓 %.3f V · 狀態穩定", r.voltage)

        let df = DateFormatter()
        df.dateFormat = "HH:mm:ss"
        lastUpdateLabel.stringValue = "最後讀取: \(df.string(from: r.lastUpdated))"

        reloadData()
    }

    func reloadData() {
        let pts = HistoryManager.shared.points
        pointsCountLabel.stringValue = "共 \(pts.count) 個採樣點"
        chartView.updatePoints(pts)
    }

    @objc private func handleSegmentChanged() {
        switch segmentedControl.selectedSegment {
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
        savePanel.nameFieldStringValue = "mijia_temp_history_\(Date().timeIntervalSince1970).csv"

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
