import Foundation

/// 單次讀到的溫濕度數據
struct SensorReading {
    var temperature: Double   // 攝氏度 (°C)
    var humidity: Double      // 相對濕度 (%)
    var batteryPercent: Int   // 電量百分比 (0-100%)
    var voltage: Double       // 電池電壓 (V)
    var rssi: Int?            // 訊號強度 (dBm)
    var deviceName: String    // 設備名稱
    var lastUpdated: Date     // 最後更新時間
    var mode: String          // 原廠模式 / 開源廣播模式
    var isBroadcast: Bool = false
}

/// 解析後的感測數值 (不含裝置與時間資訊)
struct Measurement: Equatable {
    let temperature: Double
    let humidity: Double
    let batteryPercent: Int
    let voltage: Double
    let mode: String
}

extension SensorReading {
    init(_ m: Measurement, name: String, rssi: Int?, isBroadcast: Bool, at date: Date = Date()) {
        self.init(temperature: m.temperature, humidity: m.humidity, batteryPercent: m.batteryPercent,
                  voltage: m.voltage, rssi: rssi, deviceName: name, lastUpdated: date,
                  mode: m.mode, isBroadcast: isBroadcast)
    }
}

/// 每台裝置的即時狀態
struct DeviceState {
    static let statusOK = "正常運作中"
    static let statusWaiting = "等待讀取"

    var reading: SensorReading?
    var reachable: Bool?      // nil = 尚未確認 (例如啟動時使用歷史快取)
    var status: String = DeviceState.statusWaiting
    var cached: Bool = false  // 讀數來自上次的歷史紀錄

    func withReading(_ reading: SensorReading) -> DeviceState {
        DeviceState(reading: reading, reachable: true, status: DeviceState.statusOK, cached: false)
    }

    /// 更新狀態文字；reachable 為 nil 表示可連線與否沒有改變
    func withStatus(_ status: String, reachable: Bool?) -> DeviceState {
        DeviceState(reading: reading, reachable: reachable ?? self.reachable, status: status, cached: cached)
    }
}

/// 狀態列與選單的顯示規則 (純邏輯，可單元測試)
enum DisplayRules {
    /// 「僅連線時顯示」：只有全部裝置都確定連不到才隱藏；沒有任何裝置時不隱藏 (才能加入裝置)
    static func shouldHideIcon(hideEnabled: Bool, deviceIDs: [String], states: [String: DeviceState]) -> Bool {
        guard hideEnabled, !deviceIDs.isEmpty else { return false }
        return deviceIDs.allSatisfy { states[$0]?.reachable == false }
    }

    /// 狀態列要顯示哪一台 (帶筆電換地方時用)：主裝置可連線或尚未確認 → 主裝置；
    /// 主裝置連不到時，目前顯示的附近裝置 (current) 仍在附近就維持 (不會因為讀取順序在兩台間跳)，
    /// 否則換最近讀到的那台；不改使用者選的主裝置。都連不到 → 仍是主裝置
    static func displayDeviceID(primaryID: String?, orderedIDs: [String], states: [String: DeviceState],
                                current: String? = nil) -> String? {
        guard let primary = primaryID else { return nil }
        guard states[primary]?.reachable == false else { return primary }
        func isNearby(_ id: String) -> Bool { states[id]?.reachable == true && states[id]?.reading != nil }
        if let shown = current, shown != primary, orderedIDs.contains(shown), isNearby(shown) { return shown }
        let nearby = orderedIDs.filter { $0 != primary && isNearby($0) }
        return nearby.max { (states[$0]?.reading?.lastUpdated ?? .distantPast) < (states[$1]?.reading?.lastUpdated ?? .distantPast) } ?? primary
    }

    /// 主裝置要顯示在狀態列的 (溫度, 濕度)；連不到時為 nil，畫成 --
    static func trayValues(_ state: DeviceState?) -> (temperature: Double?, humidity: Double?) {
        guard let state = state, let r = state.reading, state.reachable != false else { return (nil, nil) }
        return (r.temperature, r.humidity)
    }

    static func formatTemp(_ value: Double?) -> String {
        value.map { String(format: "%.1f", $0) } ?? "--"
    }

    static func formatHum(_ value: Double?) -> String {
        value.map { String(format: "%.0f", $0) } ?? "--"
    }

    /// 選單中每台裝置的一行摘要
    static func summaryText(name: String, state: DeviceState) -> String {
        if state.reading == nil && state.reachable != false {
            return "\(name) · \(state.status)"
        }
        let values = trayValues(state)
        guard let t = values.temperature, let h = values.humidity else {
            return "\(name) · -- (\(state.status))"
        }
        return "\(name) · \(formatTemp(t))° · \(formatHum(h))%"
    }
}
