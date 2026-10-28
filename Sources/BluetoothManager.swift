import Foundation
import CoreBluetooth

struct SensorReading {
    var temperature: Double   // 攝氏度 (°C)
    var humidity: Double      // 相對濕度 (%)
    var batteryPercent: Int   // 電量百分比 (0-100%)
    var voltage: Double       // 電池電壓 (V)
    var rssi: Int?            // 訊號強度 (dBm)
    var deviceName: String    // 設備名稱
    var lastUpdated: Date     // 最後更新時間
    var mode: String          // 原廠模式 / 開源廣播模式
}

protocol BluetoothManagerDelegate: AnyObject {
    func didUpdateStatus(_ status: String)
    func didUpdateReading(_ reading: SensorReading)
    func didFailWithError(_ error: String)
}

final class BluetoothManager: NSObject {
    weak var delegate: BluetoothManagerDelegate?

    private var centralManager: CBCentralManager!
    private var targetPeripheral: CBPeripheral?
    private var targetCharacteristic: CBCharacteristic?
    private var refreshTimer: Timer?
    private var connectTimeoutTimer: Timer?
    private var isSleepingBetweenPolls: Bool = false
    private var nextUpdateTime: Date?
    private var consecutiveFailures: Int = 0

    // 使用者自訂連線更新間隔 (秒)，預設 300 秒 (5 分鐘)
    private(set) var refreshInterval: TimeInterval = 300.0

    // 原廠韌體 UUID 定義
    private let serviceUUID = CBUUID(string: "EBE0CCB0-7A0A-4B0C-8A1A-6FF2997DA3A6")
    private let charUUID = CBUUID(string: "EBE0CCC1-7A0A-4B0C-8A1A-6FF2997DA3A6")

    // 開源韌體常見 Service Data UUID
    private let environmentalSensingUUID = CBUUID(string: "181A")
    private let btHomeUUID = CBUUID(string: "FCD2")

    private(set) var currentReading: SensorReading?
    private(set) var isScanning: Bool = false

    override init() {
        super.init()
        
        // 讀取偏好設定中的更新間隔
        if let savedInterval = UserDefaults.standard.object(forKey: "RefreshIntervalSeconds") as? Double, savedInterval >= 10.0 {
            refreshInterval = savedInterval
        } else {
            refreshInterval = 300.0
            UserDefaults.standard.set(300.0, forKey: "RefreshIntervalSeconds")
        }

        mijiaLog("BluetoothManager 初始化 (省電輪詢模式，設定間隔: \(Int(refreshInterval)) 秒)...")
        centralManager = CBCentralManager(delegate: self, queue: .main)
    }

    func setRefreshInterval(_ seconds: TimeInterval) {
        refreshInterval = seconds
        UserDefaults.standard.set(seconds, forKey: "RefreshIntervalSeconds")
        mijiaLog("連線間隔已調整為: \(Int(seconds)) 秒")
        planNextPoll()
    }

