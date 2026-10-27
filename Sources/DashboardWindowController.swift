import AppKit

final class DashboardWindowController: NSWindowController {
    static let shared = DashboardWindowController()

    // 頂部列元件
    private var deviceImageView: NSImageView!
    private var titleLabel: NSTextField!
    private var modelBadgeLabel: NSTextField!
    private var statusDotLabel: NSTextField!
    private var lastUpdateLabel: NSTextField!

    // 三大指標卡片元件
    private var tempValueLabel: NSTextField!
    private var tempSubLabel: NSTextField!
    private var humValueLabel: NSTextField!
    private var humSubLabel: NSTextField!
    private var batValueLabel: NSTextField!
    private var batSubLabel: NSTextField!

    // 圖表與分頁
    private var segmentedControl: NSSegmentedControl!
    private var chartView: ChartView!
    private var pointsCountLabel: NSTextField!

    var onRefreshRequested: (() -> Void)?

    convenience init() {
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 730, height: 580),
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

        let container = NSView(frame: NSRect(x: 24, y: 20, width: 682, height: 535))
        visualEffect.addSubview(container)

        // 1. 簡潔頂部工具列 (Header Bar: 682 x 46, Y: 485)
        let headerBar = NSView(frame: NSRect(x: 0, y: 485, width: 682, height: 46))
        container.addSubview(headerBar)

        // 硬體縮圖 (34x34)
        let imgBox = NSView(frame: NSRect(x: 0, y: 6, width: 34, height: 34))
        imgBox.wantsLayer = true
        imgBox.layer?.cornerRadius = 8
        imgBox.layer?.backgroundColor = NSColor(white: 0.12, alpha: 0.8).cgColor
        imgBox.layer?.borderWidth = 1.0
        imgBox.layer?.borderColor = NSColor(white: 1.0, alpha: 0.12).cgColor
        headerBar.addSubview(imgBox)

        deviceImageView = NSImageView(frame: NSRect(x: 2, y: 2, width: 30, height: 30))
        deviceImageView.imageScaling = .scaleProportionallyUpOrDown
        if let bundledImgPath = Bundle.main.path(forResource: "device", ofType: "png"),
           let img = NSImage(contentsOfFile: bundledImgPath) {
            deviceImageView.image = img
        } else if let localImg = NSImage(contentsOfFile: "/Users/boywei/project_code/mijia-temp-bar/Resources/device.png") {
            deviceImageView.image = localImg
        }
        imgBox.addSubview(deviceImageView)

        // 標題與標籤
        titleLabel = NSTextField(labelWithString: "米家藍牙溫濕度計 2")
        titleLabel.frame = NSRect(x: 44, y: 22, width: 170, height: 20)
        titleLabel.font = NSFont.systemFont(ofSize: 15, weight: .bold)
        headerBar.addSubview(titleLabel)

