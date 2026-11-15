import Foundation

/// 狀態 JSON (給外部腳本讀取)：頂層欄位維持舊格式，代表狀態列目前顯示的那台
/// (平常是主裝置；主裝置不在附近時是附近那台)，另加每台裝置的 devices 陣列
enum StatusFile {
    static func payload(devices: [DeviceRecord], states: [String: DeviceState], primaryID: String?, displayedID: String?,
                        interval: TimeInterval, adapterStatus: String?, now: Date = Date()) -> [String: Any] {
        let shown = devices.first { $0.id == (displayedID ?? primaryID) }
        let shownState = shown.map { states[$0.id] ?? DeviceState() }
        let iso = ISO8601DateFormatter()

        var dict: [String: Any] = [
            "status": adapterStatus ?? shownState?.status ?? "尚未加入裝置",
            "timestamp": iso.string(from: now),
            "refreshIntervalSeconds": Int(interval)
        ]
        if let d = shown, let r = shownState?.reading {
            dict["temperature"] = r.temperature
            dict["humidity"] = r.humidity
            dict["batteryPercent"] = r.batteryPercent
            dict["voltage"] = r.voltage
            dict["deviceName"] = d.name
            dict["mode"] = r.mode
        }
        dict["primaryDeviceId"] = primaryID ?? NSNull()
        dict["displayedDeviceId"] = shown?.id ?? NSNull()
        dict["devices"] = devices.map { entry($0, states[$0.id] ?? DeviceState(), primary: $0.id == primaryID, iso: iso) }
        return dict
    }

    private static func entry(_ d: DeviceRecord, _ s: DeviceState, primary: Bool, iso: ISO8601DateFormatter) -> [String: Any] {
        var e: [String: Any] = [
            "id": d.id, "name": d.name, "kind": d.kind.rawValue, "primary": primary,
            "reachable": s.reachable.map { $0 as Any } ?? NSNull(), "status": s.status
        ]
        if let r = s.reading {
            e["temperature"] = r.temperature
            e["humidity"] = r.humidity
            e["batteryPercent"] = r.batteryPercent
            e["voltage"] = r.voltage
            e["mode"] = r.mode
            e["lastUpdated"] = iso.string(from: r.lastUpdated)
        }
        return e
    }

    static func write(_ dict: [String: Any], to url: URL = AppPaths.statusJSON) {
        if let data = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: url, options: .atomic)
        }
    }
}