    private func planNextPoll(isRetry: Bool = false) {
        refreshTimer?.invalidate()

        let interval: TimeInterval
        if isRetry {
            consecutiveFailures += 1
            if consecutiveFailures <= 2 {
                // 第 1~2 次失敗 (離座 1~2 分鐘)：60 秒快速重試，方便快速恢復
                interval = min(refreshInterval, 60.0)
            } else if consecutiveFailures <= 4 {
                // 第 3~4 次失敗 (離座 2~10 分鐘)：退避至 300 秒 (5 分鐘)
                interval = max(refreshInterval, 300.0)
            } else {
                // 第 5 次以上 (確定長時間出門/不在家)：深度休眠 900 秒 (15 分鐘)，徹底杜絕藍牙空轉耗電！
                interval = max(refreshInterval, 900.0)
            }
        } else {
            consecutiveFailures = 0
            interval = refreshInterval
        }

        nextUpdateTime = Date().addingTimeInterval(interval)
        refreshTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            if isRetry {
                mijiaLog("離線指數退避探測 (連續失敗 \(self.consecutiveFailures) 次，間隔 \(Int(interval)) 秒)：嘗試尋找設備...")
            } else {
                mijiaLog("省電定時喚醒：準備發起下一次輪詢連線...")
            }
            self.connectAndFetch()
        }
    }

    func connectAndFetch() {
        guard centralManager.state == .poweredOn else { return }

        // 若已有目標周邊參照，直接發起連線（最省電、最快速）
        if let p = targetPeripheral {
            mijiaLog("正在快速連線至設備 \(p.name ?? p.identifier.uuidString)...")
            delegate?.didUpdateStatus("更新數據連線中...")
            isSleepingBetweenPolls = false

            // 連線超時保護：一般狀態給予 20 秒，長時間離線時縮短至 8 秒以節省電力
            let timeoutSec: TimeInterval = (consecutiveFailures >= 3) ? 8.0 : 20.0
            connectTimeoutTimer?.invalidate()
            connectTimeoutTimer = Timer.scheduledTimer(withTimeInterval: timeoutSec, repeats: false) { [weak self] _ in
                guard let self = self else { return }
                mijiaLog("連線超時 (設備未在連線範圍內)，取消並排定指數退避重試...")
                self.centralManager.cancelPeripheralConnection(p)
                self.delegate?.didUpdateStatus("設備未在連線範圍內")
                self.planNextPoll(isRetry: true)
            }

            centralManager.connect(p, options: nil)
            return
        }

        // 若無周邊參照，嘗試從 UserDefaults 讀取已存 UUID
        if let savedUUIDStr = UserDefaults.standard.string(forKey: "TargetPeripheralUUID"),
           let uuid = UUID(uuidString: savedUUIDStr) {
            let known = centralManager.retrievePeripherals(withIdentifiers: [uuid])
            if let p = known.first {
                mijiaLog("從已存 UUID (\(uuid.uuidString)) 快速恢復周邊參照...")
                targetPeripheral = p
                targetPeripheral?.delegate = self
                connectAndFetch()
                return
            }
        }

        // 若尚未發現過設備，啟動掃描
        startScan()
    }

    func startScan() {
        guard centralManager.state == .poweredOn else {
            let s = "等待藍牙開啟 (目前狀態: \(centralManager.state.rawValue))..."
            mijiaLog(s)
            delegate?.didUpdateStatus(s)
            return
        }

        isScanning = true
        mijiaLog("開始掃描周圍藍牙設備...")
        delegate?.didUpdateStatus("搜尋溫濕度計中...")
        centralManager.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
    }

    func stopScan() {
        centralManager.stopScan()
        isScanning = false
        mijiaLog("停止掃描。")
    }

    func restart() {
        mijiaLog("手動重啟掃描...")
        refreshTimer?.invalidate()
        connectTimeoutTimer?.invalidate()
        isSleepingBetweenPolls = false
        if let p = targetPeripheral {
            centralManager.cancelPeripheralConnection(p)
        }
        startScan()
    }

    func manualRefresh() {
        mijiaLog("手動要求立即重新整理 (重置離線退避計數器)...")
        consecutiveFailures = 0
        connectAndFetch()
    }

    private func saveStatusJSON(status: String) {
        var dict: [String: Any] = [
            "status": status,
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "refreshIntervalSeconds": Int(refreshInterval)
        ]
        if let r = currentReading {
            dict["temperature"] = r.temperature
            dict["humidity"] = r.humidity
            dict["batteryPercent"] = r.batteryPercent
            dict["voltage"] = r.voltage
            dict["deviceName"] = r.deviceName
            dict["mode"] = r.mode
        }
        if let data = try? JSONSerialization.data(withJSONObject: dict, options: .prettyPrinted) {
            try? data.write(to: URL(fileURLWithPath: "/tmp/mijia_status.json"))
        }
    }
}

