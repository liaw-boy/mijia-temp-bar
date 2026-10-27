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
    private var connectedPeripheral: CBPeripheral?
    private var targetCharacteristic: CBCharacteristic?
    private var refreshTimer: Timer?

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

        mijiaLog("BluetoothManager 初始化 (設定連線間隔: \(Int(refreshInterval)) 秒)...")
        centralManager = CBCentralManager(delegate: self, queue: .main)
    }

    func setRefreshInterval(_ seconds: TimeInterval) {
        refreshInterval = seconds
        UserDefaults.standard.set(seconds, forKey: "RefreshIntervalSeconds")
        mijiaLog("連線間隔已調整為: \(Int(seconds)) 秒")
        resetRefreshTimer()
    }

    private func resetRefreshTimer() {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.triggerIntervalRead()
        }
    }

    private func triggerIntervalRead() {
        if let p = connectedPeripheral, let c = targetCharacteristic {
            mijiaLog("定時主動讀取溫濕度數據 (間隔: \(Int(refreshInterval))s)...")
            p.readValue(for: c)
        } else {
            restart()
        }
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
        if let p = connectedPeripheral {
            centralManager.cancelPeripheralConnection(p)
            connectedPeripheral = nil
        }
        targetCharacteristic = nil
        refreshTimer?.invalidate()
        refreshTimer = nil
        startScan()
    }

    func manualRefresh() {
        if let p = connectedPeripheral, let c = targetCharacteristic {
            mijiaLog("手動讀取 characteristic...")
            p.readValue(for: c)
        } else {
            restart()
        }
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
            startScan()
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
            if connectedPeripheral == nil {
                mijiaLog("發現目標原廠設備: \(name) [\(peripheral.identifier.uuidString)]，嘗試連線...")
                delegate?.didUpdateStatus("已發現設備，連線中...")
                connectedPeripheral = peripheral
                connectedPeripheral?.delegate = self
                centralManager.connect(peripheral, options: nil)
            }
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        mijiaLog("已連線至 \(peripheral.name ?? "設備")，正在探索服務...")
        delegate?.didUpdateStatus("已連線，讀取服務中...")
        peripheral.discoverServices([serviceUUID])
        stopScan()
        resetRefreshTimer()
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        mijiaLog("連線失敗: \(error?.localizedDescription ?? "未知原因")，重新掃描...")
        delegate?.didUpdateStatus("連線失敗，重新搜尋中...")
        connectedPeripheral = nil
        startScan()
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        mijiaLog("與設備連線中斷: \(error?.localizedDescription ?? "正常斷線")，重新掃描...")
        delegate?.didUpdateStatus("連線中斷，重新連線中...")
        connectedPeripheral = nil
        targetCharacteristic = nil
        refreshTimer?.invalidate()
        refreshTimer = nil
        startScan()
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
            mijiaLog("找到 Characteristic: \(char.uuid)，設定 Notify 並讀取數值...")
            targetCharacteristic = char
            peripheral.setNotifyValue(true, for: char)
            peripheral.readValue(for: char)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == charUUID, let data = characteristic.value, data.count >= 5 else { return }

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
            mode: "原廠直連模式"
        )

        currentReading = reading
        delegate?.didUpdateReading(reading)
        saveStatusJSON(status: "已連線運作中")
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
