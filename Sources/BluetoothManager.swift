import Foundation
import CoreBluetooth

protocol BluetoothManagerDelegate: AnyObject {
    /// 電腦藍牙或離家停機等全域狀態；available 為 false 時 status 會顯示在狀態列與儀表板
    func didUpdateAdapterStatus(_ status: String, available: Bool)
    /// 單台裝置的狀態；reachable 為 nil 表示可連線與否沒有改變
    func didUpdateDeviceStatus(_ status: String, deviceID: String, reachable: Bool?)
    func didUpdateReading(_ reading: SensorReading, deviceID: String)
    func didFailWithError(_ error: String)
    /// 最近 30 天內第一個空白的起點 (決定要不要、從哪裡讀裝置內存的每小時紀錄)；沒有空白回傳 nil
    func historyGapStart(deviceID: String, interval: TimeInterval) -> Date?
    /// 讀到裝置內存的每小時紀錄 (在這次的 didUpdateReading 之前呼叫)。
    /// coveredThrough：裝置歷史已讀到的時間 (這之前補不到的空白裝置也沒有紀錄，之後不再重讀)；沒有進度時為 nil
    func didReceiveHourlyHistory(_ records: [HourlyRecord], deviceNow: UInt32, reading: SensorReading,
                                 deviceID: String, coveredThrough: Date?)
}

/// CoreBluetooth 多裝置管理：原廠 GATT 即連即斷輪詢 (一次只連一台)、開源廣播接收與搜尋新裝置。
/// central 使用主佇列，所有狀態都只在主執行緒存取。
final class BluetoothManager: NSObject {
    weak var delegate: BluetoothManagerDelegate?

    private var centralManager: CBCentralManager!
    private(set) var refreshInterval: TimeInterval = 300.0
    private(set) var isSuspended = false
    private var suspendReason = ""

    // 原廠韌體 UUID 定義
    private let serviceUUID = CBUUID(string: "EBE0CCB0-7A0A-4B0C-8A1A-6FF2997DA3A6")
    private let charUUID = CBUUID(string: "EBE0CCC1-7A0A-4B0C-8A1A-6FF2997DA3A6")
    // 裝置內存的每小時紀錄 (同一個 service，免認證)
    private let timeUUID = CBUUID(string: "EBE0CCB7-7A0A-4B0C-8A1A-6FF2997DA3A6")
    private let countUUID = CBUUID(string: "EBE0CCB9-7A0A-4B0C-8A1A-6FF2997DA3A6")
    private let indexUUID = CBUUID(string: "EBE0CCBA-7A0A-4B0C-8A1A-6FF2997DA3A6")
    private let recordsUUID = CBUUID(string: "EBE0CCBC-7A0A-4B0C-8A1A-6FF2997DA3A6")
    private let historyRetryInterval: TimeInterval = 3 * 3600  // 讀歷史失敗或裝置沒紀錄時，隔這麼久才再試
    private let broadcastMinInterval: TimeInterval = 10  // 開源廣播每台裝置最短的介面更新間隔

    /// wasFailing：手動更新前已連續失敗 (退避被手動重設)，這次連線仍視為連不到的裝置，可被另一台的手動更新插隊
    private struct Runtime { var due: Date; var failures = 0; var lastSuccess: Date?; var wasFailing = false }
    private struct BroadcastState { var lastSeen: Date; var lastEmit = Date.distantPast; var staleReported = false }
    private enum Phase { case locating, connecting, connected, history }
    private struct Attempt { let id: String; let token: Int; var phase: Phase; var timer: Timer }
    /// 讀完當下數值後接著讀裝置內存的歷史；任何一步失敗都只保留已收到的部分，當下讀數照常記錄
    private struct HistoryRun {
        let reading: SensorReading
        let since: Date
        let startedAt = Date()
        var complete = false   // 這一段讀到 lastIndex 為止 (或裝置沒有紀錄)
        var noRecords = false  // 裝置沒有可讀的紀錄
        var total: UInt32 = 0
        var deviceNow: UInt32?
        var startIndex: UInt32?
        var lastIndex: UInt32 = 0
        var written = false    // 起始 index 寫入完成後才認最後一筆 (先推的舊紀錄可能剛好落在範圍內)
        var lastSeen = false
        var seen = Set<UInt32>()  // 已收到的 index
        var records: [HourlyRecord] = []
    }
    private enum Outcome { case success(SensorReading), failure(String, timeout: Bool), cancelled }
    private enum ScanReason { case discovery, rediscover }
    private struct Discovery {
        var found: [String: DiscoveredDevice] = [:]
        var remaining: TimeInterval
        let duration: TimeInterval
        let timer: Timer
        let onUpdate: ([DiscoveredDevice], Double) -> Void
        let onFinish: ([DiscoveredDevice]) -> Void
    }

