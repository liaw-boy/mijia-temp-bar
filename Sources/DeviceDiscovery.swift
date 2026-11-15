import Foundation

/// 搜尋新裝置時找到的候選溫濕度計
struct DiscoveredDevice: Equatable {
    let id: String
    let name: String           // 廣播中的名稱 (例如 LYWSD03MMC、ATC_8C9B32)
    let kind: DeviceKind
    let rssi: Int?
    let measurement: Measurement?  // 開源廣播型才有即時讀數
}

/// 搜尋候選的分類與合併 (純函式，與 Linux 版 discovery.py 相同規則)
enum DeviceDiscovery {
    /// 可解析的廣播優先判定為開源廣播型；否則依名稱判定原廠韌體；都不是回傳 nil
    static func candidate(id: String, name: String, rssi: Int?, serviceData: [String: Data]) -> DiscoveredDevice? {
        if let m = AdvertisementParser.broadcastMeasurement(serviceData) {
            let generic = serviceData[AdvertisementParser.environmentalSensingKey] != nil ? "ATC 溫濕度計" : "BTHome 溫濕度計"
            return DiscoveredDevice(id: DeviceList.normalizeID(id), name: name.isEmpty ? generic : name,
                                    kind: .broadcast, rssi: rssi, measurement: m)
        }
        if AdvertisementParser.isStockName(name) {
            return DiscoveredDevice(id: DeviceList.normalizeID(id), name: name, kind: .stock, rssi: rssi, measurement: nil)
        }
        return nil
    }

    /// 同一台多次出現時合併：保留最強訊號、最新名稱與讀數；看過廣播就算廣播型
    static func merge(_ old: DiscoveredDevice?, _ new: DiscoveredDevice) -> DiscoveredDevice {
        guard let old = old else { return new }
        let rssi = [old.rssi, new.rssi].compactMap { $0 }.max()
        let kind: DeviceKind = (old.kind == .broadcast || new.kind == .broadcast) ? .broadcast : .stock
        return DiscoveredDevice(id: new.id, name: new.name.isEmpty ? old.name : new.name, kind: kind,
                                rssi: rssi, measurement: new.measurement ?? old.measurement)
    }

    /// 排除已加入的裝置，依訊號強度由強到弱排序 (沒有訊號值的排最後)
    static func newCandidates(_ found: [DiscoveredDevice], existingIDs: Set<String>) -> [DiscoveredDevice] {
        found.filter { !existingIDs.contains($0.id) }.sorted { a, b in
            switch (a.rssi, b.rssi) {
            case let (x?, y?) where x != y: return x > y
            case (nil, _?): return false
            case (_?, nil): return true
            default: return (a.name, a.id) < (b.name, b.id)
            }
        }
    }

    static func label(_ c: DiscoveredDevice) -> String {
        var parts = [c.name, c.kind.title]
        if let rssi = c.rssi { parts.append("\(rssi) dBm") }
        if let m = c.measurement { parts.append(String(format: "%.1f°C %.0f%%", m.temperature, m.humidity)) }
        return parts.joined(separator: " · ")
    }
}
