import Foundation
import CoreBluetooth

protocol BluetoothManagerDelegate: AnyObject {
    /// 電腦藍牙或離家停機等全域狀態；available 為 false 時 status 會顯示在狀態列與儀表板
    func didUpdateAdapterStatus(_ status: String, available: Bool)
    /// 單台裝置的狀態；reachable 為 nil 表示可連線與否沒有改變
    func didUpdateDeviceStatus(_ status: String, deviceID: String, reachable: Bool?)
    func didUpdateReading(_ reading: SensorReading, deviceID: String)
    func didFailWithError(_ error: String)
}

/// CoreBluetooth 多裝置管理：原廠 GATT 即連即斷輪詢 (一次只連一台)、開源廣播接收與搜尋新裝置。
/// central 使用主佇列，所有狀態都只在主執行緒存取。
final class BluetoothManager: NSObject {
    weak var delegate: BluetoothManagerDelegate?

    private var centralManager: CBCentralManager!
    private(set) var refreshInterval: TimeInterval = 300.0
    private(set) var isSuspended = false

    // 原廠韌體 UUID 定義
    private let serviceUUID = CBUUID(string: "EBE0CCB0-7A0A-4B0C-8A1A-6FF2997DA3A6")
    private let charUUID = CBUUID(string: "EBE0CCC1-7A0A-4B0C-8A1A-6FF2997DA3A6")
    private let broadcastMinInterval: TimeInterval = 10  // 開源廣播每台裝置最短的介面更新間隔

    private struct Runtime { var due: Date; var failures = 0; var lastSuccess: Date? }
    private struct BroadcastState { var lastSeen: Date; var lastEmit = Date.distantPast; var staleReported = false }
    private enum Phase { case locating, connecting, connected }
    private struct Attempt { let id: String; let token: Int; var phase: Phase; let timer: Timer }
    private enum Outcome { case success(SensorReading), failure(String, timeout: Bool), cancelled }
    private enum ScanReason { case discovery, rediscover }
    private struct Discovery {
        var found: [String: DiscoveredDevice] = [:]
        let deadline: Date
        let timer: Timer
        let onUpdate: ([DiscoveredDevice]) -> Void
        let onFinish: ([DiscoveredDevice]) -> Void
    }

