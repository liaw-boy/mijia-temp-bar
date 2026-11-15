import Foundation

/// 原廠 GATT 數據與開源韌體 (ATC / pvvx / BTHome) 廣播解析 (純函式，不依賴藍牙堆疊)
enum AdvertisementParser {
    static let modeStock = "原廠直連 (即連即斷省電模式)"
    static let modeATC = "開源 ATC 廣播"
    static let modePVVX = "開源 pvvx 廣播"
    static let modeBTHome = "BTHome 廣播"

    // 開源韌體常見 Service Data UUID (CBUUID.uuidString 的短格式)
    static let environmentalSensingKey = "181A"
    static let btHomeKey = "FCD2"

    /// CR2032 鈕扣電池：2.1V 視為 0%，3.0V 視為 100%
    static func batteryFromVoltage(_ volt: Double) -> Int {
        min(100, max(0, Int((volt - 2.1) / (3.0 - 2.1) * 100.0)))
    }

    static func isStockName(_ name: String) -> Bool {
        name.contains("LYWSD03MMC") || name.hasPrefix("MJ_HT_")
    }

    private static func isPlausible(_ temp: Double, _ hum: Double) -> Bool {
        (-30.0...70.0).contains(temp) && (0.0...100.0).contains(hum)
    }

    private static func int16LE(_ b: [UInt8], _ i: Int) -> Int16 { Int16(bitPattern: UInt16(b[i]) | (UInt16(b[i + 1]) << 8)) }
    private static func uint16LE(_ b: [UInt8], _ i: Int) -> UInt16 { UInt16(b[i]) | (UInt16(b[i + 1]) << 8) }
    private static func int16BE(_ b: [UInt8], _ i: Int) -> Int16 { Int16(bitPattern: (UInt16(b[i]) << 8) | UInt16(b[i + 1])) }
    private static func uint16BE(_ b: [UInt8], _ i: Int) -> UInt16 { (UInt16(b[i]) << 8) | UInt16(b[i + 1]) }

    /// 原廠韌體 Characteristic EBE0CCC1：int16 溫度 (0.01°C) + uint8 濕度 + uint16 電壓 (mV)，皆為 little-endian
    static func parseStockGATT(_ data: Data) -> Measurement? {
        let b = [UInt8](data)
        guard b.count >= 5 else { return nil }
        let temp = Double(int16LE(b, 0)) / 100.0
        let volt = Double(uint16LE(b, 3)) / 1000.0
        return Measurement(temperature: temp, humidity: Double(b[2]), batteryPercent: batteryFromVoltage(volt),
                           voltage: volt, mode: modeStock)
    }

    /// Service Data 0x181A：依長度優先嘗試對應格式 (pvvx 為 15 bytes、ATC1441 為 13 bytes)
    static func parseEnvironmental(_ data: Data) -> Measurement? {
        let b = [UInt8](data)
        return b.count >= 15 ? (parsePVVX(b) ?? parseATC1441(b)) : (parseATC1441(b) ?? parsePVVX(b))
    }

    /// ATC1441 格式 (big-endian)：MAC[6] 溫度 int16 (0.1°C) 濕度 uint8 電量 uint8 電壓 uint16 (mV) 計數
    private static func parseATC1441(_ b: [UInt8]) -> Measurement? {
        guard b.count >= 10 else { return nil }
        let temp = Double(int16BE(b, 6)) / 10.0
        let hum = Double(b[8])
        let volt = b.count >= 12 ? Double(uint16BE(b, 10)) / 1000.0 : 3.0
        guard isPlausible(temp, hum) else { return nil }
        return Measurement(temperature: temp, humidity: hum, batteryPercent: Int(b[9]), voltage: volt, mode: modeATC)
    }

    /// pvvx 自訂格式 (little-endian)：MAC[6] 溫度 int16 (0.01°C) 濕度 uint16 (0.01%) 電壓 uint16 (mV) 電量 uint8
    private static func parsePVVX(_ b: [UInt8]) -> Measurement? {
        guard b.count >= 13 else { return nil }
        let temp = Double(int16LE(b, 6)) / 100.0
        let hum = Double(uint16LE(b, 8)) / 100.0
        let volt = Double(uint16LE(b, 10)) / 1000.0
        guard isPlausible(temp, hum) else { return nil }
        return Measurement(temperature: temp, humidity: hum, batteryPercent: Int(b[12]), voltage: volt, mode: modePVVX)
    }

    // BTHome v2 物件 ID -> 資料長度；遇到未知物件無法得知長度，停止解析
    private static let btHomeSizes: [UInt8: Int] = [
        0x00: 1, 0x01: 1, 0x02: 2, 0x03: 2, 0x0C: 2, 0x0F: 1,
        0x10: 1, 0x11: 1, 0x2E: 1, 0x3A: 1, 0x45: 2
    ]

    /// Service Data 0xFCD2 (BTHome v2，僅支援未加密)
    static func parseBTHome(_ data: Data) -> Measurement? {
        let b = [UInt8](data)
        guard b.count >= 5, b[0] & 0x01 == 0 else { return nil }  // 加密封包需要 bindkey，不處理
        var temp: Double?, hum: Double?, bat: Int?, volt: Double?
        var index = 1
        while index < b.count {
            guard let size = btHomeSizes[b[index]], index + 1 + size <= b.count else { break }
            let v = index + 1
            switch b[index] {
            case 0x01: bat = Int(b[v])
            case 0x02: temp = Double(int16LE(b, v)) * 0.01
            case 0x45: temp = Double(int16LE(b, v)) * 0.1
            case 0x03: hum = Double(uint16LE(b, v)) * 0.01
            case 0x2E: hum = Double(b[v])
            case 0x0C: volt = Double(uint16LE(b, v)) * 0.001
            default: break
            }
            index += 1 + size
        }
        // 廣播資料來自附近裝置，不可信：超出合理範圍就丟棄
        guard let t = temp, let h = hum, (-40.0...85.0).contains(t), (0.0...100.0).contains(h) else { return nil }
        let voltage = volt.flatMap { (1.8...3.7).contains($0) ? $0 : nil } ?? 3.0
        return Measurement(temperature: (t * 100).rounded() / 100, humidity: (h * 100).rounded() / 100,
                           batteryPercent: min(100, max(0, bat ?? 100)), voltage: (voltage * 1000).rounded() / 1000,
                           mode: modeBTHome)
    }

    /// 依 Service Data 解析開源廣播；無法解析回傳 nil。key 為 CBUUID.uuidString (例如 "181A")
    static func broadcastMeasurement(_ serviceData: [String: Data]) -> Measurement? {
        if let data = serviceData[environmentalSensingKey] { return parseEnvironmental(data) }
        if let data = serviceData[btHomeKey] { return parseBTHome(data) }
        return nil
    }
}
