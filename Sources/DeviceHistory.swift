import Foundation

/// 原廠韌體存在裝置上的每小時紀錄 (service EBE0CCB0，免認證)：
/// 讀 CCB7 裝置時間、CCB9 筆數，寫 CCBA 起始 index 後由 CCBC 逐筆 notify。
struct HourlyRecord: Equatable {
    let index: UInt32
    let deviceTime: UInt32   // 該小時開始時的裝置秒數，不是真實時間
    let maxTemperature: Double
    let maxHumidity: Double
    let minTemperature: Double
    let minHumidity: Double
}

enum DeviceHistory {
    /// 兩筆讀數相隔超過這麼久才算空白 (平常每次連線只讀當下數值，省電)
    static let gapThreshold: TimeInterval = 65 * 60
    /// 歷史保存天數的選項 (第一個為預設)；補空白的範圍也跟著這個天數
    static let retentionOptions = [30, 90, 180, 365]
    /// 最近這麼多天完整保留，更舊的每小時留一筆 (控制檔案大小與寫入量)
    static let detailDays = 30
    /// 一次連線最多讀幾筆 (30 天，實機約 2 分鐘)；更早的空白下次連線接著讀
    static let maxRecords: UInt32 = 720
    /// 開始讀之前 (查時間、筆數、訂閱) 的時間上限
    static let setupTimeout: TimeInterval = 20
    /// 讀取中超過這麼久沒收到下一筆就結束，保留已收到的部分
    static let idleTimeout: TimeInterval = 10
    /// 整次讀取歷史的上限
    static let totalTimeout: TimeInterval = 150

    /// 保存期間內第一個空白的起點 (空白前的最後一筆；最前面沒資料時是保存期間的起點)；沒有空白回傳 nil。
    /// coveredUntil：裝置歷史已讀到的時間，之前的空白裝置也沒有紀錄，不再重讀。
    /// 更新間隔很長時，正常輪詢的間隔本身不算空白 (否則每次輪詢都會讀歷史)；超過 30 天的資料每小時一筆，也不算空白。
    static func gapStart(points: [Date], now: Date, coveredUntil: Date?, interval: TimeInterval = 0,
                         retentionDays: Int = retentionOptions[0]) -> Date? {
        let detailStart = now.addingTimeInterval(-Double(detailDays) * 86400)
        var prev = max(now.addingTimeInterval(-Double(retentionDays) * 86400), coveredUntil ?? .distantPast)
        for t in points where t > prev {
            let threshold = t <= detailStart ? 2 * 3600 + 600 : max(gapThreshold, interval + 600)
            if t.timeIntervalSince(prev) > threshold { return prev }
            prev = t
        }
        let threshold = max(gapThreshold, interval + 600)
        return now.timeIntervalSince(prev) > threshold ? prev : nil
    }

    /// 這次連線讀到哪一筆為止 (一次最多 maxRecords 筆)
    static func chunkEnd(start: UInt32, total: UInt32) -> UInt32 {
        // total 來自裝置 (不可信)：先減再加，避免接近 UInt32 上限時溢位讓程式當掉 (start <= total - 1 由 startIndex 保證)
        start + min(maxRecords - 1, total - 1 - start)
    }

    /// 紀錄那一小時結束時的真實時間
    static func realEnd(_ r: HourlyRecord, deviceNow: UInt32, now: Date) -> Date {
        now.addingTimeInterval(-Double(deviceNow) + Double(r.deviceTime) + 3600)
    }

    /// 清掉超過保存天數的資料；超過 30 天的合併成每小時一筆 (放在該小時中間，數值取平均)。重複執行結果不變
    static func compact(_ points: [HistoryPoint], now: Date, retentionDays: Int) -> [HistoryPoint] {
        let cutoff = now.addingTimeInterval(-Double(retentionDays) * 86400)
        let detailStart = now.addingTimeInterval(-Double(detailDays) * 86400)
        var result: [HistoryPoint] = []
        var bucket: [HistoryPoint] = []
        var bucketHour = Int.min
        func flush() {
            guard !bucket.isEmpty else { return }
            let n = Double(bucket.count)
            result.append(HistoryPoint(
                timestamp: Date(timeIntervalSince1970: Double(bucketHour) * 3600 + 1800),
                temperature: (bucket.map(\.temperature).reduce(0, +) / n * 100).rounded() / 100,
                humidity: (bucket.map(\.humidity).reduce(0, +) / n * 10).rounded() / 10,
                voltage: (bucket.map(\.voltage).reduce(0, +) / n * 1000).rounded() / 1000,
                batteryPercent: Int((Double(bucket.map(\.batteryPercent).reduce(0, +)) / n).rounded())))
            bucket.removeAll()
        }
        for p in points.sorted(by: { $0.timestamp < $1.timestamp }) where p.timestamp >= cutoff {
            guard p.timestamp < detailStart else { result.append(p); continue }
            let hour = Int((p.timestamp.timeIntervalSince1970 / 3600).rounded(.down))
            if hour != bucketHour { flush(); bucketHour = hour }
            bucket.append(p)
        }
        flush()
        return result.sorted { $0.timestamp < $1.timestamp }
    }