    private var devices: [String: DeviceRecord] = [:]
    private var order: [String] = []                  // 原廠裝置的輪詢順序 (主裝置在最前面)
    private var runtimes: [String: Runtime] = [:]
    private var broadcasts: [String: BroadcastState] = [:]
    private var peripherals: [UUID: CBPeripheral] = [:]  // 強參照：CoreBluetooth 會取消沒人持有的連線
    private var attempt: Attempt?
    private var historyRun: HistoryRun?
    private var lastHistoryAttempt: [String: Date] = [:]
    private var attemptCounter = 0
    private var oneShotIDs = Set<String>()            // 離家停機時手動要求的單次讀取
    private var manualIDs = Set<String>()             // 手動要求更新的裝置，下次優先讀
    private var sleepingAfterRead = Set<String>()     // 讀取成功後主動斷線的裝置 (斷線回呼時記錄「進入休眠」)
    private var scanReasons = Set<ScanReason>()
    private var isScanning = false
    private var schedulerTimer: Timer?
    private var discovery: Discovery?

    override init() {
        super.init()
        // 讀取偏好設定中的更新間隔
        if let saved = UserDefaults.standard.object(forKey: "RefreshIntervalSeconds") as? Double, saved >= 10.0, saved <= 86400 {
            refreshInterval = saved
        } else {
            UserDefaults.standard.set(300.0, forKey: "RefreshIntervalSeconds")
        }
        mijiaLog("BluetoothManager 初始化 (多裝置省電輪詢模式，設定間隔: \(Int(refreshInterval)) 秒)...")
        centralManager = CBCentralManager(delegate: self, queue: .main)
    }

    // MARK: - 公開介面

