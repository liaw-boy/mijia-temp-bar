import AppKit

final class DashboardWindowController: NSWindowController {
    static let shared = DashboardWindowController()

    // UI 元件
    private var deviceImageView: NSImageView!
    private var titleLabel: NSTextField!
    private var modelBadgeLabel: NSTextField!
    private var statusDotLabel: NSTextField!
    private var lastUpdateLabel: NSTextField!

    // 數值卡片
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
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 620),
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

        let visualEffect = NSVisualEffectView(frame: win.contentView!.bounds)
        visualEffect.autoresizingMask = [.width, .height]
        visualEffect.material = .hudWindow
        visualEffect.blendingMode = .behindWindow
        visualEffect.state = .active
        win.contentView = visualEffect

        let container = NSView(frame: NSRect(x: 20, y: 20, width: 660, height: 575))
        visualEffect.addSubview(container)

        // 1. 頂部設備資訊卡片 (Hero Card)
        let headerCard = NSView(frame: NSRect(x: 0, y: 485, width: 660, height: 90))
        headerCard.wantsLayer = true
        headerCard.layer?.cornerRadius = 12
        headerCard.layer?.backgroundColor = NSColor(white: 0.15, alpha: 0.8).cgColor
        headerCard.layer?.borderWidth = 1.0
        headerCard.layer?.borderColor = NSColor(white: 0.28, alpha: 0.6).cgColor
        container.addSubview(headerCard)

        // 設備圖片 (70x70)
        deviceImageView = NSImageView(frame: NSRect(x: 10, y: 10, width: 70, height: 70))
        deviceImageView.wantsLayer = true
        deviceImageView.layer?.cornerRadius = 10
        deviceImageView.layer?.masksToBounds = true
        deviceImageView.layer?.borderWidth = 1.0
        deviceImageView.layer?.borderColor = NSColor(white: 0.3, alpha: 0.6).cgColor
        deviceImageView.imageScaling = .scaleProportionallyUpOrDown

        if let bundledImgPath = Bundle.main.path(forResource: "device", ofType: "png"),
           let img = NSImage(contentsOfFile: bundledImgPath) {
            deviceImageView.image = img
        } else if let localImg = NSImage(contentsOfFile: "/Users/boywei/project_code/mijia-temp-bar/Resources/device.png") {
            deviceImageView.image = localImg
        }
        headerCard.addSubview(deviceImageView)

        // 標題與標籤
        titleLabel = NSTextField(labelWithString: "米家藍牙溫濕度計 2")
        titleLabel.frame = NSRect(x: 92, y: 55, width: 220, height: 22)
        titleLabel.font = NSFont.systemFont(ofSize: 17, weight: .bold)
        headerCard.addSubview(titleLabel)

        modelBadgeLabel = NSTextField(labelWithString: "LYWSD03MMC · 原廠直連 (秒讀休眠)")
        modelBadgeLabel.frame = NSRect(x: 92, y: 34, width: 320, height: 18)
        modelBadgeLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)
        modelBadgeLabel.textColor = NSColor(red: 0.2, green: 0.75, blue: 1.0, alpha: 1.0)
        headerCard.addSubview(modelBadgeLabel)

        statusDotLabel = NSTextField(labelWithString: "● 正常運作中 (休眠省電)")
        statusDotLabel.frame = NSRect(x: 92, y: 14, width: 200, height: 16)
        statusDotLabel.font = NSFont.systemFont(ofSize: 11)
        statusDotLabel.textColor = NSColor(red: 0.3, green: 0.85, blue: 0.45, alpha: 1.0)
        headerCard.addSubview(statusDotLabel)

        // 右側按鈕與時間
        let refreshButton = NSButton(frame: NSRect(x: 540, y: 48, width: 108, height: 28))
        refreshButton.title = "即時刷新 (⌘R)"
        refreshButton.bezelStyle = .rounded
        refreshButton.target = self
        refreshButton.action = #selector(handleRefreshClicked)
        headerCard.addSubview(refreshButton)

        let exportButton = NSButton(frame: NSRect(x: 540, y: 16, width: 108, height: 28))
        exportButton.title = "匯出 CSV..."
        exportButton.bezelStyle = .rounded
        exportButton.target = self
        exportButton.action = #selector(handleExportCSV)
        headerCard.addSubview(exportButton)

        lastUpdateLabel = NSTextField(labelWithString: "最後更新: --:--:--")
        lastUpdateLabel.frame = NSRect(x: 350, y: 14, width: 180, height: 16)
        lastUpdateLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        lastUpdateLabel.alignment = .right
        lastUpdateLabel.textColor = NSColor.secondaryLabelColor
        headerCard.addSubview(lastUpdateLabel)

        // 2. 中間三大指標卡片 (3 Cards: Temp, Hum, Bat)
        let cardW: CGFloat = 212
        let cardH: CGFloat = 95
        let cardY: CGFloat = 378

        // 卡片 1：溫度
        let (card1, tVal, tSub) = makeMetricCard(
            x: 0, y: cardY, w: cardW, h: cardH,
            icon: "🌡️", title: "即時溫度",
            accentColor: NSColor(red: 1.0, green: 0.52, blue: 0.15, alpha: 1.0)
        )
        container.addSubview(card1)
        tempValueLabel = tVal
        tempSubLabel = tSub

        // 卡片 2：濕度
        let (card2, hVal, hSub) = makeMetricCard(
            x: 224, y: cardY, w: cardW, h: cardH,
            icon: "💧", title: "相對濕度",
            accentColor: NSColor(red: 0.15, green: 0.65, blue: 1.0, alpha: 1.0)
        )
        container.addSubview(card2)
        humValueLabel = hVal
        humSubLabel = hSub

        // 卡片 3：電池電量
        let (card3, bVal, bSub) = makeMetricCard(
            x: 448, y: cardY, w: cardW, h: cardH,
            icon: "🔋", title: "電池狀態",
            accentColor: NSColor(red: 0.2, green: 0.85, blue: 0.5, alpha: 1.0)
        )
        container.addSubview(card3)
        batValueLabel = bVal
        batSubLabel = bSub

        // 3. 底部圖表區塊
        let chartHeaderY: CGFloat = 338
        let chartLabel = NSTextField(labelWithString: "歷史趨勢折線圖")
        chartLabel.frame = NSRect(x: 2, y: chartHeaderY, width: 140, height: 22)
        chartLabel.font = NSFont.systemFont(ofSize: 14, weight: .bold)
        container.addSubview(chartLabel)

        segmentedControl = NSSegmentedControl(labels: ["🌡️ 溫度走勢", "💧 濕度走勢", "🔋 電壓回彈"], trackingMode: .selectOne, target: self, action: #selector(handleSegmentChanged))
        segmentedControl.frame = NSRect(x: 140, y: chartHeaderY - 2, width: 320, height: 24)
        segmentedControl.selectedSegment = 0
        container.addSubview(segmentedControl)

        pointsCountLabel = NSTextField(labelWithString: "共 0 個採樣點")
        pointsCountLabel.frame = NSRect(x: 480, y: chartHeaderY, width: 180, height: 18)
        pointsCountLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        pointsCountLabel.alignment = .right
        pointsCountLabel.textColor = NSColor.secondaryLabelColor
        container.addSubview(pointsCountLabel)

        chartView = ChartView(frame: NSRect(x: 0, y: 0, width: 660, height: 328))
        container.addSubview(chartView)

        reloadData()
    }

    private func makeMetricCard(x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat, icon: String, title: String, accentColor: NSColor) -> (NSView, NSTextField, NSTextField) {
        let card = NSView(frame: NSRect(x: x, y: y, width: w, height: h))
        card.wantsLayer = true
        card.layer?.cornerRadius = 12
        card.layer?.backgroundColor = NSColor(white: 0.15, alpha: 0.8).cgColor
        card.layer?.borderWidth = 1.0
        card.layer?.borderColor = NSColor(white: 0.26, alpha: 0.6).cgColor

        let headerLabel = NSTextField(labelWithString: "\(icon) \(title)")
        headerLabel.frame = NSRect(x: 14, y: h - 26, width: w - 28, height: 18)
        headerLabel.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        headerLabel.textColor = NSColor.secondaryLabelColor
        card.addSubview(headerLabel)

        let valLabel = NSTextField(labelWithString: "--")
        valLabel.frame = NSRect(x: 14, y: 32, width: w - 28, height: 36)
        valLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 28, weight: .bold)
        valLabel.textColor = accentColor
        card.addSubview(valLabel)

        let subLabel = NSTextField(labelWithString: "載入中...")
        subLabel.frame = NSRect(x: 14, y: 10, width: w - 28, height: 16)
        subLabel.font = NSFont.systemFont(ofSize: 11)
        subLabel.textColor = NSColor.tertiaryLabelColor
        card.addSubview(subLabel)

        return (card, valLabel, subLabel)
    }

    func updateReading(_ r: SensorReading) {
        tempValueLabel.stringValue = String(format: "%.1f °C", r.temperature)
        let minT = HistoryManager.shared.minTemperature ?? r.temperature
        let maxT = HistoryManager.shared.maxTemperature ?? r.temperature
        tempSubLabel.stringValue = String(format: "最低 %.1f° · 最高 %.1f°", minT, maxT)

        humValueLabel.stringValue = String(format: "%.0f %%", r.humidity)
        let comfort = (r.humidity >= 40 && r.humidity <= 65) ? "適宜舒適 😊" : (r.humidity > 65 ? "偏潮濕 💧" : "乾燥 🏜️")
        humSubLabel.stringValue = comfort

        batValueLabel.stringValue = String(format: "%d %%", r.batteryPercent)
        batSubLabel.stringValue = String(format: "電壓 %.3f V · 健康穩定", r.voltage)

        let df = DateFormatter()
        df.dateFormat = "HH:mm:ss"
        lastUpdateLabel.stringValue = "最後更新: \(df.string(from: r.lastUpdated))"

        reloadData()
    }

    func reloadData() {
        let pts = HistoryManager.shared.points
        pointsCountLabel.stringValue = "共 \(pts.count) 個採樣點"
        chartView.updatePoints(pts)
    }

    @objc private func handleSegmentChanged() {
        switch segmentedControl.selectedSegment {
        case 0: chartView.dataType = .temperature
        case 1: chartView.dataType = .humidity
        case 2: chartView.dataType = .voltage
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