// MARK: - CBCentralManagerDelegate
extension BluetoothManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        mijiaLog("CBCentralManager 狀態更新: \(central.state.rawValue)")
        switch central.state {
        case .poweredOn:
            connectAndFetch()
        case .poweredOff:
            mijiaLog("錯誤: 電腦藍牙已關閉")
            delegate?.didUpdateStatus("電腦藍牙已關閉")
            delegate?.didFailWithError("請在 Mac 控制中心開啟藍牙")
            saveStatusJSON(status: "電腦藍牙已關閉")
        case .unauthorized:
            mijiaLog("錯誤: 藍牙存取未授權")
            delegate?.didUpdateStatus("藍牙未授權")
            delegate?.didFailWithError("請在 系統設定 > 隱私權與安全性 > 藍牙 允許存取")
            saveStatusJSON(status: "藍牙未授權")
        case .unsupported:
            mijiaLog("錯誤: 硬體不支援藍牙")
            delegate?.didUpdateStatus("硬體不支援藍牙")
            saveStatusJSON(status: "硬體不支援藍牙")
        default:
            delegate?.didUpdateStatus("藍牙初始化中...")
            saveStatusJSON(status: "藍牙初始化中...")
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = peripheral.name ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? ""

        // 情況 A：開源韌體廣播
        if let serviceData = advertisementData[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data] {
            if let data = serviceData[environmentalSensingUUID] {
                if parseATCServiceData(data, name: name.isEmpty ? "ATC 溫濕度計" : name, rssi: RSSI.intValue) {
                    return
                }
            } else if let data = serviceData[btHomeUUID] {
                if parseBTHomeData(data, name: name.isEmpty ? "BTHome 溫濕度計" : name, rssi: RSSI.intValue) {
                    return
                }
            }
        }

        // 情況 B：原廠韌體設備
        if name.contains("LYWSD03MMC") || name.hasPrefix("MJ_HT_") {
            mijiaLog("發現目標原廠設備: \(name) [\(peripheral.identifier.uuidString)]，記住並連線...")
            UserDefaults.standard.set(peripheral.identifier.uuidString, forKey: "TargetPeripheralUUID")
            targetPeripheral = peripheral
            targetPeripheral?.delegate = self
            stopScan()
            connectAndFetch()
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        mijiaLog("已連線至 \(peripheral.name ?? "設備")，正在探索溫濕度服務...")
        delegate?.didUpdateStatus("讀取感測數據中...")
        peripheral.discoverServices([serviceUUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        connectTimeoutTimer?.invalidate()
        connectTimeoutTimer = nil
        mijiaLog("連線失敗: \(error?.localizedDescription ?? "未知原因")")
        delegate?.didUpdateStatus("連線失敗，等待下次輪詢")
        planNextPoll(isRetry: true)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        connectTimeoutTimer?.invalidate()
        connectTimeoutTimer = nil

        if isSleepingBetweenPolls {
            mijiaLog("設備已成功進入省電休眠。")
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm"
            let nextStr = nextUpdateTime != nil ? formatter.string(from: nextUpdateTime!) : "--:--"
            delegate?.didUpdateStatus("省電休眠中 (下次更新 \(nextStr))")
            return
        }

        mijiaLog("非預期連線中斷: \(error?.localizedDescription ?? "正常斷線")")
        delegate?.didUpdateStatus("設備未在連線範圍內")
    }
}

// MARK: - CBPeripheralDelegate (原廠韌體 GATT 解析)
extension BluetoothManager: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let services = peripheral.services else { return }
        for service in services where service.uuid == serviceUUID {
            mijiaLog("找到溫濕度服務: \(service.uuid)，開始搜尋 Characteristic...")
            peripheral.discoverCharacteristics([charUUID], for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let characteristics = service.characteristics else { return }
        for char in characteristics where char.uuid == charUUID {
            mijiaLog("找到 Characteristic: \(char.uuid)，單次讀取溫濕度數據 (不開 Notify 以杜絕頻繁喚醒)...")
            targetCharacteristic = char
            // 注意：絕對不要呼叫 setNotifyValue(true)，否則硬體會每 6 秒主動發射一次射頻，導致嚴重耗電！
            peripheral.readValue(for: char)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == charUUID, let data = characteristic.value, data.count >= 5 else { return }
        connectTimeoutTimer?.invalidate()
        connectTimeoutTimer = nil

        let tempRaw = Int16(data[0]) | (Int16(data[1]) << 8)
        let temp = Double(tempRaw) / 100.0

        let hum = Double(data[2])

        let voltRaw = UInt16(data[3]) | (UInt16(data[4]) << 8)
        let volt = Double(voltRaw) / 1000.0

        let batteryPct = min(100, max(0, Int(((volt - 2.1) / (3.0 - 2.1)) * 100.0)))

        mijiaLog("收到原廠數據: 溫度=\(temp)°C, 濕度=\(hum)%, 電壓=\(volt)V, 電量=\(batteryPct)%")

        let reading = SensorReading(
            temperature: temp,
            humidity: hum,
            batteryPercent: batteryPct,
            voltage: volt,
            rssi: nil,
            deviceName: peripheral.name ?? "米家溫濕度計 2",
            lastUpdated: Date(),
            mode: "原廠直連 (即連即斷省電模式)"
        )

        currentReading = reading
        delegate?.didUpdateReading(reading)
        saveStatusJSON(status: "已連線運作中")

        // ★★★ 極致省電核心機制 ★★★
        // 讀取完畢後，立刻主動斷開 BLE GATT 連線！
        // 讓硬體 TLSR8251 晶片立刻進入 Deep Sleep 休眠模式，耗電瞬間從 150µA 降至 15µA！
        // 鈕扣電池 CR2032 負載消失，電壓會逐漸回彈，不再發生劇烈掉電！
        isSleepingBetweenPolls = true
        mijiaLog("數據讀取完成，立刻主動斷開連線以讓硬體休眠省電 (下次連線間隔: \(Int(refreshInterval)) 秒)...")
        centralManager.cancelPeripheralConnection(peripheral)
        planNextPoll()
    }
}

// MARK: - 開源廣播解析
private extension BluetoothManager {
    func parseATCServiceData(_ data: Data, name: String, rssi: Int) -> Bool {
        if data.count >= 10 {
            let tempRaw = (Int16(data[6]) << 8) | Int16(data[7])
            let temp = Double(tempRaw) / 10.0
            let hum = Double(data[8])
            let bat = Int(data[9])
            var volt = 3.0
            if data.count >= 12 {
                let voltRaw = (UInt16(data[10]) << 8) | UInt16(data[11])
                volt = Double(voltRaw) / 1000.0
            }

            if temp >= -30.0 && temp <= 70.0 && hum >= 0 && hum <= 100 {
                let reading = SensorReading(
                    temperature: temp,
                    humidity: hum,
                    batteryPercent: bat,
                    voltage: volt,
                    rssi: rssi,
                    deviceName: name,
                    lastUpdated: Date(),
                    mode: "開源 ATC 廣播"
                )
                currentReading = reading
                delegate?.didUpdateReading(reading)
                saveStatusJSON(status: "廣播接收中")
                return true
            }
        }

        if data.count >= 13 {
            let tempRaw = Int16(data[6]) | (Int16(data[7]) << 8)
            let temp = Double(tempRaw) / 100.0
            let humRaw = UInt16(data[8]) | (UInt16(data[9]) << 8)
            let hum = Double(humRaw) / 100.0
            let voltRaw = UInt16(data[10]) | (UInt16(data[11]) << 8)
            let volt = Double(voltRaw) / 1000.0
            let bat = Int(data[12])

            if temp >= -30.0 && temp <= 70.0 && hum >= 0 && hum <= 100 {
                let reading = SensorReading(
                    temperature: temp,
                    humidity: hum,
                    batteryPercent: bat,
                    voltage: volt,
                    rssi: rssi,
                    deviceName: name,
                    lastUpdated: Date(),
                    mode: "開源 pvvx 廣播"
                )
                currentReading = reading
                delegate?.didUpdateReading(reading)
                saveStatusJSON(status: "廣播接收中")
                return true
            }
        }

        return false
    }

    func parseBTHomeData(_ data: Data, name: String, rssi: Int) -> Bool {
        guard data.count >= 5 else { return false }
        var index = 1
        var temp: Double?
        var hum: Double?
        var bat: Int?

        while index < data.count {
            let objectId = data[index]
            index += 1
            if objectId == 0x01 && index < data.count {
                bat = Int(data[index])
                index += 1
            } else if objectId == 0x02 && index + 1 < data.count {
                let val = Int16(data[index]) | (Int16(data[index+1]) << 8)
                temp = Double(val) * 0.01
                index += 2
            } else if objectId == 0x03 && index + 1 < data.count {
                let val = UInt16(data[index]) | (UInt16(data[index+1]) << 8)
                hum = Double(val) * 0.01
                index += 2
            } else {
                index += 1
            }
        }

        if let t = temp, let h = hum {
            let reading = SensorReading(
                temperature: t,
                humidity: h,
                batteryPercent: bat ?? 100,
                voltage: 3.0,
                rssi: rssi,
                deviceName: name,
                lastUpdated: Date(),
                mode: "BTHome 廣播"
            )
            currentReading = reading
            delegate?.didUpdateReading(reading)
            saveStatusJSON(status: "廣播接收中")
            return true
        }

        return false
    }
}