    /// 更新裝置清單與輪詢順序 (order 第一台為主裝置)
    func setDevices(_ records: [DeviceRecord], order primaryFirst: [String]) {
        let now = Date()
        devices = Dictionary(records.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        order = primaryFirst.filter { devices[$0]?.kind == .stock }
        manualIDs = manualIDs.filter { devices[$0] != nil }
        runtimes = Dictionary(order.map { ($0, runtimes[$0] ?? Runtime(due: now)) }, uniquingKeysWith: { first, _ in first })
        broadcasts = Dictionary(records.filter { $0.kind == .broadcast }.map {
            ($0.id, broadcasts[$0.id] ?? BroadcastState(lastSeen: now))  // 新加入的廣播裝置給緩衝時間
        }, uniquingKeysWith: { first, _ in first })
        peripherals = peripherals.filter { devices[$0.key.uuidString] != nil || $0.key.uuidString == attempt?.id }
        if let a = attempt, devices[a.id] == nil {
            finishAttempt(a.id, token: a.token, outcome: .cancelled)
        }
        retrieveKnownPeripherals()
        updateScanning()
        scheduleTick(after: 0)
    }

    func setRefreshInterval(_ seconds: TimeInterval) {
        refreshInterval = seconds
        UserDefaults.standard.set(seconds, forKey: "RefreshIntervalSeconds")
        mijiaLog("連線間隔已調整為: \(Int(seconds)) 秒")
        let now = Date()
        for (id, rt) in runtimes where rt.failures == 0 {
            runtimes[id]?.due = Backoff.dueAfterIntervalChange(lastSuccess: rt.lastSuccess, interval: seconds, now: now)
        }
        scheduleTick(after: 0)
    }

    /// 立即更新原廠裝置 (nil 為全部) 並重設其退避；離家停機時只讀一次，不解除停機
    func refresh(deviceID: String? = nil) {
        let targets = order.filter { deviceID == nil || $0 == deviceID }
        let now = Date()
        for id in targets {
            guard var rt = runtimes[id] else { continue }
            rt.wasFailing = rt.wasFailing || rt.failures > 0
            rt.due = now
            rt.failures = 0
            runtimes[id] = rt
        }
        manualIDs.formUnion(targets)
        // 正在對另一台連不到的裝置連線 (離線重試，或對它的手動更新)：先中斷那次 (不算失敗)，否則要等它逾時才輪到手動更新
        // 讀裝置歷史期間 (當下數值已讀到) 不插隊，最多等 DeviceHistory.totalTimeout
        if let a = attempt, a.phase != .history, !targets.contains(a.id), let current = runtimes[a.id], current.failures > 0 || current.wasFailing {
            mijiaLog("手動更新插隊：中斷 [\(a.id)] 的連線 (這台原本就連不到，不算失敗)")
            finishAttempt(a.id, token: a.token, outcome: .cancelled)
            delegate?.didUpdateDeviceStatus("設備未在連線範圍內", deviceID: a.id, reachable: false)
        }
        if isSuspended {
            oneShotIDs.formUnion(targets)
            mijiaLog("離家停機中，手動要求只讀取一次 (不解除停機)")
        } else {
            mijiaLog("手動要求立即重新整理 [\(deviceID ?? "全部")]...")
        }
        scheduleTick(after: 0)
    }

    /// 換地方 (喚醒、換網路)：所有原廠裝置立刻重讀一次；失敗次數保留，久未出現的裝置逾時仍較短
    func reprobeAll(reason: String) {
        guard !isSuspended else { return }
        mijiaLog("\(reason)：所有裝置立刻重新偵測")
        let now = Date()
        for id in runtimes.keys { runtimes[id]?.due = now }
        scheduleTick(after: 0)
    }

    /// 離開居家大範圍時全面停止輪詢與廣播掃描 (0 耗電)；使用者主動的搜尋與單次讀取仍可進行
    func suspend(reason: String = "已離開居家大範圍") {
        guard !isSuspended else { return }
        isSuspended = true
        suspendReason = reason
        if let a = attempt {
            finishAttempt(a.id, token: a.token, outcome: .cancelled)
        }
        updateScanning()
        mijiaLog("【大範圍地理圍欄】\(reason)，全面暫停藍牙輪詢 (0 耗電)")
        delegate?.didUpdateAdapterStatus("\(reason) · 休眠停機", available: false)
    }

    /// 回到居家大範圍內，自動喚醒恢復輪詢
    func resume() {
        guard isSuspended else { return }
        isSuspended = false
        let now = Date()
        for id in runtimes.keys {
            runtimes[id]?.failures = 0
            runtimes[id]?.due = now
        }
        for id in broadcasts.keys {
            broadcasts[id]?.lastSeen = now
        }
        mijiaLog("【大範圍地理圍欄】已回到居家範圍，自動喚醒並發起連線...")
        if centralManager.state == .poweredOn {
            delegate?.didUpdateAdapterStatus("已進入居家範圍，連線中...", available: true)
        } else {
            centralManagerDidUpdateState(centralManager)  // 藍牙仍未就緒：維持顯示藍牙的狀態
        }
        updateScanning()
        scheduleTick(after: 0)
    }

    // MARK: - 搜尋新裝置

    /// onUpdate 每秒回報 (目前找到的候選, 進度 0~1)；藍牙還沒就緒時不倒數
    func startDiscovery(duration: TimeInterval = 20, onUpdate: @escaping ([DiscoveredDevice], Double) -> Void,
                        onFinish: @escaping ([DiscoveredDevice]) -> Void) {
        guard discovery == nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.discoveryTick() }
        RunLoop.main.add(timer, forMode: .common)
        discovery = Discovery(remaining: duration, duration: duration, timer: timer, onUpdate: onUpdate, onFinish: onFinish)
        scanReasons.insert(.discovery)
        updateScanning()
        mijiaLog("開始搜尋新裝置...")
    }

    /// 取消搜尋 (不回呼結果)
    func stopDiscovery() {
        finishDiscovery(notify: false)
    }

    private func discoveryTick() {
        guard var d = discovery else { return }
        if isScanning { d.remaining -= 1 }
        discovery = d
        if d.remaining <= 0 {
            finishDiscovery(notify: true)
        } else {
            d.onUpdate(Array(d.found.values), 1 - d.remaining / d.duration)
        }
    }

    private func finishDiscovery(notify: Bool) {
        guard let d = discovery else { return }
        d.timer.invalidate()
        discovery = nil
        scanReasons.remove(.discovery)
        updateScanning()
        mijiaLog("搜尋結束，找到 \(d.found.count) 台溫濕度計 (含已加入的)")
        if notify { d.onFinish(Array(d.found.values)) }
    }

    // MARK: - 輪詢排程 (一次只連一台)

    private func scheduleTick(after seconds: TimeInterval) {
        schedulerTimer?.invalidate()
        // 加到 common 模式：選單開著時計時器照樣觸發
        let t = Timer(timeInterval: max(0.05, seconds), repeats: false) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        schedulerTimer = t
    }

