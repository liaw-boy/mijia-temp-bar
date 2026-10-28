import AppKit
import UserNotifications

final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationManager()

    // 提醒門檻：電量 <= 15% 或 電壓 <= 2.60V (進入 CR2032 斷崖崩塌期)
    private let lowBatteryThreshold = 15
    private let lowVoltageThreshold = 2.60
    private let cooldownSeconds: TimeInterval = 86400 // 24 小時冷卻，避免狂轟濫炸
    private let lastAlertKey = "LastLowBatteryNotificationDate"
    private let enabledKey = "LowBatteryNotificationEnabled"

    // 濕度警示：高於上限或低於下限時通知；回到範圍內 (含 2% 緩衝) 才重新武裝，持續超標則每 3 小時再提醒一次
    private let humidityEnabledKey = "HumidityAlertEnabled"
    private let humidityHighKey = "HumidityHighThreshold"
    private let humidityLowKey = "HumidityLowThreshold"
    private let humidityRepeatSeconds: TimeInterval = 3 * 3600
    private let humidityHysteresis = 2.0
    private enum HumidityState { case normal, high, low }
    private var humidityState: HumidityState = .normal
    private var lastHumidityAlert: Date?

    var isHumidityAlertEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: humidityEnabledKey) } // 預設關閉
        set { UserDefaults.standard.set(newValue, forKey: humidityEnabledKey); humidityState = .normal }
    }

    var humidityHigh: Int {
        get { UserDefaults.standard.object(forKey: humidityHighKey) as? Int ?? 70 }
        set { UserDefaults.standard.set(newValue, forKey: humidityHighKey); humidityState = .normal }
    }

    var humidityLow: Int {
        get { UserDefaults.standard.object(forKey: humidityLowKey) as? Int ?? 30 }
        set { UserDefaults.standard.set(newValue, forKey: humidityLowKey); humidityState = .normal }
    }

    var isEnabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: enabledKey) == nil {
                return true // 預設開啟提醒
            }
            return UserDefaults.standard.bool(forKey: enabledKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: enabledKey)
        }
    }

    override init() {
        super.init()
        requestAuthorization()
    }

    func requestAuthorization() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if granted {
                mijiaLog("[Notification] 系統通知權限已獲取")
            }
        }
    }

    func checkReading(_ reading: SensorReading) {
        checkHumidity(reading)
        guard isEnabled else { return }

        let isLow = reading.batteryPercent <= lowBatteryThreshold || reading.voltage <= lowVoltageThreshold

        guard isLow else {
            // 若換了新電池 (電量恢復至 30% 以上)，重置冷卻記錄
            if reading.batteryPercent > 30 {
                UserDefaults.standard.removeObject(forKey: lastAlertKey)
            }
            return
        }

        // 檢查 24 小時冷卻防干擾機制
        if let lastDate = UserDefaults.standard.object(forKey: lastAlertKey) as? Date {
            let elapsed = Date().timeIntervalSince(lastDate)
            if elapsed < cooldownSeconds {
                return // 冷卻期間內，暫不重複通知
            }
        }

        // 發送通知並更新時間戳
        sendLowBatteryNotification(percent: reading.batteryPercent, voltage: reading.voltage)
        UserDefaults.standard.set(Date(), forKey: lastAlertKey)
    }

    private func checkHumidity(_ reading: SensorReading) {
        guard isHumidityAlertEnabled else { return }
        let hum = reading.humidity
        let high = Double(humidityHigh)
        let low = Double(humidityLow)

        let current: HumidityState = hum > high ? .high : (hum < low ? .low : .normal)
        if current == .normal {
            // 回到範圍內並越過緩衝區才重新武裝，避免在門檻附近來回觸發
            if hum <= high - humidityHysteresis && hum >= low + humidityHysteresis {
                humidityState = .normal
                lastHumidityAlert = nil
            }
            return
        }

        let isNewExcursion = (current != humidityState)
        let repeatDue = lastHumidityAlert.map { Date().timeIntervalSince($0) >= humidityRepeatSeconds } ?? true
        guard isNewExcursion || repeatDue else { return }

        humidityState = current
        lastHumidityAlert = Date()
        let body = current == .high
            ? String(format: "目前濕度 %.0f%%，高於設定的上限 %d%%。", hum, humidityHigh)
            : String(format: "目前濕度 %.0f%%，低於設定的下限 %d%%。", hum, humidityLow)
        mijiaLog("[Notification] 濕度警示: \(body)")
        send(identifier: "MijiaTempBar.Humidity",
             title: current == .high ? "米家溫濕度計 2 - 濕度過高" : "米家溫濕度計 2 - 濕度過低",
             subtitle: "濕度警示", body: body)
    }

    private func sendLowBatteryNotification(percent: Int, voltage: Double) {
        let title = "米家溫濕度計 2 - 低電量提醒 🔋⚠️"
        let subtitle = "CR2032 鈕扣電池電量即將耗盡"
        let body = String(format: "目前電量僅剩 %d%% (%.3f V)，已進入斷崖放電期。建議您盡速備妥並更換 CR2032 鈕扣電池，以確保溫濕度監控不中斷。", percent, voltage)

        mijiaLog("[Notification] 觸發低電量通知: \(percent)%, \(voltage)V")
        send(identifier: "MijiaTempBar.LowBattery", title: title, subtitle: subtitle, body: body)
    }

    private func send(identifier: String, title: String, subtitle: String, body: String) {
        if Bundle.main.bundleIdentifier != nil {
            let content = UNMutableNotificationContent()
            content.title = title
            content.subtitle = subtitle
            content.body = body
            content.sound = .default

            let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
            UNUserNotificationCenter.current().add(request) { error in
                if let error = error {
                    mijiaLog("[Notification] UNUserNotificationCenter 發送失敗: \(error.localizedDescription)，改用系統備用通知方案")
                    self.fallbackNotify(title: title, body: body)
                }
            }
        } else {
            fallbackNotify(title: title, body: body)
        }
    }

    private func fallbackNotify(title: String, body: String) {
        // 先跳脫反斜線再跳脫雙引號，並移除換行，避免字串逸出 AppleScript 字面值
        func escape(_ text: String) -> String {
            text.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\r", with: " ")
        }
        let escapedTitle = escape(title)
        let escapedBody = escape(body)
        let script = "display notification \"\(escapedBody)\" with title \"\(escapedTitle)\" sound name \"default\""
        if let appleScript = NSAppleScript(source: script) {
            var errorInfo: NSDictionary?
            appleScript.executeAndReturnError(&errorInfo)
        }
    }

    // 支援 App 在前景時依然能彈出橫幅通知
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