    private var devices: [String: DeviceRecord] = [:]
    private var order: [String] = []                  // 原廠裝置的輪詢順序 (主裝置在最前面)
    private var runtimes: [String: Runtime] = [:]
    private var broadcasts: [String: BroadcastState] = [:]
    private var peripherals: [UUID: CBPeripheral] = [:]  // 強參照：CoreBluetooth 會取消沒人持有的連線
    private var attempt: Attempt?
    private var attemptCounter = 0
    private var oneShotIDs = Set<String>()            // 離家停機時手動要求的單次讀取
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
        devices = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
        order = primaryFirst.filter { devices[$0]?.kind == .stock }
        runtimes = Dictionary(uniqueKeysWithValues: order.map { ($0, runtimes[$0] ?? Runtime(due: now)) })
        broadcasts = Dictionary(uniqueKeysWithValues: records.filter { $0.kind == .broadcast }.map {
            ($0.id, broadcasts[$0.id] ?? BroadcastState(lastSeen: now))  // 新加入的廣播裝置給緩衝時間
        })
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
            runtimes[id]?.due = now
            runtimes[id]?.failures = 0
        }
        if isSuspended {
            oneShotIDs.formUnion(targets)
            mijiaLog("離家停機中，手動要求只讀取一次 (不解除停機)")
        } else {
            mijiaLog("手動要求立即重新整理 [\(deviceID ?? "全部")]...")
        }
        scheduleTick(after: 0)
    }

    /// 離開居家大範圍時全面停止輪詢與廣播掃描 (0 耗電)；使用者主動的搜尋與單次讀取仍可進行
    func suspend(reason: String = "已離開居家大範圍") {
        guard !isSuspended else { return }
        isSuspended = true
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
        delegate?.didUpdateAdapterStatus("已進入居家範圍，連線中...", available: true)
        updateScanning()
        scheduleTick(after: 0)
    }

    // MARK: - 搜尋新裝置

    func startDiscovery(duration: TimeInterval = 20, onUpdate: @escaping ([DiscoveredDevice]) -> Void,
                        onFinish: @escaping ([DiscoveredDevice]) -> Void) {
        guard discovery == nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.discoveryTick() }
        RunLoop.main.add(timer, forMode: .common)
        discovery = Discovery(deadline: Date().addingTimeInterval(duration), timer: timer, onUpdate: onUpdate, onFinish: onFinish)
        scanReasons.insert(.discovery)
        updateScanning()
        mijiaLog("開始搜尋新裝置...")
    }

    /// 取消搜尋 (不回呼結果)
    func stopDiscovery() {
        finishDiscovery(notify: false)
    }

    private func discoveryTick() {
        guard let d = discovery else { return }
        if Date() >= d.deadline {
            finishDiscovery(notify: true)
        } else {
            d.onUpdate(Array(d.found.values))
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
        let due = runtimes.filter { eligible.contains($0.key) }.mapValues(\.due)
        let next = Backoff.pickNextDue(due: due, order: eligible, now: Date())
        if let id = next.id {
            beginAttempt(id)
        } else {
            scheduleTick(after: next.wait)
        }
    }

    private func beginAttempt(_ id: String) {
        guard let uuid = UUID(uuidString: id) else {
            runtimes[id]?.due = .distantFuture
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
        a.timer.invalidate()
        attempt = nil
        if let uuid = UUID(uuidString: id), let p = peripherals[uuid], p.state != .disconnected {
            centralManager.cancelPeripheralConnection(p)
        }
        if scanReasons.remove(.rediscover) != nil { updateScanning() }

        switch outcome {
        case .success(let reading): recordSuccess(id, reading)
        case .failure(let message, let timeout): recordFailure(id, message, timeout: timeout)
        case .cancelled: break
        }
        scheduleTick(after: 0)
    }

    private func recordSuccess(_ id: String, _ reading: SensorReading) {
        guard var rt = runtimes[id] else { return }  // 讀取期間被移除的裝置：結果丟棄
        let now = Date()
        rt.failures = 0
        rt.lastSuccess = now
        rt.due = now.addingTimeInterval(refreshInterval)
        runtimes[id] = rt
        delegate?.didUpdateReading(reading, deviceID: id)
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        delegate?.didUpdateDeviceStatus("省電休眠中 (下次更新 \(formatter.string(from: rt.due)))", deviceID: id, reachable: true)
    }

    private func recordFailure(_ id: String, _ message: String, timeout: Bool) {
        guard var rt = runtimes[id] else { return }
        rt.failures += 1
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
            if !isSuspended { delegate?.didUpdateAdapterStatus("藍牙已就緒", available: true) }
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
        let name = peripheral.name ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? ""
        let raw = advertisementData[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data] ?? [:]
        let serviceData = Dictionary(uniqueKeysWithValues: raw.map { ($0.key.uuidString.uppercased(), $0.value) })

        if discovery != nil, let c = DeviceDiscovery.candidate(id: id, name: name, rssi: RSSI.intValue, serviceData: serviceData) {
            discovery?.found[c.id] = DeviceDiscovery.merge(discovery?.found[c.id], c)
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
        guard var a = attempt, a.id == peripheral.identifier.uuidString else { return }
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
        if let a = attempt, a.id == id, a.phase == .connected {
            // 讀到數據前就斷線：算一次失敗並排定重試 (舊版在這裡會停止輪詢)
            finishAttempt(id, token: a.token, outcome: .failure("非預期連線中斷: \(error?.localizedDescription ?? "正常斷線")", timeout: false))
        } else if attempt?.id != id {
            mijiaLog("設備已成功進入省電休眠 [\(id)]。")
        }
    }
}

// MARK: - CBPeripheralDelegate (原廠韌體 GATT 解析)
extension BluetoothManager: CBPeripheralDelegate {
    private func failCurrent(_ peripheral: CBPeripheral, _ message: String) {
        guard let a = attempt, a.id == peripheral.identifier.uuidString else { return }
        finishAttempt(a.id, token: a.token, outcome: .failure(message, timeout: false))
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let service = peripheral.services?.first(where: { $0.uuid == serviceUUID }) else {
            failCurrent(peripheral, "找不到溫濕度服務: \(error?.localizedDescription ?? "無此服務")")
            return
        }
        peripheral.discoverCharacteristics([charUUID], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let char = service.characteristics?.first(where: { $0.uuid == charUUID }) else {
            failCurrent(peripheral, "找不到溫濕度特徵值: \(error?.localizedDescription ?? "無此特徵值")")
            return
        }
        mijiaLog("找到 Characteristic: \(char.uuid)，單次讀取溫濕度數據 (不開 Notify 以杜絕頻繁喚醒)...")
        // 注意：絕對不要呼叫 setNotifyValue(true)，否則硬體會每 6 秒主動發射一次射頻，導致嚴重耗電！
        peripheral.readValue(for: char)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == charUUID, let a = attempt, a.id == peripheral.identifier.uuidString else { return }
        guard error == nil, let data = characteristic.value, let m = AdvertisementParser.parseStockGATT(data) else {
            failCurrent(peripheral, "讀取失敗: \(error?.localizedDescription ?? "數據長度不足")")
            return
        }
        mijiaLog("收到原廠數據: 溫度=\(m.temperature)°C, 濕度=\(m.humidity)%, 電壓=\(m.voltage)V, 電量=\(m.batteryPercent)% [\(a.id)]")

        // ★★★ 極致省電核心機制 ★★★
        // 讀取完畢後，立刻主動斷開 BLE GATT 連線 (finishAttempt 內)，
        // 讓硬體 TLSR8251 晶片立刻進入 Deep Sleep 休眠模式，耗電瞬間從 150µA 降至 15µA！
        mijiaLog("數據讀取完成，立刻主動斷開連線以讓硬體休眠省電 (下次連線間隔: \(Int(refreshInterval)) 秒)...")
        let reading = SensorReading(m, name: devices[a.id]?.name ?? (peripheral.name ?? a.id), rssi: nil, isBroadcast: false)
        finishAttempt(a.id, token: a.token, outcome: .success(reading))
    }
}