    private func tick() {
        checkBroadcastStaleness()
        guard centralManager.state == .poweredOn, attempt == nil else {
            scheduleTick(after: Backoff.maxWait)
            return
        }
        let eligible = isSuspended ? order.filter { oneShotIDs.contains($0) } : order
        let prioritized = eligible.filter { manualIDs.contains($0) } + eligible.filter { !manualIDs.contains($0) }
        let due = runtimes.filter { eligible.contains($0.key) }.mapValues(\.due)
        let next = Backoff.pickNextDue(due: due, order: prioritized, now: Date())
        if let id = next.id {
            beginAttempt(id)
        } else {
            scheduleTick(after: next.wait)
        }
    }

    private func beginAttempt(_ id: String) {
        guard let uuid = UUID(uuidString: id) else {
            runtimes[id]?.due = .distantFuture
            scheduleTick(after: 0)
            return
        }
        attemptCounter += 1
        let token = attemptCounter
        let timeout = Backoff.connectTimeout(failures: runtimes[id]?.failures ?? 0)
        let timer = Timer(timeInterval: timeout, repeats: false) { [weak self] _ in
            self?.finishAttempt(id, token: token, outcome: .failure("連線超時 (設備未在連線範圍內)", timeout: true))
        }
        RunLoop.main.add(timer, forMode: .common)
        attempt = Attempt(id: id, token: token, phase: .locating, timer: timer)
        oneShotIDs.remove(id)
        manualIDs.remove(id)
        delegate?.didUpdateDeviceStatus("更新數據連線中...", deviceID: id, reachable: nil)

        if let p = peripherals[uuid] ?? centralManager.retrievePeripherals(withIdentifiers: [uuid]).first {
            peripherals[uuid] = p
            connect(p)
        } else {
            // 系統不認得這台 (例如重開機後)：在逾時內用掃描找回來
            mijiaLog("系統尚未記得設備 [\(id)]，掃描尋找中...")
            scanReasons.insert(.rediscover)
            updateScanning()
        }
    }

    private func connect(_ p: CBPeripheral) {
        guard var a = attempt, a.id == p.identifier.uuidString else { return }
        mijiaLog("正在快速連線至設備 \(devices[a.id]?.name ?? a.id) [\(a.id)]...")
        p.delegate = self
        a.phase = .connecting
        attempt = a
        centralManager.connect(p, options: nil)
    }

    /// 結束這次連線 (只認目前這一次；逾時後才到的回呼一律忽略)，斷線並排定下一次
    private func finishAttempt(_ id: String, token: Int, outcome: Outcome) {
        guard let a = attempt, a.id == id, a.token == token else { return }
        var outcome = outcome
        if case .cancelled = outcome, a.phase == .history, let run = historyRun {
            // 讀歷史時被中斷 (停機、藍牙關閉、移除裝置)：當下數值已讀到，照常記錄並交出已收到的紀錄
            deliverHistory(id, run)
            outcome = .success(run.reading)
        }
        a.timer.invalidate()
        attempt = nil
        historyRun = nil
        if let uuid = UUID(uuidString: id), let p = peripherals[uuid], p.state != .disconnected {
            centralManager.cancelPeripheralConnection(p)
        }
        if scanReasons.remove(.rediscover) != nil { updateScanning() }

        switch outcome {
        case .success(let reading):
            sleepingAfterRead.insert(id)
            recordSuccess(id, reading)
        case .failure(let message, let timeout): recordFailure(id, message, timeout: timeout)
        case .cancelled: break
        }
        scheduleTick(after: 0)
    }

    private func recordSuccess(_ id: String, _ reading: SensorReading) {
        guard var rt = runtimes[id] else { return }  // 讀取期間被移除的裝置：結果丟棄
        let now = Date()
        rt.failures = 0
        rt.wasFailing = false
        rt.lastSuccess = now
        rt.due = now.addingTimeInterval(refreshInterval)
        runtimes[id] = rt
        delegate?.didUpdateReading(reading, deviceID: id)
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        let status = isSuspended ? "離家停機中 (已手動讀取一次)" : "省電休眠中 (下次更新 \(formatter.string(from: rt.due)))"
        delegate?.didUpdateDeviceStatus(status, deviceID: id, reachable: true)
    }

    private func recordFailure(_ id: String, _ message: String, timeout: Bool) {
        guard var rt = runtimes[id] else { return }
        rt.failures += 1
        rt.wasFailing = false
        let delay = Backoff.retryDelay(failures: rt.failures, interval: refreshInterval)
        rt.due = Date().addingTimeInterval(delay)
        runtimes[id] = rt
        mijiaLog("\(message) [\(id)]；離線退避 (連續失敗 \(rt.failures) 次)，\(Int(delay)) 秒後重試")
        delegate?.didUpdateDeviceStatus(timeout ? "設備未在連線範圍內" : "連線失敗，等待下次輪詢", deviceID: id, reachable: false)
    }

