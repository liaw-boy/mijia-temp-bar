import AppKit
import CoreWLAN


class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

final class DashboardWindowController: NSWindowController {
    static let shared = DashboardWindowController()

    enum WindowTab: Int {
        case dashboard = 0
        case settings = 1
    }

    // 頂部列元件
    var topSegmentedControl: NSSegmentedControl!
    var deviceView: DeviceView!
    var modelBadgeLabel: NSTextField!
    var statusDotLabel: NSTextField!
    var lastUpdateLabel: NSTextField!

    // 容器分頁檢視
    var mainContainer: NSView!
    var dashboardContainerView: NSView!
    var settingsScrollView: NSScrollView!
    var settingsContentView: FlippedView!

    // === 儀表板頁面元件 ===
    var tempValueLabel: NSTextField!
    var tempSubLabel: NSTextField!
    var humValueLabel: NSTextField!
    var humSubLabel: NSTextField!
    var batValueLabel: NSTextField!
    var batSubLabel: NSTextField!

    var chartSegmentedControl: NSSegmentedControl!
    var chartView: ChartView!
    var rangePopUp: NSPopUpButton!
    var refreshButton: NSButton!
    var exportButton: NSButton!

    // === 設定頁面元件 ===
    // 1. 網路與在席感應
    var wifiCheckbox: NSButton!
    var wifiSSIDTextField: NSTextField!
    var wifiBindGatewayCheckbox: NSButton!
    var wifiGatewayInfoLabel: NSTextField!
    var wifiHintLabel: NSTextField!
    var updateStatusLabel: NSTextField!
    var updateButton: NSButton!
    var autoUpdateCheckbox: NSButton!
    var availableUpdateURL: URL?
    var geofenceCheckbox: NSButton!
    var geofenceRadiusPopUp: NSPopUpButton!
    var presenceStatusBadge: NSTextField!

    // 2. 頻率與省電
    var intervalPopUp: NSPopUpButton!
    var customIntervalField: NSTextField!

    // 3. 外觀與通知
    var stylePopUp: NSPopUpButton!
    var hideWhenDisconnectedCheckbox: NSButton!
    var lowBatteryCheckbox: NSButton!
    var humidityAlertCheckbox: NSButton!
    var humidityHighField: NSTextField!
    var humidityLowField: NSTextField!

    // 4. 裝置與登入時自動啟動 (設定分頁)
    var deviceSummaryTitle: NSTextField?
    var launchAtLoginCheckbox: NSButton!
    var launchAtLoginCaption: NSTextField?

    let settingsWidth: CGFloat = 692

    // 多裝置：資料來源 (StatusBarController) 與目前選的裝置
    weak var coordinator: DeviceCoordinator?
    private(set) var selectedDeviceID: String?
    var devicePopUp: NSPopUpButton!
    private var popUpDeviceIDs: [String] = []

    // 回呼閉包 (與 StatusBarController 連動)；立即更新帶目前選的裝置
    var onRefreshRequested: ((String?) -> Void)?
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
        win.title = "米家藍牙溫濕度計 - 數據圖表"
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

