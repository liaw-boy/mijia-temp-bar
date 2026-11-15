import AppKit
import CoreWLAN

/// 狀態列圖示、彈出式儀表板與多裝置狀態的協調者。
/// 狀態列只顯示「主裝置」；每台裝置的讀數、狀態、歷史與通知各自獨立。
final class StatusBarController: NSObject {
    private static let discoveryPromptedKey = "DiscoveryPromptShown"

    private var statusItem: NSStatusItem!
    private var bluetoothManager: BluetoothManager!
    private let deviceStore: DeviceStore
    private var states: [String: DeviceState] = [:]
    private var shownID: String?   // 狀態列目前顯示的裝置 (維持附近那台，不在兩台間跳)
    private var displayStyle: DisplayStyle = .statsBadge
    private var hideWhenDisconnected: Bool = true  // 「僅連線時顯示」：全部裝置都連不到才隱藏
    private var adapterStatus: String?
    private var adapterHint: String?
    private var forceVisibleTimer: Timer?
    private var statusWriteTimer: Timer?
    private var lastStatusWrite = Date.distantPast

    private let popover = NSPopover()
    private var popoverAnchorWidth: CGFloat = 0  // 面板打開時狀態列圖示的寬度
    private var outsideClickMonitor: Any?
    private var dashboardController: DashboardWindowController?
    private var searchWindow: DeviceSearchWindowController?
    private var reprobeTriggers: ReprobeTriggers?