    // MARK: - 掃描與廣播

    private func updateScanning() {
        let wantBroadcast = !broadcasts.isEmpty && !isSuspended
        let want = (wantBroadcast || !scanReasons.isEmpty) && centralManager.state == .poweredOn
        if want && !isScanning {
            isScanning = true
            mijiaLog("開始掃描周圍藍牙設備...")
            // 不用 Service 過濾：ATC / pvvx 只廣播 Service Data，過濾可能收不到
            centralManager.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        } else if !want && isScanning {
            isScanning = false
            centralManager.stopScan()
            mijiaLog("停止掃描。")
        }
    }

    private func retrieveKnownPeripherals() {
        guard centralManager.state == .poweredOn else { return }
        let missing = order.compactMap(UUID.init(uuidString:)).filter { peripherals[$0] == nil }
        for p in centralManager.retrievePeripherals(withIdentifiers: missing) {
            peripherals[p.identifier] = p
        }
    }

    private func handleBroadcast(_ id: String, _ m: Measurement, rssi: Int) {
        guard var s = broadcasts[id], !isSuspended else { return }
        let now = Date()
        s.lastSeen = now
        if !s.staleReported && now.timeIntervalSince(s.lastEmit) < broadcastMinInterval {
            broadcasts[id] = s
            return
        }
        s.lastEmit = now
        s.staleReported = false
        broadcasts[id] = s
        let reading = SensorReading(m, name: devices[id]?.name ?? id, rssi: rssi, isBroadcast: true)
        delegate?.didUpdateReading(reading, deviceID: id)
    }

    private func checkBroadcastStaleness() {
        guard !isSuspended else { return }
        let now = Date()
        for (id, s) in broadcasts where !s.staleReported
            && Backoff.isBroadcastStale(lastSeen: s.lastSeen, interval: refreshInterval, now: now) {
            broadcasts[id]?.staleReported = true
            mijiaLog("太久沒收到廣播 [\(id)]")
            delegate?.didUpdateDeviceStatus("未收到廣播", deviceID: id, reachable: false)
        }
    }
}