        // 裝置切換 (取代原本固定的標題) 與型號標章
        devicePopUp = NSPopUpButton(frame: NSRect(x: 54, y: 21, width: 154, height: 24), pullsDown: false)
        devicePopUp.font = NSFont.systemFont(ofSize: 13, weight: .bold)
        devicePopUp.target = self
        devicePopUp.action = #selector(handleDeviceSelected)
        devicePopUp.toolTip = "選擇要查看的裝置"
        headerBar.addSubview(devicePopUp)

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
            window?.title = "米家藍牙溫濕度計 - 數據圖表"
            reloadData()
        case .settings:
            dashboardContainerView.isHidden = true
            settingsScrollView.isHidden = false
            lastUpdateLabel.isHidden = true
            window?.title = "米家藍牙溫濕度計 - 設定"
            reloadSettingsValues()
        }
    }


    // MARK: - 裝置切換
    /// 裝置清單變動：重建下拉選單 (保留目前選擇，被移除時改選主裝置)
    func reloadDevices() {
        let devices = coordinator?.devices ?? []
        popUpDeviceIDs = devices.map(\.id)
        devicePopUp.removeAllItems()
        // 直接加 NSMenuItem：addItem(withTitle:) 會把同名的項目合併，改名成相同名稱時會少一台
        let titles = devices.map { $0.id == coordinator?.primaryID ? "\($0.name)  (狀態列)" : $0.name }
        for title in titles.isEmpty ? ["尚未加入裝置"] : titles {
            devicePopUp.menu?.addItem(NSMenuItem(title: title, action: nil, keyEquivalent: ""))
        }
        devicePopUp.isEnabled = !devices.isEmpty
        let keep = popUpDeviceIDs.contains(selectedDeviceID ?? "") ? selectedDeviceID : coordinator?.primaryID
        selectDevice(keep)
        reloadDeviceSection()
    }

    func selectDevice(_ id: String?) {
        selectedDeviceID = popUpDeviceIDs.contains(id ?? "") ? id : nil
        if let id = selectedDeviceID, let i = popUpDeviceIDs.firstIndex(of: id) {
            devicePopUp.selectItem(at: i)
        }
        applySelectedState()
    }

    @objc private func handleDeviceSelected() {
        let i = devicePopUp.indexOfSelectedItem
        guard popUpDeviceIDs.indices.contains(i) else { return }
        selectedDeviceID = popUpDeviceIDs[i]
        applySelectedState()
    }

    /// 某台裝置有新讀數或狀態 (由 StatusBarController 呼叫)
    func deviceStateChanged(_ id: String) {
        if id == selectedDeviceID { applySelectedState() }
    }

    func applySelectedState() {
        let device = coordinator?.devices.first { $0.id == selectedDeviceID }
        modelBadgeLabel.stringValue = device?.kind == .broadcast ? "開源廣播" : "LYWSD03MMC"
        let state = selectedDeviceID.flatMap { coordinator?.state(for: $0) } ?? DeviceState()
        if let r = state.reading {
            showReading(r)
        } else {
            showEmpty()
        }
        refreshStatus()
        reloadData()
    }

    /// 標頭的連線狀態：顏色依可否連線 (綠 = 正常、藍 = 尚未確認、橘 = 連不到)
    private func statusInfo() -> (text: String, reachable: Bool?) {
        guard let id = selectedDeviceID else { return ("尚未加入裝置，請到「設定」搜尋新裝置", nil) }
        if let global = coordinator?.globalStatus { return (global, false) }
        let state = coordinator?.state(for: id) ?? DeviceState()
        return (state.status, state.reachable)
    }

    func refreshStatus() {
        let (text, reachable) = statusInfo()
        statusDotLabel.stringValue = "● \(text)"
        statusDotLabel.toolTip = text
        switch reachable {
        case true?: statusDotLabel.textColor = NSColor(red: 0.25, green: 0.88, blue: 0.50, alpha: 1.0)
        case false?: statusDotLabel.textColor = NSColor(red: 1.0, green: 0.65, blue: 0.20, alpha: 1.0)
        case nil: statusDotLabel.textColor = NSColor(red: 0.35, green: 0.75, blue: 1.0, alpha: 1.0)
        }
    }

    // MARK: - 數據同步與更新 (Data Update)
    private var selectedHistory: HistoryManager? {
        selectedDeviceID.map { HistoryManager.forDevice($0) }
    }

    private func showEmpty() {
        for label in [tempValueLabel, humValueLabel, batValueLabel] { label?.stringValue = "--" }
        for label in [tempSubLabel, humSubLabel, batSubLabel] { label?.stringValue = "尚無數據" }
        batSubLabel.textColor = NSColor(white: 0.70, alpha: 1.0)
        deviceView.temperature = nil
        deviceView.humidity = nil
        deviceView.batteryPercent = nil
        lastUpdateLabel.stringValue = "最後讀取: --:--"
    }

    private func showReading(_ r: SensorReading) {
        tempValueLabel.stringValue = String(format: "%.1f°C", r.temperature)
        if let range = selectedHistory?.todayTemperatureRange() {
            tempSubLabel.stringValue = String(format: "今日 %.1f° ~ %.1f°", range.min, range.max)
        } else {
            tempSubLabel.stringValue = "今日尚無紀錄"
        }

        humValueLabel.stringValue = String(format: "%.0f%%", r.humidity)
        let comfort = (r.humidity >= 40 && r.humidity <= 65) ? "舒適" : (r.humidity > 65 ? "偏濕" : "偏乾")
        humSubLabel.stringValue = comfort

        batValueLabel.stringValue = String(format: "%d%%", r.batteryPercent)
        if LowBatteryPolicy.isLow(percent: r.batteryPercent, voltage: r.voltage) {
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
        df.dateFormat = "MM/dd HH:mm:ss"
        lastUpdateLabel.stringValue = "最後讀取: \(df.string(from: r.lastUpdated))"
    }

    func reloadData() {
        chartView.updatePoints(selectedHistory?.points ?? [])
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
        onRefreshRequested?(selectedDeviceID)
    }

    @objc private func handleExportCSV() {
        guard let id = selectedDeviceID, let history = selectedHistory else { return }
        let savePanel = NSSavePanel()
        savePanel.title = "匯出溫濕度歷史數據"
        savePanel.allowedContentTypes = [.commaSeparatedText]
        savePanel.nameFieldStringValue = "mijia_temp_history_\(DeviceList.fileID(id).prefix(8))_\(Int(Date().timeIntervalSince1970)).csv"

        savePanel.begin { response in
            guard response == .OK, let url = savePanel.url else { return }
            do {
                try history.exportCSV(to: url)
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