    init(deviceStore: DeviceStore) {
        self.deviceStore = deviceStore
        super.init()
        loadPreferences()
        // 啟動時先用每台最後一筆歷史當快取 (避免圖示閃爍或意外消失)
        for d in deviceStore.devices { states[d.id] = cachedState(for: d) }

        setupStatusItem()
        setupPopover()

        bluetoothManager = BluetoothManager()
        bluetoothManager.delegate = self

        LocationGatekeeper.shared.bluetoothManager = bluetoothManager
        LocationGatekeeper.shared.delegate = self
        LocationGatekeeper.shared.checkCurrentStatus()

        refreshTray()
        bluetoothManager.setDevices(deviceStore.devices, order: deviceStore.orderedIDs)
        // 帶筆電換地方：喚醒或換到另一個網路時立刻重新偵測，狀態列才能改顯示附近那台
        reprobeTriggers = ReprobeTriggers { [weak self] reason in
            self?.bluetoothManager.reprobeAll(reason: reason)
        }

        // 啟動後稍等再檢查新版本，避免與藍牙初始化搶資源
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            UpdateChecker.shared.checkIfDue { status in
                self?.dashboardController?.showUpdateStatus(status)
            }
        }
        // 全新安裝 (沒有任何裝置) 時自動開啟搜尋視窗，只跳一次
        if deviceStore.devices.isEmpty && !UserDefaults.standard.bool(forKey: Self.discoveryPromptedKey) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                guard let self = self, self.deviceStore.devices.isEmpty else { return }
                mijiaLog("尚未加入任何裝置，自動開啟搜尋視窗")
                self.openDeviceSearch()
            }
        }
    }

    private func loadPreferences() {
        if UserDefaults.standard.object(forKey: "HideWhenDisconnected") != nil {
            hideWhenDisconnected = UserDefaults.standard.bool(forKey: "HideWhenDisconnected")
        } else {
            UserDefaults.standard.set(true, forKey: "HideWhenDisconnected")
        }
        if let saved = UserDefaults.standard.object(forKey: "DisplayStyle") as? Int, let style = DisplayStyle(rawValue: saved) {
            displayStyle = style
        } else {
            UserDefaults.standard.set(DisplayStyle.statsBadge.rawValue, forKey: "DisplayStyle")
        }
    }

    private func cachedState(for device: DeviceRecord) -> DeviceState {
        guard let last = HistoryManager.forDevice(device.id).lastPoint else { return DeviceState() }
        let reading = SensorReading(temperature: last.temperature, humidity: last.humidity,
                                    batteryPercent: last.batteryPercent, voltage: last.voltage, rssi: nil,
                                    deviceName: device.name, lastUpdated: last.timestamp,
                                    mode: device.kind == .stock ? AdvertisementParser.modeStock : "開源廣播",
                                    isBroadcast: device.kind == .broadcast)
        return DeviceState(reading: reading, reachable: nil, status: "使用上次紀錄", cached: true)
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.isVisible = true
        if let button = statusItem.button {
            button.title = "🌡️ 搜尋中..."
            button.toolTip = "米家藍牙溫濕度計"
            button.target = self
            button.action = #selector(handleStatusButtonClick)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            // 圖示寬度變了 (換樣式、文字長度) 才重新定位面板；狀態列調整寬度的時機不固定，直接監聽尺寸變化
            button.postsFrameChangedNotifications = true
            NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: button, queue: .main) { [weak self] _ in
                self?.reanchorPopoverIfNeeded()
            }
        }
    }

    private func setupPopover() {
        let dashboard = DashboardWindowController.shared
        dashboardController = dashboard
        dashboard.coordinator = self
        dashboard.onRefreshRequested = { [weak self] id in self?.refresh(id) }
        dashboard.onIntervalChanged = { [weak self] sec in
            self?.bluetoothManager.setRefreshInterval(sec)
        }
        dashboard.onStyleChanged = { [weak self] style in
            self?.displayStyle = style
            UserDefaults.standard.set(style.rawValue, forKey: "DisplayStyle")
            self?.updateTitle()
            // 換樣式後圖示寬度與位置會變：等狀態列排好，一律在新位置重新顯示面板
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { self?.reanchorPopoverIfNeeded(force: true) }
        }
        dashboard.onHideWhenDisconnectedChanged = { [weak self] hide in
            self?.hideWhenDisconnected = hide
            UserDefaults.standard.set(hide, forKey: "HideWhenDisconnected")
            self?.updateVisibility()
        }
        dashboard.onSettingsChanged = { [weak self] in self?.updateTitle() }
        dashboard.reloadDevices()

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
        } else if deviceStore.devices.isEmpty {
            openDeviceSearch()
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
        dashboardController?.selectDevice(deviceStore.primaryID)  // 每次打開都選回主裝置
        dashboardController?.updatePresenceStatus()
        dashboardController?.switchTab(tab)
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        popoverAnchorWidth = button.bounds.width
        installOutsideClickMonitor()
    }

    /// 常駐型 (accessory) App 的 transient 面板不會因點擊其他 App 而收起，自行監聽外部點擊
    private func installOutsideClickMonitor() {
        if let monitor = outsideClickMonitor { NSEvent.removeMonitor(monitor) }
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            self?.popover.performClose(nil)
        }
    }

    /// 圖示寬度變了 (換樣式、文字長度改變)：狀態列會移動圖示的視窗，面板不會跟著動，
    /// 只改 positioningRect 也無效，所以不帶動畫關掉再於新位置打開
    private func reanchorPopoverIfNeeded(force: Bool = false) {
        guard popover.isShown, let b = statusItem.button, force || abs(b.bounds.width - popoverAnchorWidth) > 0.5 else { return }
        popover.animates = false
        popover.close()
        popover.show(relativeTo: b.bounds, of: b, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        popover.animates = true
        popoverAnchorWidth = b.bounds.width
        installOutsideClickMonitor()
    }

    /// 右鍵選單：裝置清單、搜尋、全部更新、設定、結束
    private func showContextMenu() {
        statusItem.menu = DeviceMenuBuilder.contextMenu(for: self)
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    // MARK: - 狀態列圖示

    private func refreshTray() {
        updateTitle()
        updateVisibility()
    }

    private func updateTitle() {
        guard let button = statusItem.button else { return }
        let shown = deviceStore.device(displayedID)
        shownID = shown?.id
        guard let primary = shown else {
            StatusItemRenderer.showText("🌡️ 尚未加入裝置", on: button)
            button.toolTip = "尚未加入裝置：點一下搜尋新裝置"
            return
        }
        let state = states[primary.id] ?? DeviceState()
        if state.reading == nil && state.reachable != false {
            StatusItemRenderer.showText("🌡️ \(adapterStatus ?? state.status)", on: button)
            button.toolTip = primary.name
            return
        }
        // 主裝置連不到時 trayValues 為 nil，圖示顯示 --
        let values = DisplayRules.trayValues(state)
        StatusItemRenderer.apply(style: displayStyle, temp: values.temperature, hum: values.humidity, to: button)
        let battery = state.reading.map { "\($0.batteryPercent)%" } ?? "--"
        let note = deviceStore.primary.map { $0.id == primary.id ? "" : " (主裝置 \($0.name) 不在附近)" } ?? ""
        button.toolTip = "\(primary.name)\(note)\n溫度: \(DisplayRules.formatTemp(values.temperature))°C\n" +
            "濕度: \(DisplayRules.formatHum(values.humidity))%\n電量: \(battery)\n" +
            "更新間隔: \(Int(bluetoothManager.refreshInterval))秒\n狀態: \(state.status)"
    }

    private func updateVisibility() {
        if forceVisibleTimer != nil {
            statusItem.isVisible = true
            return
        }
        let hide = DisplayRules.shouldHideIcon(hideEnabled: hideWhenDisconnected,
                                               deviceIDs: deviceStore.devices.map(\.id), states: states)
        if hide { popover.performClose(nil) }
        statusItem.isVisible = !hide
    }

    /// 使用者在桌面點擊 App 圖示時，暫時喚起狀態列顯示 10 秒
    func temporarilyShowStatusItem() {
        forceVisibleTimer?.invalidate()
        let t = Timer(timeInterval: 10.0, repeats: false) { [weak self] _ in
            self?.forceVisibleTimer = nil
            self?.updateVisibility()
        }
        RunLoop.main.add(t, forMode: .common)
        forceVisibleTimer = t
        statusItem.isVisible = true
    }

    // MARK: - 裝置變動

    private func devicesChanged() {
        bluetoothManager.setDevices(deviceStore.devices, order: deviceStore.orderedIDs)
        dashboardController?.reloadDevices()
        refreshTray()
        scheduleStatusWrite()
    }

    private func addCandidates(_ candidates: [DiscoveredDevice]) {
        var existing = deviceStore.devices
        var newDevices: [DeviceRecord] = []
        for c in candidates {
            let d = DeviceRecord(id: c.id, name: DeviceList.defaultName(existing: existing), kind: c.kind)
            existing.append(d)
            newDevices.append(d)
        }
        for d in deviceStore.add(newDevices) {
            states[d.id] = cachedState(for: d)
            mijiaLog("已加入裝置 \(d.name) [\(d.id)] (\(d.kind.rawValue))")
        }
        devicesChanged()
    }

    private func startSearchScan() {
        guard let window = searchWindow else { return }
        window.showSearching()
        bluetoothManager.startDiscovery(
            onUpdate: { [weak self, weak window] found, progress in
                guard let w = window, self?.searchWindow === w else { return }
                w.update(found, progress: progress)
            },
            onFinish: { [weak self, weak window] found in
                guard let w = window, self?.searchWindow === w else { return }
                w.finish(found)
            })
    }

    // MARK: - 狀態 JSON (最多每 5 秒寫一次)

    private func scheduleStatusWrite() {
        guard statusWriteTimer == nil else { return }
        let wait = max(0, 5 - Date().timeIntervalSince(lastStatusWrite))
        let t = Timer(timeInterval: wait, repeats: false) { [weak self] _ in self?.writeStatus() }
        RunLoop.main.add(t, forMode: .common)
        statusWriteTimer = t
    }

    private func writeStatus() {
        statusWriteTimer = nil
        lastStatusWrite = Date()
        StatusFile.write(StatusFile.payload(devices: deviceStore.devices, states: states, primaryID: deviceStore.primaryID,
                                            displayedID: displayedID, interval: bluetoothManager.refreshInterval,
                                            adapterStatus: adapterStatus))
    }
}

// MARK: - DeviceCoordinator (選單、儀表板與設定分頁使用)
extension StatusBarController: DeviceCoordinator {
    var devices: [DeviceRecord] { deviceStore.devices }
    var primaryID: String? { deviceStore.primaryID }
    /// 狀態列實際顯示的裝置：主裝置不在附近時改為附近那台
    var displayedID: String? {
        DisplayRules.displayDeviceID(primaryID: deviceStore.primaryID, orderedIDs: deviceStore.orderedIDs, states: states,
                                     current: shownID)
    }
    var globalStatus: String? { adapterStatus.map { s in adapterHint.map { "\(s) · \($0)" } ?? s } }

    func state(for id: String) -> DeviceState { states[id] ?? DeviceState() }

    func setPrimary(_ id: String) {
        guard let device = deviceStore.device(id), id != deviceStore.primaryID else { return }
        deviceStore.setPrimary(id)
        mijiaLog("狀態列主裝置改為 \(device.name) [\(id)]")
        devicesChanged()
    }

    func refresh(_ id: String?) {
        temporarilyShowStatusItem()
        bluetoothManager.refresh(deviceID: id)
    }

    func renameDevice(_ id: String) {
        guard let device = deviceStore.device(id), let name = DeviceDialogs.askRename(current: device.name) else { return }
        do {
            try deviceStore.rename(id, to: name)
            devicesChanged()
        } catch {
            DeviceDialogs.showError("無法重新命名", error.localizedDescription)
        }
    }

    func removeDevice(_ id: String) {
        guard let device = deviceStore.device(id), DeviceDialogs.confirmRemove(name: device.name) else { return }
        deviceStore.remove(id)
        states[id] = nil
        mijiaLog("已移除裝置 \(device.name) [\(id)] (歷史檔保留)")
        devicesChanged()
    }

    func openDeviceSearch() {
        UserDefaults.standard.set(true, forKey: Self.discoveryPromptedKey)
        popover.performClose(nil)
        if let existing = searchWindow {
            NSApp.activate(ignoringOtherApps: true)
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        let window = DeviceSearchWindowController(duration: 20) { [weak self] in Set(self?.deviceStore.devices.map(\.id) ?? []) }
        window.onAdd = { [weak self] chosen in self?.addCandidates(chosen) }
        window.onRetry = { [weak self] in self?.startSearchScan() }
        window.onClose = { [weak self] in
            self?.bluetoothManager.stopDiscovery()
            self?.searchWindow = nil
        }
        searchWindow = window
        startSearchScan()
    }

    func openSettings() {
        if popover.isShown {
            dashboardController?.switchTab(.settings)
        } else {
            togglePopover(tab: .settings)
        }
    }

    func quit() {
        NSApplication.shared.terminate(nil)
    }
}

// MARK: - BluetoothManagerDelegate
extension StatusBarController: BluetoothManagerDelegate {
    func didUpdateAdapterStatus(_ status: String, available: Bool) {
        adapterStatus = available ? nil : status
        if available { adapterHint = nil }
        refreshTray()
        dashboardController?.refreshStatus()
        scheduleStatusWrite()
    }

    func didUpdateDeviceStatus(_ status: String, deviceID: String, reachable: Bool?) {
        guard deviceStore.device(deviceID) != nil else { return }  // 已移除的裝置
        states[deviceID] = state(for: deviceID).withStatus(status, reachable: reachable)
        refreshTray()
        dashboardController?.deviceStateChanged(deviceID)
        scheduleStatusWrite()
    }

    func didUpdateReading(_ reading: SensorReading, deviceID: String) {
        guard let device = deviceStore.device(deviceID) else { return }
        var r = reading
        r.deviceName = device.name
        states[deviceID] = state(for: deviceID).withReading(r)

        // 先寫入歷史，面板重繪時才包含這一筆；開源廣播依更新間隔取樣，避免每 10 秒寫一次檔
        let history = HistoryManager.forDevice(deviceID)
        if !r.isBroadcast || (history.lastPoint.map { Date().timeIntervalSince($0.timestamp) >= bluetoothManager.refreshInterval } ?? true) {
            history.addPoint(temp: r.temperature, hum: r.humidity, volt: r.voltage, battery: r.batteryPercent)
        }
        refreshTray()
        dashboardController?.deviceStateChanged(deviceID)
        NotificationManager.shared.checkReading(r, deviceID: deviceID, deviceName: device.name)
        scheduleStatusWrite()
    }

    func didFailWithError(_ error: String) {
        adapterHint = error
        dashboardController?.refreshStatus()
    }

    private static let backfillCoveredKey = "HistoryBackfillCoveredUntil"  // [裝置 id: 上次完整讀過裝置歷史的時間]

    func historyRetentionExtended() {
        UserDefaults.standard.removeObject(forKey: Self.backfillCoveredKey)
    }

    func historyGapStart(deviceID: String, interval: TimeInterval) -> Date? {
        let covered = (UserDefaults.standard.dictionary(forKey: Self.backfillCoveredKey) as? [String: Date])?[deviceID]
        return DeviceHistory.gapStart(points: HistoryManager.forDevice(deviceID).points.map(\.timestamp), now: Date(),
                                      coveredUntil: covered, interval: interval, retentionDays: HistoryManager.retentionDays)
    }

    func didReceiveHourlyHistory(_ records: [HourlyRecord], deviceNow: UInt32, reading: SensorReading,
                                 deviceID: String, coveredThrough: Date?) {
        guard deviceStore.device(deviceID) != nil else { return }
        if let through = coveredThrough {
            var covered = UserDefaults.standard.dictionary(forKey: Self.backfillCoveredKey) as? [String: Date] ?? [:]
            covered[deviceID] = through
            UserDefaults.standard.set(covered, forKey: Self.backfillCoveredKey)
        }
        let history = HistoryManager.forDevice(deviceID)
        let before = history.points.count
        let merged = DeviceHistory.fill(existing: history.points, records: records, deviceNow: deviceNow, now: Date(),
                                        voltage: reading.voltage, battery: reading.batteryPercent)
        guard merged.count > before else { return }
        history.replaceAll(merged)
        mijiaLog("用裝置歷史補上 \(merged.count - before) 筆空白 [\(deviceID)]")
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
        guard !popover.isShown else { return }  // 重新定位時關掉又立刻打開：保留外部點擊監聽
        if let monitor = outsideClickMonitor {
            NSEvent.removeMonitor(monitor)
            outsideClickMonitor = nil
        }
    }
}
