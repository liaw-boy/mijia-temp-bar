import Foundation

struct HistoryPoint: Codable {
    let timestamp: Date
    let temperature: Double
    let humidity: Double
    let voltage: Double
    let batteryPercent: Int
}

final class HistoryManager {
    static let shared = HistoryManager()

    private(set) var points: [HistoryPoint] = []
    private let storageURL: URL
    private let maxPoints = 8640 // 最多保留 30 天 (5分鐘間隔 = 8640筆)

    private init() {
        let fileManager = FileManager.default
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("MijiaTempBar", isDirectory: true)
        try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true, attributes: nil)
        storageURL = dir.appendingPathComponent("history.json")

        loadHistory()
        if points.isEmpty {
            backfillFromLog()
        }
    }

    func addPoint(temp: Double, hum: Double, volt: Double, battery: Int) {
        let point = HistoryPoint(
            timestamp: Date(),
            temperature: temp,
            humidity: hum,
            voltage: volt,
            batteryPercent: battery
        )
        points.append(point)
        if points.count > maxPoints {
            points.removeFirst(points.count - maxPoints)
        }
        saveHistory()
    }

    private func saveHistory() {
        guard let data = try? JSONEncoder().encode(points) else { return }
        try? data.write(to: storageURL, options: .atomic)
    }

    private func loadHistory() {
        guard let data = try? Data(contentsOf: storageURL),
              let loaded = try? JSONDecoder().decode([HistoryPoint].self, from: data) else {
            return
        }
        points = loaded
    }

    /// 從已存在的本地日誌回填今日歷史記錄
    func backfillFromLog() {
        let logPath = AppPaths.logFile.path
        guard let content = try? String(contentsOfFile: logPath, encoding: .utf8) else { return }

        let lines = content.components(separatedBy: .newlines)
        let pattern = #"\[(.*?)\] 收到原廠數據: 溫度=(.*?)°C, 濕度=(.*?)%, 電壓=(.*?)V, 電量=(\d+)%"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
        let formatter = ISO8601DateFormatter()

        var backfilled: [HistoryPoint] = []
        for line in lines {
            let range = NSRange(location: 0, length: line.utf16.count)
            if let match = regex.firstMatch(in: line, options: [], range: range) {
                let dateStr = (line as NSString).substring(with: match.range(at: 1))
                let tempStr = (line as NSString).substring(with: match.range(at: 2))
                let humStr = (line as NSString).substring(with: match.range(at: 3))
                let voltStr = (line as NSString).substring(with: match.range(at: 4))
                let batStr = (line as NSString).substring(with: match.range(at: 5))

                if let date = formatter.date(from: dateStr),
                   let temp = Double(tempStr),
                   let hum = Double(humStr),
                   let volt = Double(voltStr),
                   let bat = Int(batStr) {
                    backfilled.append(HistoryPoint(timestamp: date, temperature: temp, humidity: hum, voltage: volt, batteryPercent: bat))
                }
            }
        }

        if !backfilled.isEmpty {
            points = backfilled
            saveHistory()
            mijiaLog("歷史管理器已從日誌成功載入 \(backfilled.count) 筆歷史採樣點！")
        }
    }

    // MARK: - 統計指標
    var minTemperature: Double? { points.map { $0.temperature }.min() }
    var maxTemperature: Double? { points.map { $0.temperature }.max() }
    var avgTemperature: Double? {
        guard !points.isEmpty else { return nil }
        return points.reduce(0.0) { $0 + $1.temperature } / Double(points.count)
    }

    var minHumidity: Double? { points.map { $0.humidity }.min() }
    var maxHumidity: Double? { points.map { $0.humidity }.max() }
    var avgHumidity: Double? {
        guard !points.isEmpty else { return nil }
        return points.reduce(0.0) { $0 + $1.humidity } / Double(points.count)
    }

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
