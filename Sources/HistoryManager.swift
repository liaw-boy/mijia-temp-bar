import Foundation

struct HistoryPoint: Codable, Equatable {
    let timestamp: Date
    let temperature: Double
    let humidity: Double
    let voltage: Double
    let batteryPercent: Int
}

/// 歷史採樣點 (每台裝置一個檔：Application Support/MijiaTempBar/history/<裝置>.json) 與 CSV 匯出
final class HistoryManager {
    /// 舊版單一裝置的歷史檔 (只讀取來遷移，不再寫入)
    static var legacyURL: URL { AppPaths.supportDir.appendingPathComponent("history.json") }
    static var historyDir: URL { AppPaths.supportDir.appendingPathComponent("history", isDirectory: true) }

    private static var instances: [URL: HistoryManager] = [:]

    /// 同一台裝置共用同一個實例 (儀表板與狀態列看到的是同一份資料)
    static func forDevice(_ id: String, in dir: URL = HistoryManager.historyDir) -> HistoryManager {
        let url = dir.appendingPathComponent("\(DeviceList.fileID(id)).json")
        if let existing = instances[url] { return existing }
        let manager = HistoryManager(storageURL: url)
        instances[url] = manager
        return manager
    }

    private(set) var points: [HistoryPoint] = []
    let storageURL: URL
    private var readOnly = false  // 讀不到或無法另存原檔時不寫入，避免蓋掉使用者的歷史
    /// 筆數保險上限：更新間隔最短 10 秒時，最近 30 天的完整資料約 26 萬筆，加上壓縮後的舊資料
    private let maxPoints = 300_000

    static let retentionKey = "HistoryRetentionDays"
    /// 歷史保存天數 (設定頁可選)；最近 30 天完整保留，更舊的每小時留一筆
    static var retentionDays: Int {
        get {
            let d = UserDefaults.standard.integer(forKey: retentionKey)
            return DeviceHistory.retentionOptions.contains(d) ? d : DeviceHistory.retentionOptions[0]
        }
        set { UserDefaults.standard.set(newValue, forKey: retentionKey) }
    }

    init(storageURL: URL) {
        self.storageURL = storageURL
        loadHistory()
    }

    var lastPoint: HistoryPoint? { points.last }

    func addPoint(temp: Double, hum: Double, volt: Double, battery: Int, at date: Date = Date()) {
        points.append(HistoryPoint(timestamp: date, temperature: temp, humidity: hum, voltage: volt, batteryPercent: battery))
        compactAndSave()
    }

    /// 遷移回填或用裝置歷史補空白後整批寫回
    func replaceAll(_ newPoints: [HistoryPoint]) {
        points = newPoints
        compactAndSave()
    }

    /// 依保存天數清掉過期資料、超過 30 天的合併成每小時一筆，再寫檔
    private func compactAndSave(now: Date = Date()) {
        points = DeviceHistory.compact(points, now: now, retentionDays: Self.retentionDays)
        if points.count > maxPoints {
            points.removeFirst(points.count - maxPoints)
        }
        saveHistory()
    }

    private func saveHistory() {
        guard !readOnly, let data = try? JSONEncoder().encode(points) else { return }
        try? FileManager.default.createDirectory(at: storageURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? data.write(to: storageURL, options: .atomic)
    }

    private func loadHistory() {
        guard FileManager.default.fileExists(atPath: storageURL.path) else { return }
        guard let data = try? Data(contentsOf: storageURL) else {
            readOnly = true
            mijiaLog("無法讀取歷史檔 \(storageURL.lastPathComponent)，本次不寫入")
            return
        }
        guard let loaded = try? JSONDecoder().decode([HistoryPoint].self, from: data) else {
            setAsideCorrupted()
            return
        }
        points = loaded
    }

    /// 損毀的檔案先另存一份，避免下次寫入時被默默覆蓋
    private func setAsideCorrupted() {
        let name = storageURL.deletingPathExtension().lastPathComponent
        let backup = storageURL.deletingLastPathComponent()
            .appendingPathComponent("\(name).corrupt-\(Int(Date().timeIntervalSince1970)).json")
        do {
            if try FileOps.copyWithoutOverwrite(from: storageURL, to: backup) {
                mijiaLog("歷史檔損毀，已另存為 \(backup.lastPathComponent)")
            } else {
                readOnly = true  // 同一秒的備份已存在，保守起見不覆蓋原檔
            }
        } catch {
            readOnly = true
            mijiaLog("歷史檔損毀且無法另存，本次不寫入: \(error.localizedDescription)")
        }
    }

    // MARK: - 統計指標
    private func todayPoints(now: Date) -> [HistoryPoint] {
        let start = Calendar.current.startOfDay(for: now)
        return points.filter { $0.timestamp >= start }
    }

    func todayTemperatureRange(now: Date = Date()) -> (min: Double, max: Double)? {
        let temps = todayPoints(now: now).map(\.temperature)
        guard let lo = temps.min(), let hi = temps.max() else { return nil }
        return (lo, hi)
    }

    var minTemperature: Double? { points.map { $0.temperature }.min() }
    var maxTemperature: Double? { points.map { $0.temperature }.max() }
    var minHumidity: Double? { points.map { $0.humidity }.min() }
    var maxHumidity: Double? { points.map { $0.humidity }.max() }
    var minVoltage: Double? { points.map { $0.voltage }.min() }
    var maxVoltage: Double? { points.map { $0.voltage }.max() }

    // MARK: - 匯出 CSV
    func exportCSV(to url: URL) throws {
        var csv = "時間,溫度 (°C),濕度 (%),電壓 (V),電量百分比 (%)\n"
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm:ss"

        for p in points {
            let row = "\(df.string(from: p.timestamp)),\(String(format: "%.2f", p.temperature)),\(String(format: "%.1f", p.humidity)),\(String(format: "%.3f", p.voltage)),\(p.batteryPercent)\n"
            csv.append(row)
        }
        try csv.write(to: url, atomically: true, encoding: .utf8)
    }
}
