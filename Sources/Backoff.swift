import Foundation

/// 離線指數退避策略與輪詢排程判斷 (純函式，與 Linux 版 backoff.py / scheduler.py 相同)
enum Backoff {
    static let fastRetry: TimeInterval = 60    // 連線失敗後最快多久重試 (不超過使用者設定的間隔)
    static let maxWait: TimeInterval = 60      // 排程每次最多等 60 秒就重新檢查 (睡眠喚醒後能及時補讀)

    /// 1~2 次快速重試、3~4 次退到 5 分鐘、之後 15 分鐘 (皆不短於使用者間隔)
    static func retryDelay(failures: Int, interval: TimeInterval) -> TimeInterval {
        if failures <= 2 { return min(interval, fastRetry) }
        if failures <= 4 { return max(interval, 300) }
        return max(interval, 900)
    }

    /// 連線逾時：一般 20 秒，連續失敗 3 次以上 (多半不在範圍內) 縮短為 8 秒以省電
    static func connectTimeout(failures: Int) -> TimeInterval {
        failures >= 3 ? 8 : 20
    }

    /// 回傳 (現在該讀的裝置, 等待秒數)：已到期的依 order 順序挑第一台 (主裝置在最前面)
    static func pickNextDue(due: [String: Date], order: [String], now: Date,
                            maxWait: TimeInterval = Backoff.maxWait) -> (id: String?, wait: TimeInterval) {
        let candidates = order.filter { due[$0] != nil }
        if let ready = candidates.first(where: { due[$0]! <= now }) {
            return (ready, 0)
        }
        guard let earliest = candidates.compactMap({ due[$0] }).min() else { return (nil, maxWait) }
        return (nil, min(max(0, earliest.timeIntervalSince(now)), maxWait))
    }

    /// 調整間隔後的下次到期時間：以上次成功時間重新起算，已過期就立刻讀
    static func dueAfterIntervalChange(lastSuccess: Date?, interval: TimeInterval, now: Date) -> Date {
        guard let last = lastSuccess else { return now }
        return max(now, last.addingTimeInterval(interval))
    }

    /// 開源廣播裝置太久沒收到廣播 (2 倍間隔且至少 2 分鐘) 即視為不在範圍內
    static func isBroadcastStale(lastSeen: Date?, interval: TimeInterval, now: Date) -> Bool {
        guard let seen = lastSeen else { return true }
        return now.timeIntervalSince(seen) > max(2 * interval, 120)
    }
}