// MARK: - CBCentralManagerDelegate
extension BluetoothManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        mijiaLog("CBCentralManager 狀態更新: \(central.state.rawValue)")
        if central.state != .poweredOn, let a = attempt {
            finishAttempt(a.id, token: a.token, outcome: .cancelled)
        }
        switch central.state {
        case .poweredOn:
            if isSuspended {
                delegate?.didUpdateAdapterStatus("\(suspendReason) · 休眠停機", available: false)
            } else {
                delegate?.didUpdateAdapterStatus("藍牙已就緒", available: true)
            }
            retrieveKnownPeripherals()
            updateScanning()
            scheduleTick(after: 0)
            return
        case .poweredOff:
            reportAdapter("電腦藍牙已關閉", hint: "請在 Mac 控制中心開啟藍牙")
        case .unauthorized:
            reportAdapter("藍牙未授權", hint: "請在 系統設定 > 隱私權與安全性 > 藍牙 允許存取")
        case .unsupported:
            reportAdapter("硬體不支援藍牙", hint: nil)
        case .resetting:
            peripherals.removeAll()  // 重置後舊的裝置物件失效
            reportAdapter("藍牙重新啟動中...", hint: nil)
        default:
            reportAdapter("藍牙初始化中...", hint: nil)
        }
        isScanning = false
    }

    private func reportAdapter(_ status: String, hint: String?) {
        mijiaLog("藍牙狀態: \(status)")
        delegate?.didUpdateAdapterStatus(status, available: false)
        if let hint = hint { delegate?.didFailWithError(hint) }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let id = peripheral.identifier.uuidString
        let locating = attempt.map { $0.id == id && $0.phase == .locating } ?? false
        guard discovery != nil || broadcasts[id] != nil || locating else { return }
        let name = peripheral.name ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? ""
        let raw = advertisementData[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data] ?? [:]
        // 廣播內容來自附近任何裝置，不可信：重複的鍵只取第一筆 (uniqueKeysWithValues 遇到重複會讓程式崩潰)
        let serviceData = Dictionary(raw.map { ($0.key.uuidString.uppercased(), $0.value) }, uniquingKeysWith: { first, _ in first })

        if discovery != nil, let c = DeviceDiscovery.candidate(id: id, name: name, rssi: RSSI.intValue, serviceData: serviceData) {
            let merged = DeviceDiscovery.merge(discovery?.found[c.id], c)  // 先算好再寫入 (同一行讀寫會違反獨佔存取)
            discovery?.found[c.id] = merged
            if c.kind == .stock { peripherals[peripheral.identifier] = peripheral }
        }
        if let a = attempt, a.id == id, a.phase == .locating {
            peripherals[peripheral.identifier] = peripheral
            scanReasons.remove(.rediscover)
            updateScanning()
            connect(peripheral)
        }
        if broadcasts[id] != nil, let m = AdvertisementParser.broadcastMeasurement(serviceData) {
            handleBroadcast(id, m, rssi: RSSI.intValue)
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard var a = attempt, a.id == peripheral.identifier.uuidString, a.phase == .connecting else { return }
        a.phase = .connected
        attempt = a
        mijiaLog("已連線至 \(devices[a.id]?.name ?? "設備") [\(a.id)]，正在探索溫濕度服務...")
        delegate?.didUpdateDeviceStatus("讀取感測數據中...", deviceID: a.id, reachable: nil)
        peripheral.discoverServices([serviceUUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard let a = attempt, a.id == peripheral.identifier.uuidString else { return }
        finishAttempt(a.id, token: a.token, outcome: .failure("連線失敗: \(error?.localizedDescription ?? "未知原因")", timeout: false))
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        let id = peripheral.identifier.uuidString
        if let a = attempt, a.id == id, a.phase == .history {
            finishHistory("讀取裝置歷史時斷線")
        } else if let a = attempt, a.id == id, a.phase == .connected {
            // 讀到數據前就斷線：算一次失敗並排定重試 (舊版在這裡會停止輪詢)
            finishAttempt(id, token: a.token, outcome: .failure("非預期連線中斷: \(error?.localizedDescription ?? "正常斷線")", timeout: false))
        } else if sleepingAfterRead.remove(id) != nil {
            mijiaLog("設備已成功進入省電休眠 [\(id)]。")
        }
    }
}

// MARK: - CBPeripheralDelegate (原廠韌體 GATT 解析)
extension BluetoothManager: CBPeripheralDelegate {
    /// 目前這次連線且已連上 (逾時後才到的舊回呼不算)
    private func currentConnected(_ peripheral: CBPeripheral) -> Attempt? {
        guard let a = attempt, a.id == peripheral.identifier.uuidString, a.phase == .connected else { return nil }
        return a
    }

    private func failCurrent(_ peripheral: CBPeripheral, _ message: String) {
        guard let a = currentConnected(peripheral) else { return }
        finishAttempt(a.id, token: a.token, outcome: .failure(message, timeout: false))
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard currentConnected(peripheral) != nil else { return }
        guard let service = peripheral.services?.first(where: { $0.uuid == serviceUUID }) else {
            failCurrent(peripheral, "找不到溫濕度服務: \(error?.localizedDescription ?? "無此服務")")
            return
        }
        peripheral.discoverCharacteristics([charUUID], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if currentHistory(peripheral) != nil {
            guard let time = characteristic(timeUUID, peripheral) else {
                finishHistory("找不到裝置時間特徵值")
                return
            }
            peripheral.readValue(for: time)
            return
        }
        guard currentConnected(peripheral) != nil else { return }
        guard let char = service.characteristics?.first(where: { $0.uuid == charUUID }) else {
            failCurrent(peripheral, "找不到溫濕度特徵值: \(error?.localizedDescription ?? "無此特徵值")")
            return
        }
        mijiaLog("找到 Characteristic: \(char.uuid)，單次讀取溫濕度數據 (不開 Notify 以杜絕頻繁喚醒)...")
        // 注意：絕對不要呼叫 setNotifyValue(true)，否則硬體會每 6 秒主動發射一次射頻，導致嚴重耗電！
        peripheral.readValue(for: char)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if currentHistory(peripheral) != nil {
            handleHistoryValue(peripheral, characteristic, error: error)
            return
        }
        guard characteristic.uuid == charUUID, let a = currentConnected(peripheral) else { return }
        guard error == nil, let data = characteristic.value, let m = AdvertisementParser.parseStockGATT(data) else {
            failCurrent(peripheral, "讀取失敗: \(error?.localizedDescription ?? "數據長度不足")")
            return
        }
        mijiaLog("收到原廠數據: 溫度=\(m.temperature)°C, 濕度=\(m.humidity)%, 電壓=\(m.voltage)V, 電量=\(m.batteryPercent)% [\(a.id)]")
        let reading = SensorReading(m, name: devices[a.id]?.name ?? (peripheral.name ?? a.id), rssi: nil, isBroadcast: false)

        // 歷史有超過 1 小時的空白 (電腦睡眠、離家、不在範圍內) 才順便讀裝置內存的每小時紀錄
        let now = Date()
        if let since = delegate?.historyGapStart(deviceID: a.id, interval: refreshInterval),
           lastHistoryAttempt[a.id].map({ now.timeIntervalSince($0) >= historyRetryInterval }) ?? true,
           let service = peripheral.services?.first(where: { $0.uuid == serviceUUID }) {
            startHistory(peripheral, service, a, reading: reading, since: since)
            return
        }

        // ★★★ 極致省電核心機制 ★★★
        // 讀取完畢後，立刻主動斷開 BLE GATT 連線 (finishAttempt 內)，
        // 讓硬體 TLSR8251 晶片立刻進入 Deep Sleep 休眠模式，耗電瞬間從 150µA 降至 15µA！
        mijiaLog("數據讀取完成，立刻主動斷開連線以讓硬體休眠省電 (下次連線間隔: \(Int(refreshInterval)) 秒)...")
        finishAttempt(a.id, token: a.token, outcome: .success(reading))
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == recordsUUID, currentHistory(peripheral) != nil, let run = historyRun else { return }
        guard error == nil, let index = self.characteristic(indexUUID, peripheral) else {
            finishHistory("無法訂閱歷史紀錄: \(error?.localizedDescription ?? "找不到特徵值")")
            return
        }
        guard let deviceNow = run.deviceNow, let start = run.startIndex else {
            finishHistory("缺少裝置時間")
            return
        }
        mijiaLog("讀取裝置歷史: 從第 \(start) 筆到第 \(run.lastIndex) 筆 (裝置時間 \(deviceNow))")
        let type: CBCharacteristicWriteType = index.properties.contains(.write) ? .withResponse : .withoutResponse
        peripheral.writeValue(DeviceHistory.uint32Data(start), for: index, type: type)
        if type == .withoutResponse, var r = historyRun {  // 沒有寫入回應可等，視為已寫入
            r.written = true
            historyRun = r
        }
    }

    // MARK: - 裝置內存歷史

    private func currentHistory(_ peripheral: CBPeripheral) -> Attempt? {
        guard let a = attempt, a.id == peripheral.identifier.uuidString, a.phase == .history, historyRun != nil else { return nil }
        return a
    }

    private func characteristic(_ uuid: CBUUID, _ peripheral: CBPeripheral) -> CBCharacteristic? {
        peripheral.services?.first(where: { $0.uuid == serviceUUID })?.characteristics?.first(where: { $0.uuid == uuid })
    }

    private func startHistory(_ peripheral: CBPeripheral, _ service: CBService, _ a: Attempt, reading: SensorReading, since: Date) {
        var a = a
        lastHistoryAttempt[a.id] = Date()
        a.phase = .history
        attempt = a
        historyRun = HistoryRun(reading: reading, since: since)
        armHistoryTimer(DeviceHistory.setupTimeout)
        mijiaLog("歷史有空白，讀取裝置內存的每小時紀錄 (從 \(since) 起) [\(a.id)]...")
        peripheral.discoverCharacteristics([timeUUID, countUUID, indexUUID, recordsUUID], for: service)
    }

    private func handleHistoryValue(_ peripheral: CBPeripheral, _ characteristic: CBCharacteristic, error: Error?) {
        guard var run = historyRun else { return }
        guard error == nil, let data = characteristic.value else {
            finishHistory("讀取裝置歷史失敗: \(error?.localizedDescription ?? "沒有資料")")
            return
        }
        switch characteristic.uuid {
        case timeUUID:
            guard let deviceNow = DeviceHistory.parseDeviceTime(data), let count = self.characteristic(countUUID, peripheral) else {
                finishHistory("無法解析裝置時間")
                return
            }
            run.deviceNow = deviceNow
            historyRun = run
            peripheral.readValue(for: count)
        case countUUID:
            guard let count = DeviceHistory.parseCount(data), count.total > 0,
                  let start = DeviceHistory.startIndex(total: count.total, stored: count.stored, since: run.since, now: Date()),
                  let records = self.characteristic(recordsUUID, peripheral) else {
                run.complete = true  // 裝置沒有紀錄：之前的空白補不到，之後不再重讀
                run.noRecords = true
                historyRun = run
                finishHistory("裝置沒有可讀的歷史紀錄")
                return
            }
            run.total = count.total
            run.lastIndex = DeviceHistory.chunkEnd(start: start, total: count.total)  // 一次最多 30 天，更早的下次接著讀
            run.startIndex = start
            historyRun = run
            peripheral.setNotifyValue(true, for: records)
        case recordsUUID:
            // 訂閱後、寫入起始位置前裝置會先推幾筆舊的 (實機確認)：比起始舊的略過
            // 只收這一段範圍內的 (先推的舊紀錄可能落在範圍外，包括比結尾新的)
            guard let index = DeviceHistory.recordIndex(data), index >= run.startIndex ?? 0, index <= run.lastIndex else { return }
            // 同一筆重送就不再收 (裝置資料不可信，也避免之後補空白時重複計算)
            if !run.seen.contains(index), run.records.count < Int(DeviceHistory.maxRecords),
               let record = DeviceHistory.parseRecord(data) {  // 數值不合理就不收
                run.records.append(record)
            }
            run.seen.insert(index)
            if index >= run.lastIndex { run.lastSeen = true }
            historyRun = run
            armHistoryTimer(DeviceHistory.idleTimeout)  // 資料還在進來就繼續等
            if run.lastSeen && run.written { finishHistory(nil, complete: true) }
        default:
            break
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == indexUUID, currentHistory(peripheral) != nil, var run = historyRun else { return }
        if let error = error {
            finishHistory("寫入歷史起始位置失敗: \(error.localizedDescription)")
            return
        }
        run.written = true
        historyRun = run
        if run.lastSeen { finishHistorySoon() }
    }

    /// 最後一筆在寫入回應前就到了 (可能是寫入前先推的舊紀錄)：再等一下，沒有新的就結束
    private func finishHistorySoon() {
        guard let a = attempt else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self = self, let cur = self.attempt, cur.token == a.token else { return }
            self.finishHistory(nil, complete: true)
        }
    }

    /// 讀歷史的逾時：每收到一筆就重新計時，但整次不超過 totalTimeout
    private func armHistoryTimer(_ seconds: TimeInterval) {
        guard var a = attempt, a.phase == .history, let run = historyRun else { return }
        let left = DeviceHistory.totalTimeout - Date().timeIntervalSince(run.startedAt)
        a.timer.invalidate()
        let id = a.id, token = a.token
        let timer = Timer(timeInterval: max(0.1, min(seconds, left)), repeats: false) { [weak self] _ in
            guard let self = self, let cur = self.attempt, cur.id == id, cur.token == token else { return }
            self.finishHistory("讀取裝置歷史逾時")
        }
        RunLoop.main.add(timer, forMode: .common)
        a.timer = timer
        attempt = a
    }

    /// 結束讀取歷史 (成功或失敗都一樣)：交出已收到的紀錄，當下讀數照常記錄
    private func finishHistory(_ failure: String?, complete: Bool = false) {
        guard let a = attempt, a.phase == .history, var run = historyRun else { return }
        if let failure = failure { mijiaLog("\(failure) [\(a.id)]；保留已收到的 \(run.records.count) 筆") }
        if complete { run.complete = true }
        historyRun = nil  // 已交出，finishAttempt 不再重複處理
        deliverHistory(a.id, run)
        finishAttempt(a.id, token: a.token, outcome: .success(run.reading))
    }

    private func deliverHistory(_ id: String, _ run: HistoryRun) {
        guard let deviceNow = run.deviceNow, !run.records.isEmpty || run.complete else { return }
        let now = Date()
        let reachedEnd = run.complete && (run.noRecords || run.lastIndex + 1 >= run.total)
        let covered: Date?
        if reachedEnd {
            covered = now
        } else if run.complete {
            // 這一段讀完 (即使都是無效紀錄也往前推進)：每筆一小時，依 index 換算這段結尾的時間
            covered = now.addingTimeInterval(-Double(run.total - 1 - run.lastIndex) * 3600)
        } else {
            covered = run.records.max(by: { $0.index < $1.index }).map { DeviceHistory.realEnd($0, deviceNow: deviceNow, now: now) }
        }
        if run.complete && !reachedEnd {
            lastHistoryAttempt[id] = nil  // 這一段讀完了，下次連線就接著讀下一段
        }
        mijiaLog("收到裝置歷史 \(run.records.count) 筆 [\(id)]\(reachedEnd ? "" : run.complete ? " (還有更新的，下次接著讀)" : " (未讀完)")")
        delegate?.didReceiveHourlyHistory(run.records, deviceNow: deviceNow, reading: run.reading,
                                          deviceID: id, coveredThrough: covered)
    }
}