        modelBadgeLabel = NSTextField(labelWithString: "LYWSD03MMC")
        modelBadgeLabel.frame = NSRect(x: 218, y: 23, width: 85, height: 16)
        modelBadgeLabel.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .semibold)
        modelBadgeLabel.textColor = NSColor(red: 0.35, green: 0.75, blue: 1.0, alpha: 1.0)
        headerBar.addSubview(modelBadgeLabel)

        statusDotLabel = NSTextField(labelWithString: "● 連線正常 (省電輪詢模式)")
        statusDotLabel.frame = NSRect(x: 44, y: 4, width: 200, height: 16)
        statusDotLabel.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        statusDotLabel.textColor = NSColor(red: 0.25, green: 0.88, blue: 0.50, alpha: 1.0)
        headerBar.addSubview(statusDotLabel)

        // 右側按鈕與最後讀取時間
        let refreshButton = NSButton(frame: NSRect(x: 582, y: 12, width: 100, height: 26))
        refreshButton.title = "⟳ 立即刷新"
        refreshButton.bezelStyle = .rounded
        refreshButton.target = self
        refreshButton.action = #selector(handleRefreshClicked)
        headerBar.addSubview(refreshButton)

        let exportButton = NSButton(frame: NSRect(x: 480, y: 12, width: 96, height: 26))
        exportButton.title = "⤓ 匯出 CSV"
        exportButton.bezelStyle = .rounded
        exportButton.target = self
        exportButton.action = #selector(handleExportCSV)
        headerBar.addSubview(exportButton)

        lastUpdateLabel = NSTextField(labelWithString: "最後讀取: --:--")
        lastUpdateLabel.frame = NSRect(x: 320, y: 17, width: 150, height: 16)
        lastUpdateLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        lastUpdateLabel.alignment = .right
        lastUpdateLabel.textColor = NSColor(white: 0.55, alpha: 1.0)
        headerBar.addSubview(lastUpdateLabel)

        // 2. 中間三大指標卡片 (3 Cards: Temp, Hum, Bat: 220 x 100, Y: 365)
        let cardW: CGFloat = 220
        let cardH: CGFloat = 100
        let cardY: CGFloat = 365

        // 卡片 1：溫度
        let (card1, tVal, tSub) = makeMetricCard(
            x: 0, y: cardY, w: cardW, h: cardH,
            icon: "🌡️", category: "TEMPERATURE · 溫度",
            accentColor: NSColor(red: 1.0, green: 0.48, blue: 0.12, alpha: 1.0),
            bgTint: NSColor(red: 1.0, green: 0.45, blue: 0.10, alpha: 0.08),
            borderTint: NSColor(red: 1.0, green: 0.48, blue: 0.12, alpha: 0.25)
        )
        container.addSubview(card1)
        tempValueLabel = tVal
        tempSubLabel = tSub

        // 卡片 2：濕度
        let (card2, hVal, hSub) = makeMetricCard(
            x: 231, y: cardY, w: cardW, h: cardH,
            icon: "💧", category: "HUMIDITY · 相對濕度",
            accentColor: NSColor(red: 0.05, green: 0.68, blue: 1.0, alpha: 1.0),
            bgTint: NSColor(red: 0.05, green: 0.60, blue: 0.95, alpha: 0.08),
            borderTint: NSColor(red: 0.05, green: 0.68, blue: 1.0, alpha: 0.25)
        )
        container.addSubview(card2)
        humValueLabel = hVal
        humSubLabel = hSub

        // 卡片 3：電池電量
        let (card3, bVal, bSub) = makeMetricCard(
            x: 462, y: cardY, w: cardW, h: cardH,
            icon: "🔋", category: "BATTERY · 電池狀態",
            accentColor: NSColor(red: 0.10, green: 0.88, blue: 0.52, alpha: 1.0),
            bgTint: NSColor(red: 0.10, green: 0.80, blue: 0.45, alpha: 0.08),
            borderTint: NSColor(red: 0.10, green: 0.88, blue: 0.52, alpha: 0.25)
        )
        container.addSubview(card3)
        batValueLabel = bVal
        batSubLabel = bSub

        // 3. 底部圖表區塊 (682 x 340)
        let chartHeaderY: CGFloat = 328
        let chartLabel = NSTextField(labelWithString: "歷史趨勢折線圖")
        chartLabel.frame = NSRect(x: 2, y: chartHeaderY, width: 130, height: 22)
        chartLabel.font = NSFont.systemFont(ofSize: 14, weight: .bold)
        container.addSubview(chartLabel)

        segmentedControl = NSSegmentedControl(
            labels: ["📊 綜合總覽", "🌡️ 溫度走勢", "💧 濕度走勢", "🔋 電壓回彈"],
            trackingMode: .selectOne,
            target: self,
            action: #selector(handleSegmentChanged)
        )
        segmentedControl.frame = NSRect(x: 135, y: chartHeaderY - 2, width: 380, height: 26)
        segmentedControl.selectedSegment = 0
        container.addSubview(segmentedControl)

        pointsCountLabel = NSTextField(labelWithString: "共 0 個採樣點")
        pointsCountLabel.frame = NSRect(x: 520, y: chartHeaderY, width: 162, height: 20)
        pointsCountLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        pointsCountLabel.alignment = .right
        pointsCountLabel.textColor = NSColor(white: 0.60, alpha: 1.0)
        container.addSubview(pointsCountLabel)

        chartView = ChartView(frame: NSRect(x: 0, y: 0, width: 682, height: 316))
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
        card.layer?.cornerRadius = 14
        card.layer?.backgroundColor = bgTint.cgColor
        card.layer?.borderWidth = 1.0
        card.layer?.borderColor = borderTint.cgColor

        let headerLabel = NSTextField(labelWithString: "\(icon) \(category)")
        headerLabel.frame = NSRect(x: 14, y: h - 26, width: w - 28, height: 16)
        headerLabel.font = NSFont.systemFont(ofSize: 10.5, weight: .bold)
        headerLabel.textColor = accentColor.withAlphaComponent(0.9)
        card.addSubview(headerLabel)

        let valLabel = NSTextField(labelWithString: "--")
        valLabel.frame = NSRect(x: 12, y: 32, width: w - 24, height: 38)
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

    func updateReading(_ r: SensorReading) {
        tempValueLabel.stringValue = String(format: "%.1f°C", r.temperature)
        let minT = HistoryManager.shared.minTemperature ?? r.temperature
        let maxT = HistoryManager.shared.maxTemperature ?? r.temperature
        tempSubLabel.stringValue = String(format: "↓ 最低 %.1f°    ↑ 最高 %.1f°", minT, maxT)

        humValueLabel.stringValue = String(format: "%.0f%%", r.humidity)
        let comfort = (r.humidity >= 40 && r.humidity <= 65) ? "舒適度：適宜 (Comfortable) 😊" : (r.humidity > 65 ? "濕度偏高 (Humid) 💧" : "空氣乾燥 (Dry) 🏜️")
        humSubLabel.stringValue = comfort

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
