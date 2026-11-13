import Foundation

/// 舊版單一裝置設定 → 多裝置清單的遷移。
/// 原則：只新增資料，絕不覆寫或刪除舊檔與舊設定鍵 (TargetPeripheralUUID、history.json)，裝回舊版仍可照常使用。
enum Migration {
    struct Plan: Equatable {
        let devices: [DeviceRecord]
        let primaryID: String?
        let copyHistoryTo: String?   // 舊 history.json 要複製給哪一台
        let legacyUnclaimed: Bool    // 有舊歷史但沒有舊目標 (開源廣播用戶)
    }

    /// 已經遷移過 (設定中已有 Devices 鍵，即使是空清單) 時回傳 nil
    static func plan(devicesKeyPresent: Bool, legacyTarget: Any?, legacyHistoryExists: Bool) -> Plan? {
        guard !devicesKeyPresent else { return nil }
        guard let raw = legacyTarget as? String, let uuid = UUID(uuidString: raw.trimmingCharacters(in: .whitespaces)) else {
            return Plan(devices: [], primaryID: nil, copyHistoryTo: nil, legacyUnclaimed: legacyHistoryExists)
        }
        let id = uuid.uuidString
        let device = DeviceRecord(id: id, name: "\(DeviceList.defaultPrefix) 1", kind: .stock)
        return Plan(devices: [device], primaryID: id, copyHistoryTo: legacyHistoryExists ? id : nil, legacyUnclaimed: false)
    }

    /// 執行遷移；回傳是否執行了遷移。複製歷史失敗時丟出錯誤且不寫入 Devices，下次啟動會再試
    @discardableResult
    static func run(store: KeyValueStore, deviceStore: DeviceStore, logFile: URL) throws -> Bool {
        let legacy = deviceStore.legacyHistory
        let hasHistory = FileManager.default.fileExists(atPath: legacy.path)
        guard let plan = plan(devicesKeyPresent: store.object(forKey: DeviceKeys.devices) != nil,
                              legacyTarget: store.object(forKey: DeviceKeys.legacyTarget),
                              legacyHistoryExists: hasHistory) else { return false }

        if let target = plan.primaryID {
            let dest = deviceStore.historyURL(for: target)
            if let id = plan.copyHistoryTo, try FileOps.copyWithoutOverwrite(from: legacy, to: dest) {
                mijiaLog("遷移: 舊歷史已複製到 \(id)")
            }
            backfillIfEmpty(dest, logFile: logFile)
            migrateLowBatteryDate(store: store, deviceID: target)
        }
        if plan.legacyUnclaimed {
            store.set(true, forKey: DeviceKeys.legacyUnclaimed)
        }
        store.set(plan.primaryID, forKey: DeviceKeys.primary)
        // Devices 最後寫入，作為遷移完成的記號
        store.set(DeviceList.serialize(plan.devices), forKey: DeviceKeys.devices)
        deviceStore.reload()
        mijiaLog("遷移完成: \(plan.devices.count) 台裝置，主裝置 \(plan.primaryID ?? "無")")
        return true
    }

    private static func migrateLowBatteryDate(store: KeyValueStore, deviceID: String) {
        guard store.object(forKey: DeviceKeys.lowBatteryDates) == nil,
              let last = store.object(forKey: DeviceKeys.legacyLowBattery) as? Date else { return }
        store.set([deviceID: last], forKey: DeviceKeys.lowBatteryDates)
    }

    /// 舊版只有一台時，日誌裡的「收到原廠數據」都屬於它：新歷史檔不存在或為空時才從日誌回填
    private static func backfillIfEmpty(_ dest: URL, logFile: URL) {
        let existing = HistoryManager(storageURL: dest)
        guard existing.points.isEmpty,
              let text = try? String(contentsOf: logFile, encoding: .utf8) else { return }
        let points = parseLogPoints(text)
        guard !points.isEmpty else { return }
        existing.replaceAll(points)
        mijiaLog("遷移: 從日誌回填 \(points.count) 筆歷史採樣點")
    }

    /// 解析日誌中的原廠讀數行 (行尾可能帶裝置 id，舊格式沒有)
    static func parseLogPoints(_ text: String) -> [HistoryPoint] {
        let pattern = #"\[(.*?)\] 收到原廠數據: 溫度=(.*?)°C, 濕度=(.*?)%, 電壓=(.*?)V, 電量=(\d+)%"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let formatter = ISO8601DateFormatter()
        var points: [HistoryPoint] = []
        for line in text.components(separatedBy: .newlines) {
            let ns = line as NSString
            guard let m = regex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { continue }
            let g = (1...5).map { ns.substring(with: m.range(at: $0)) }
            if let date = formatter.date(from: g[0]), let t = Double(g[1]), let h = Double(g[2]),
               let v = Double(g[3]), let b = Int(g[4]) {
                points.append(HistoryPoint(timestamp: date, temperature: t, humidity: h, voltage: v, batteryPercent: b))
            }
        }
        return points
    }
}