    /// 先取出 index：數值不合理的紀錄也要知道是不是最後一筆，才不會等到逾時
    static func recordIndex(_ data: Data) -> UInt32? {
        let b = [UInt8](data)
        return b.count >= 4 ? uint32LE(b, 0) : nil
    }

    /// CCBC 的一筆：<IIhBhB = index, 裝置時間, 最高溫×10, 最高濕度, 最低溫×10, 最低濕度
    static func parseRecord(_ data: Data) -> HourlyRecord? {
        let b = [UInt8](data)
        guard b.count >= 14 else { return nil }
        let maxT = Double(Int16(bitPattern: UInt16(b[8]) | UInt16(b[9]) << 8)) / 10
        let minT = Double(Int16(bitPattern: UInt16(b[11]) | UInt16(b[12]) << 8)) / 10
        let rec = HourlyRecord(index: uint32LE(b, 0), deviceTime: uint32LE(b, 4),
                               maxTemperature: maxT, maxHumidity: Double(b[10]),
                               minTemperature: minT, minHumidity: Double(b[13]))
        // 不合理的數值 (損毀或格式不同) 整筆丟掉
        guard (-40...85).contains(rec.minTemperature), (-40...85).contains(rec.maxTemperature),
              rec.minTemperature <= rec.maxTemperature,
              rec.maxHumidity <= 100, rec.minHumidity <= rec.maxHumidity else { return nil }
        return rec
    }

    /// CCB7：裝置目前時間 (<I)
    static func parseDeviceTime(_ data: Data) -> UInt32? {
        let b = [UInt8](data)
        return b.count >= 4 ? uint32LE(b, 0) : nil
    }

    /// CCB9：(累計寫過幾筆, 目前還存著幾筆)
    static func parseCount(_ data: Data) -> (total: UInt32, stored: UInt32)? {
        let b = [UInt8](data)
        guard b.count >= 8 else { return nil }
        return (uint32LE(b, 0), uint32LE(b, 4))
    }

    /// 要從哪一筆開始讀 (空白起點，加一筆緩衝；裝置沒存那麼久就從最舊的開始)；沒有可讀的紀錄時回傳 nil
    static func startIndex(total: UInt32, stored: UInt32, since: Date, now: Date) -> UInt32? {
        let available = min(stored, total)
        guard available > 0 else { return nil }
        let hours = max(0, now.timeIntervalSince(since)) / 3600
        let wanted = UInt32(min(Double(available), hours.rounded(.up) + 1))
        return total - wanted
    }

    static func uint32Data(_ value: UInt32) -> Data {
        Data([UInt8(value & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 24 & 0xFF)])
    }

    /// 把每小時紀錄補進歷史的空白處：每筆放在該小時中間，溫濕度取最高最低的平均。
    /// 附近 30 分鐘內已有讀數就不補；紀錄沒有電量，用這次連線讀到的電壓與電量。
    static func fill(existing: [HistoryPoint], records: [HourlyRecord], deviceNow: UInt32, now: Date,
                     voltage: Double, battery: Int, maxAge: TimeInterval = 366 * 86400) -> [HistoryPoint] {
        var added: [HistoryPoint] = []
        let times = existing.map(\.timestamp)
        for r in records where r.deviceTime <= deviceNow {
            // 紀錄時間是該小時的開始 (實機確認：最後一筆約在 1~2 小時前)，換成真實時間後往後半小時
            let mid = now.addingTimeInterval(-Double(deviceNow - r.deviceTime) + 1800)
            guard mid <= now, now.timeIntervalSince(mid) <= maxAge,
                  !times.contains(where: { abs($0.timeIntervalSince(mid)) < 1800 }),
                  !added.contains(where: { abs($0.timestamp.timeIntervalSince(mid)) < 1800 }) else { continue }
            added.append(HistoryPoint(timestamp: mid,
                                      temperature: ((r.maxTemperature + r.minTemperature) / 2 * 100).rounded() / 100,
                                      humidity: ((r.maxHumidity + r.minHumidity) / 2 * 10).rounded() / 10,
                                      voltage: voltage, batteryPercent: battery))
        }
        guard !added.isEmpty else { return existing }
        return (existing + added).sorted { $0.timestamp < $1.timestamp }
    }

    private static func uint32LE(_ b: [UInt8], _ i: Int) -> UInt32 {
        UInt32(b[i]) | UInt32(b[i + 1]) << 8 | UInt32(b[i + 2]) << 16 | UInt32(b[i + 3]) << 24
    }
}
