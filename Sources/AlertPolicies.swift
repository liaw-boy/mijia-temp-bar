import Foundation

/// 低電量與濕度通知的判斷規則 (純邏輯，每台裝置各自一份狀態)
enum LowBatteryPolicy {
    static let lowPercent = 15
    static let lowVoltage = 2.60
    static let recoveredPercent = 30            // 換新電池 (電量回升到此值以上) 重置冷卻
    static let cooldown: TimeInterval = 86400   // 24 小時內不重複提醒

    static func isLow(percent: Int, voltage: Double) -> Bool {
        percent <= lowPercent || voltage <= lowVoltage
    }

    /// 回傳 (是否通知, 新的上次通知時間)
    static func next(lastAlert: Date?, percent: Int, voltage: Double, now: Date) -> (notify: Bool, lastAlert: Date?) {
        guard isLow(percent: percent, voltage: voltage) else {
            return (false, percent > recoveredPercent ? nil : lastAlert)
        }
        if let last = lastAlert, now.timeIntervalSince(last) < cooldown {
            return (false, last)
        }
        return (true, now)
    }
}

/// 濕度上下限警示的狀態機：進入超標狀態通知一次，持續超標每 3 小時再提醒；回到範圍內 (含 2% 緩衝) 才重新武裝
struct HumidityMonitor {
    enum Level { case normal, high, low }

    static let repeatInterval: TimeInterval = 3 * 3600
    static let hysteresis = 2.0

    private(set) var state: Level = .normal
    private(set) var lastAlert: Date?

    /// 回傳 .high / .low 表示此刻應通知，nil 表示不通知
    mutating func check(humidity: Double, high: Double, low: Double, now: Date) -> Level? {
        let current: Level = humidity > high ? .high : (humidity < low ? .low : .normal)
        if current == .normal {
            if humidity <= high - Self.hysteresis && humidity >= low + Self.hysteresis {
                state = .normal
                lastAlert = nil
            }
            return nil
        }
        let newExcursion = current != state
        let repeatDue = lastAlert.map { now.timeIntervalSince($0) >= Self.repeatInterval } ?? true
        guard newExcursion || repeatDue else { return nil }
        state = current
        lastAlert = now
        return current
    }
}
