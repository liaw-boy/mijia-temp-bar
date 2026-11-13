import AppKit
import UserNotifications

final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationManager()

    // 低電量提醒 (電量 <= 15% 或電壓 <= 2.60V) 與濕度警示：每台裝置各自的冷卻與狀態，規則見 AlertPolicies.swift
    private let enabledKey = "LowBatteryNotificationEnabled"
    private let humidityEnabledKey = "HumidityAlertEnabled"
    private let humidityHighKey = "HumidityHighThreshold"
    private let humidityLowKey = "HumidityLowThreshold"
    private var humidityMonitors: [String: HumidityMonitor] = [:]

    var isHumidityAlertEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: humidityEnabledKey) } // 預設關閉
        set { UserDefaults.standard.set(newValue, forKey: humidityEnabledKey); humidityMonitors.removeAll() }
    }

    var humidityHigh: Int {
        get { UserDefaults.standard.object(forKey: humidityHighKey) as? Int ?? 70 }
        set { UserDefaults.standard.set(newValue, forKey: humidityHighKey); humidityMonitors.removeAll() }
    }

    var humidityLow: Int {
        get { UserDefaults.standard.object(forKey: humidityLowKey) as? Int ?? 30 }
        set { UserDefaults.standard.set(newValue, forKey: humidityLowKey); humidityMonitors.removeAll() }
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

    /// 依這台裝置的讀數決定是否發出低電量與濕度通知
    func checkReading(_ reading: SensorReading, deviceID: String, deviceName: String) {
        checkHumidity(reading, deviceID: deviceID, deviceName: deviceName)
        guard isEnabled else { return }

        var dates = UserDefaults.standard.dictionary(forKey: DeviceKeys.lowBatteryDates) as? [String: Date] ?? [:]
        let last = dates[deviceID]
        let decision = LowBatteryPolicy.next(lastAlert: last, percent: reading.batteryPercent, voltage: reading.voltage, now: Date())
        if decision.lastAlert != last {
            dates[deviceID] = decision.lastAlert
            UserDefaults.standard.set(dates, forKey: DeviceKeys.lowBatteryDates)
        }
        guard decision.notify else { return }

        let body = String(format: "%@ 目前電量僅剩 %d%% (%.3f V)，已進入斷崖放電期。建議您盡速備妥並更換 CR2032 鈕扣電池，以確保溫濕度監控不中斷。",
                          deviceName, reading.batteryPercent, reading.voltage)
        mijiaLog("[Notification] 觸發低電量通知 [\(deviceID)]: \(reading.batteryPercent)%, \(reading.voltage)V")
        send(identifier: "MijiaTempBar.LowBattery.\(deviceID)", title: "\(deviceName) - 低電量提醒 🔋⚠️",
             subtitle: "CR2032 鈕扣電池電量即將耗盡", body: body)
    }

    private func checkHumidity(_ reading: SensorReading, deviceID: String, deviceName: String) {
        guard isHumidityAlertEnabled else { return }
        var monitor = humidityMonitors[deviceID] ?? HumidityMonitor()
        let level = monitor.check(humidity: reading.humidity, high: Double(humidityHigh), low: Double(humidityLow), now: Date())
        humidityMonitors[deviceID] = monitor
        guard let level = level else { return }

        let high = level == .high
        let body = high
            ? String(format: "%@ 目前濕度 %.0f%%，高於設定的上限 %d%%。", deviceName, reading.humidity, humidityHigh)
            : String(format: "%@ 目前濕度 %.0f%%，低於設定的下限 %d%%。", deviceName, reading.humidity, humidityLow)
        mijiaLog("[Notification] 濕度警示 [\(deviceID)]: \(body)")
        send(identifier: "MijiaTempBar.Humidity.\(deviceID)",
             title: high ? "\(deviceName) - 濕度過高" : "\(deviceName) - 濕度過低",
             subtitle: "濕度警示", body: body)
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
