import AppKit
import CoreWLAN

// 儀表板的「設定」分頁 (從 DashboardWindowController.swift 拆出，避免單檔過大)

/// 文字垂直置中並保留左右內距的標籤 cell
private final class PaddedLabelCell: NSTextFieldCell {
    private let horizontalInset: CGFloat = 12

    override func titleRect(forBounds rect: NSRect) -> NSRect {
        var r = super.titleRect(forBounds: rect)
        let h = cellSize(forBounds: rect).height
        r.origin.x = rect.origin.x + horizontalInset
        r.origin.y = rect.origin.y + (rect.height - h) / 2
        r.size.width = rect.width - horizontalInset * 2
        r.size.height = h
        return r
    }

    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        super.drawInterior(withFrame: titleRect(forBounds: cellFrame), in: controlView)
    }
}

/// 設定區塊容器：標題 + 圓角卡片，列由上往下排
final class SettingsSection: FlippedView {
    var nextY: CGFloat = 4
    var lastCaption: NSTextField?
    var lastTitle: NSTextField?
}

extension DashboardWindowController {
    // MARK: - 設定視圖 (Settings View)

    func setupSettingsView() {
        settingsScrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 710, height: 535))
        settingsScrollView.hasVerticalScroller = true
        settingsScrollView.autohidesScrollers = true
        settingsScrollView.drawsBackground = false
        mainContainer.addSubview(settingsScrollView)

        settingsContentView = FlippedView(frame: NSRect(x: 0, y: 0, width: settingsWidth, height: 700))
        settingsScrollView.documentView = settingsContentView

        var cursor: CGFloat = 4

        func button(_ title: String, _ width: CGFloat, _ action: Selector) -> NSButton {
            let b = NSButton(title: title, target: self, action: action)
            b.bezelStyle = .rounded
            b.frame.size = NSSize(width: width, height: 24)
            return b
        }
        func checkbox(_ action: Selector?) -> NSButton {
            let c = NSButton(checkboxWithTitle: "", target: action == nil ? nil : self, action: action)
            c.frame.size = NSSize(width: 18, height: 18)
            return c
        }
        func popUp(_ width: CGFloat) -> NSPopUpButton {
            let p = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: width, height: 24), pullsDown: false)
            return p
        }

        // 0. 裝置 (固定高度的一列，清單操作交給「管理…」跳出的選單)
        addDevicesSection(at: &cursor)

        // 1. 更新與省電
        var card = beginSection("更新與省電", at: &cursor)
        intervalPopUp = popUp(200)
        let intervalPresets: [(String, Double)] = [
            ("30 秒", 30.0), ("1 分鐘", 60.0), ("3 分鐘", 180.0), ("5 分鐘 (預設)", 300.0),
            ("10 分鐘", 600.0), ("15 分鐘", 900.0), ("30 分鐘", 1800.0), ("1 小時", 3600.0),
            ("2 小時", 7200.0), ("自訂...", -1.0)
        ]
        for (t, sec) in intervalPresets {
            let item = NSMenuItem(title: t, action: #selector(handleSelectInterval), keyEquivalent: "")
            item.target = self
            item.representedObject = sec
            intervalPopUp.menu?.addItem(item)
        }
        customIntervalField = NSTextField(frame: NSRect(x: 0, y: 0, width: 96, height: 22))
        customIntervalField.placeholderString = "自訂分鐘"
        customIntervalField.alignment = .center
        customIntervalField.target = self
        customIntervalField.action = #selector(handleCustomIntervalEntered)
        addRow(to: card, title: "更新間隔", caption: "間隔越長越省電；自訂請輸入分鐘後按 Enter。",
               controls: [intervalPopUp, customIntervalField])
        endSection(card, at: &cursor)

        // 2. 狀態列
        card = beginSection("狀態列", at: &cursor)
        stylePopUp = popUp(200)
        let styles = ["雙行膠囊 (TMP / HUM)", "純數字雙行 (26.1° / 63%)", "橫向完整 (26°C  65%)", "僅溫度 (26°C)", "緊湊單行 (26.1° 65%)"]
        for (i, st) in styles.enumerated() {
            let item = NSMenuItem(title: st, action: #selector(handleSelectStyle), keyEquivalent: "")
            item.target = self
            item.tag = i
            stylePopUp.menu?.addItem(item)
        }
        addRow(to: card, title: "圖示樣式", caption: nil, controls: [stylePopUp])
        hideWhenDisconnectedCheckbox = checkbox(#selector(handleToggleHideWhenDisconnected))
        addRow(to: card, title: "僅連線時顯示", caption: "所有裝置都連不到時隱藏狀態列圖示。", controls: [hideWhenDisconnectedCheckbox])
        launchAtLoginCheckbox = checkbox(#selector(handleToggleLaunchAtLogin))
        addRow(to: card, title: "登入時自動啟動", caption: "登入後自動在狀態列顯示。", controls: [launchAtLoginCheckbox])
        launchAtLoginCaption = card.lastCaption
        endSection(card, at: &cursor)

        // 通知
        card = beginSection("通知", at: &cursor)
        lowBatteryCheckbox = checkbox(#selector(handleToggleLowBatteryNotification))
        addRow(to: card, title: "低電量通知", caption: "電量 ≤ 15% 或電壓 ≤ 2.60V 時提醒，每台裝置每天最多一次。", controls: [lowBatteryCheckbox])

        humidityAlertCheckbox = checkbox(#selector(handleToggleHumidityAlert))
        addRow(to: card, title: "濕度警示", caption: "超出下方設定範圍時通知，持續超標每 3 小時再提醒。", controls: [humidityAlertCheckbox])

        func percentField() -> NSTextField {
            let f = NSTextField(frame: NSRect(x: 0, y: 0, width: 64, height: 22))
            f.alignment = .center
            f.target = self
            f.action = #selector(handleHumidityThresholdEntered)
            return f
        }
        humidityHighField = percentField()
        addRow(to: card, title: "濕度上限 (%)", caption: "高於此值時通知。輸入後按 Enter。", controls: [humidityHighField])
        humidityLowField = percentField()
        addRow(to: card, title: "濕度下限 (%)", caption: "低於此值時通知。輸入後按 Enter。", controls: [humidityLowField])
        endSection(card, at: &cursor)

        // 3. 居家感應
        card = beginSection("居家感應", at: &cursor)
        wifiCheckbox = checkbox(#selector(handleToggleWiFiOnly))
        addRow(to: card, title: "僅在指定 Wi-Fi 時連線", caption: "離開該網路時完全停止藍牙輪詢。", controls: [wifiCheckbox])

        wifiSSIDTextField = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 22))
        wifiSSIDTextField.placeholderString = "Wi-Fi 名稱 (SSID)"
        addRow(to: card, title: "Wi-Fi 名稱", caption: nil,
               controls: [wifiSSIDTextField, button("儲存", 56, #selector(handleSaveWiFiSSID)), button("清除", 56, #selector(handleClearWiFiSSID))])

        addRow(to: card, title: "使用目前連線的 Wi-Fi", caption: "將目前連上的 Wi-Fi 設為指定網路。",
               controls: [button("使用目前 Wi-Fi", 108, #selector(handleUseCurrentWiFi))])
        wifiHintLabel = card.lastCaption

        wifiBindGatewayCheckbox = checkbox(nil)
        wifiBindGatewayCheckbox.state = .on
        addRow(to: card, title: "同時比對路由器 MAC", caption: "閘道特徵檢測中...", controls: [wifiBindGatewayCheckbox])
        wifiGatewayInfoLabel = card.lastCaption

        geofenceCheckbox = checkbox(#selector(handleToggleGeofence))
        addRow(to: card, title: "GPS 地理圍欄", caption: "以粗略定位判斷是否在家，離家時停機。", controls: [geofenceCheckbox])

        geofenceRadiusPopUp = popUp(100)
        for r in [100.0, 200.0, 500.0, 1000.0] {
            let item = NSMenuItem(title: "\(Int(r)) 公尺", action: #selector(handleSelectRadius), keyEquivalent: "")
            item.target = self
            item.representedObject = r
            geofenceRadiusPopUp.menu?.addItem(item)
        }
        addRow(to: card, title: "感應半徑", caption: nil,
               controls: [geofenceRadiusPopUp, button("設為目前位置", 100, #selector(handleRecordHomeLocation)), button("清除", 56, #selector(handleClearHomeLocation))])

        presenceStatusBadge = NSTextField(frame: NSRect(x: 16, y: card.nextY + 6, width: settingsWidth - 32, height: 32))
        presenceStatusBadge.cell = PaddedLabelCell(textCell: "狀態：持續運作 (未啟用居家感應)")
        presenceStatusBadge.isEditable = false
        presenceStatusBadge.isSelectable = false
        presenceStatusBadge.isBordered = false
        presenceStatusBadge.drawsBackground = false
        presenceStatusBadge.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        presenceStatusBadge.wantsLayer = true
        presenceStatusBadge.layer?.cornerRadius = 8
        presenceStatusBadge.layer?.borderWidth = 1.0
        card.addSubview(presenceStatusBadge)
        card.nextY += 46
        endSection(card, at: &cursor)

        // 4. 版本更新
        card = beginSection("版本更新", at: &cursor)
        updateButton = button("檢查更新", 108, #selector(handleUpdateButton))
        addRow(to: card, title: "目前版本 \(UpdateChecker.shared.currentVersion)", caption: "查詢 GitHub 上是否有新版本。",
               controls: [updateButton])
        updateStatusLabel = card.lastCaption
        autoUpdateCheckbox = checkbox(#selector(handleToggleAutoUpdate))
        autoUpdateCheckbox.state = UpdateChecker.shared.autoCheckEnabled ? .on : .off
        addRow(to: card, title: "自動檢查更新", caption: "每天啟動時檢查一次，有新版本會標示在「設定」。", controls: [autoUpdateCheckbox])
        endSection(card, at: &cursor)

        // 5. 關於
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "-"
        let about = NSTextField(labelWithString: "MijiaTempBar v\(version)  ·  米家藍牙溫濕度計 2 (LYWSD03MMC)  ·  github.com/liaw-boy/mijia-temp-bar")
        about.frame = NSRect(x: 16, y: cursor + 2, width: settingsWidth - 32, height: 16)
        about.font = NSFont.systemFont(ofSize: 11)
        about.textColor = NSColor(white: 0.5, alpha: 1.0)
        settingsContentView.addSubview(about)
        cursor += 28

        settingsContentView.frame.size.height = max(cursor, 535)
    }

    private func beginSection(_ title: String, at cursor: inout CGFloat) -> SettingsSection {
        let header = NSTextField(labelWithString: title)
        header.frame = NSRect(x: 16, y: cursor, width: 300, height: 16)
        header.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        header.textColor = NSColor(white: 0.62, alpha: 1.0)
        settingsContentView.addSubview(header)
        cursor += 22

        let card = SettingsSection(frame: NSRect(x: 0, y: cursor, width: settingsWidth, height: 40))
        card.wantsLayer = true
        card.layer?.cornerRadius = 10
        card.layer?.backgroundColor = NSColor(white: 1.0, alpha: 0.05).cgColor
        card.layer?.borderWidth = 1.0
        card.layer?.borderColor = NSColor(white: 1.0, alpha: 0.08).cgColor
        settingsContentView.addSubview(card)
        return card
    }

    private func endSection(_ card: SettingsSection, at cursor: inout CGFloat) {
        card.frame.size.height = card.nextY + 4
        cursor += card.frame.height + 18
    }

    /// 單列 (統一規格)：左側標題 + 一行說明，右側控制項由右往左靠齊。
    /// 說明只佔控制項左側的剩餘寬度，一律單行；訊息過長以「…」截斷並放進 tooltip。
    private func addRow(to card: SettingsSection, title: String, caption: String?, controls: [NSView]) {
        let rowH: CGFloat = 52
        let inset: CGFloat = 16
        let y = card.nextY
        if card.nextY > 4 {
            let sep = NSBox(frame: NSRect(x: inset, y: y, width: settingsWidth - inset * 2, height: 1))
            sep.boxType = .separator
            card.addSubview(sep)
        }

        let controlsWidth = controls.reduce(0) { $0 + $1.frame.width } + CGFloat(max(0, controls.count - 1)) * 8
        let textWidth = settingsWidth - inset * 2 - controlsWidth - 16

        let titleLabel = NSTextField(labelWithString: title)
        card.lastTitle = titleLabel
        titleLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        titleLabel.textColor = NSColor(white: 0.95, alpha: 1.0)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.frame = NSRect(x: inset, y: y + (caption == nil ? (rowH - 18) / 2 : 9), width: textWidth, height: 18)
        card.addSubview(titleLabel)

        let captionLabel = NSTextField(labelWithString: caption ?? "")
        captionLabel.font = NSFont.systemFont(ofSize: 11)
        captionLabel.textColor = NSColor(white: 0.58, alpha: 1.0)
        captionLabel.lineBreakMode = .byTruncatingTail
        captionLabel.frame = NSRect(x: inset, y: y + 28, width: textWidth, height: 16)
        captionLabel.isHidden = (caption == nil)
        card.addSubview(captionLabel)
        card.lastCaption = captionLabel

        var right = settingsWidth - inset
        for c in controls.reversed() {
            let w = c.frame.width
            right -= w
            c.frame.origin = NSPoint(x: right, y: y + (rowH - c.frame.height) / 2)
            card.addSubview(c)
            right -= 8
        }
        card.nextY += rowH
    }


    // MARK: - 設定頁面數值載入
    func reloadSettingsValues() {
        // Wi-Fi 狀態
        wifiCheckbox.state = LocationGatekeeper.shared.isWiFiOnlyEnabled ? .on : .off
        wifiSSIDTextField.stringValue = LocationGatekeeper.shared.targetWiFiSSID ?? ""
        if wifiSSIDTextField.stringValue.isEmpty, let curSSID = CWWiFiClient.shared().interface()?.ssid(), !curSSID.isEmpty {
            wifiSSIDTextField.placeholderString = "Wi-Fi 名稱 (SSID)"
        } else {
            wifiSSIDTextField.placeholderString = "Wi-Fi 名稱 (SSID)"
        }

        let gateway = LocationGatekeeper.shared.getCurrentGatewayInfo()
        if let mac = gateway.mac {
            wifiGatewayInfoLabel.stringValue = "目前偵測到的閘道 MAC: \(mac) (IP: \(gateway.ip ?? "未知"))"
        } else {
            wifiGatewayInfoLabel.stringValue = "目前閘道: 尚未連上區域網路"
        }
        wifiBindGatewayCheckbox.state = (LocationGatekeeper.shared.homeGatewayMAC != nil) ? .on : .off

        // GPS 地理圍欄
        geofenceCheckbox.state = LocationGatekeeper.shared.isEnabled ? .on : .off
        let currentRadius = LocationGatekeeper.shared.geofenceRadius
        if let idx = geofenceRadiusPopUp.menu?.items.firstIndex(where: { abs(($0.representedObject as? Double ?? 0) - currentRadius) < 1.0 }) {
            geofenceRadiusPopUp.selectItem(at: idx)
        }

        // 間隔頻率
        let savedSec = UserDefaults.standard.double(forKey: "RefreshIntervalSeconds")
        let currentSec = savedSec > 0 ? savedSec : 300.0
        var matched = false
        for item in intervalPopUp.itemArray {
            if let s = item.representedObject as? Double, abs(s - currentSec) < 0.1 {
                intervalPopUp.select(item)
                matched = true
                break
            }
        }
        if !matched {
            let lastItem = intervalPopUp.itemArray.last
            intervalPopUp.select(lastItem)
            let mins = currentSec / 60.0
            let text = mins.truncatingRemainder(dividingBy: 1) == 0 ? String(format: "%.0f", mins) : String(format: "%.1f", mins)
            lastItem?.title = "自訂 (\(text) 分鐘)"
            customIntervalField.stringValue = text
        } else {
            intervalPopUp.itemArray.last?.title = "自訂..."
            customIntervalField.stringValue = ""
        }

        // 樣式
        let currentStyle = UserDefaults.standard.integer(forKey: "DisplayStyle")
        stylePopUp.selectItem(withTag: currentStyle)

        // 隱藏與通知
        hideWhenDisconnectedCheckbox.state = UserDefaults.standard.bool(forKey: "HideWhenDisconnected") ? .on : .off
        lowBatteryCheckbox.state = NotificationManager.shared.isEnabled ? .on : .off
        humidityAlertCheckbox.state = NotificationManager.shared.isHumidityAlertEnabled ? .on : .off
        humidityHighField.stringValue = "\(NotificationManager.shared.humidityHigh)"
        humidityLowField.stringValue = "\(NotificationManager.shared.humidityLow)"
        humidityHighField.isEnabled = NotificationManager.shared.isHumidityAlertEnabled
        humidityLowField.isEnabled = NotificationManager.shared.isHumidityAlertEnabled

        reloadDeviceSection()
        reloadLaunchAtLogin()
        updatePresenceStatus()
    }

    func updatePresenceStatus() {
        guard presenceStatusBadge != nil else { return }

        if LocationGatekeeper.shared.isWiFiOnlyEnabled {
            let target = LocationGatekeeper.shared.targetWiFiSSID ?? "未指定"
            if LocationGatekeeper.shared.isInHomeArea {
                presenceStatusBadge.stringValue = "狀態：已連上指定 Wi-Fi [\(target)] · 藍牙輪詢正常運作中"
                presenceStatusBadge.layer?.backgroundColor = NSColor(red: 0.10, green: 0.55, blue: 0.25, alpha: 0.35).cgColor
                presenceStatusBadge.layer?.borderColor = NSColor(red: 0.20, green: 0.85, blue: 0.40, alpha: 0.6).cgColor
                presenceStatusBadge.textColor = NSColor(red: 0.35, green: 0.95, blue: 0.55, alpha: 1.0)
            } else {
                presenceStatusBadge.stringValue = "狀態：未連線至指定 Wi-Fi [\(target)] · 已徹底休眠停機 (0 耗電)"
                presenceStatusBadge.layer?.backgroundColor = NSColor(red: 0.60, green: 0.35, blue: 0.05, alpha: 0.35).cgColor
                presenceStatusBadge.layer?.borderColor = NSColor(red: 0.95, green: 0.60, blue: 0.10, alpha: 0.6).cgColor
                presenceStatusBadge.textColor = NSColor(red: 1.0, green: 0.75, blue: 0.30, alpha: 1.0)
            }
        } else if LocationGatekeeper.shared.isEnabled {
            let isHome = LocationGatekeeper.shared.isInHomeArea
            if let dist = LocationGatekeeper.shared.lastKnownDistance {
                if isHome {
                    presenceStatusBadge.stringValue = String(format: "狀態：已在居家大範圍內 (距家約 %.0fm) · 正常運作", dist)
                    presenceStatusBadge.layer?.backgroundColor = NSColor(red: 0.10, green: 0.55, blue: 0.25, alpha: 0.35).cgColor
                    presenceStatusBadge.layer?.borderColor = NSColor(red: 0.20, green: 0.85, blue: 0.40, alpha: 0.6).cgColor
                    presenceStatusBadge.textColor = NSColor(red: 0.35, green: 0.95, blue: 0.55, alpha: 1.0)
                } else {
                    presenceStatusBadge.stringValue = String(format: "狀態：已超出居家大範圍 (距家約 %.0fm) · 藍牙停機休眠中", dist)
                    presenceStatusBadge.layer?.backgroundColor = NSColor(red: 0.60, green: 0.35, blue: 0.05, alpha: 0.35).cgColor
                    presenceStatusBadge.layer?.borderColor = NSColor(red: 0.95, green: 0.60, blue: 0.10, alpha: 0.6).cgColor
                    presenceStatusBadge.textColor = NSColor(red: 1.0, green: 0.75, blue: 0.30, alpha: 1.0)
                }
            } else {
                presenceStatusBadge.stringValue = isHome ? "狀態：已在居家大範圍內 · 正常運作" : "狀態：超出居家大範圍 · 藍牙停機休眠中"
                presenceStatusBadge.layer?.backgroundColor = NSColor(red: 0.10, green: 0.55, blue: 0.25, alpha: 0.35).cgColor
                presenceStatusBadge.layer?.borderColor = NSColor(red: 0.20, green: 0.85, blue: 0.40, alpha: 0.6).cgColor
                presenceStatusBadge.textColor = NSColor(red: 0.35, green: 0.95, blue: 0.55, alpha: 1.0)
            }
        } else {
            presenceStatusBadge.stringValue = "狀態：持續運作模式 (未開啟在席感應，固定週期輪詢)"
            presenceStatusBadge.layer?.backgroundColor = NSColor(white: 0.20, alpha: 0.35).cgColor
            presenceStatusBadge.layer?.borderColor = NSColor(white: 0.50, alpha: 0.4).cgColor
            presenceStatusBadge.textColor = NSColor(white: 0.80, alpha: 1.0)
        }
    }

    // MARK: - 設定頁面動作處理
    @objc private func handleToggleWiFiOnly() {
        if LocationGatekeeper.shared.targetWiFiSSID == nil {
            handleSaveWiFiSSID()
            return
        }
        LocationGatekeeper.shared.isWiFiOnlyEnabled.toggle()
        wifiCheckbox.state = LocationGatekeeper.shared.isWiFiOnlyEnabled ? .on : .off
        updatePresenceStatus()
        onSettingsChanged?()
    }

    /// 以目前連線的 Wi-Fi 直接綁定 (不跳額外視窗，訊息顯示在該列說明)
    @objc private func handleUseCurrentWiFi() {
        wifiHintLabel.textColor = NSColor(white: 0.58, alpha: 1.0)
        wifiHintLabel.stringValue = "讀取目前 Wi-Fi 中..."
        LocationGatekeeper.shared.readCurrentSSID { [weak self] ssid, error in
            guard let self = self else { return }
            guard let ssid = ssid else {
                self.wifiHintLabel.stringValue = error ?? "讀不到目前的 Wi-Fi"
                self.wifiHintLabel.textColor = NSColor(red: 1.0, green: 0.65, blue: 0.20, alpha: 1.0)
                return
            }
            self.wifiSSIDTextField.stringValue = ssid
            LocationGatekeeper.shared.setTargetWiFi(ssid: ssid, bindCurrentGateway: self.wifiBindGatewayCheckbox.state == .on)
            self.wifiHintLabel.stringValue = "已綁定目前的 Wi-Fi：\(ssid)"
            self.reloadSettingsValues()
            self.onSettingsChanged?()
        }
    }

    // MARK: - 版本更新
    @objc private func handleUpdateButton() {
        if let url = availableUpdateURL {
            NSWorkspace.shared.open(url)
            return
        }
        updateStatusLabel.textColor = NSColor(white: 0.58, alpha: 1.0)
        updateStatusLabel.stringValue = "檢查中..."
        updateButton.isEnabled = false
        UpdateChecker.shared.check { [weak self] status in
            self?.showUpdateStatus(status)
        }
    }

    @objc private func handleToggleAutoUpdate() {
        UpdateChecker.shared.autoCheckEnabled = (autoUpdateCheckbox.state == .on)
    }

    func showUpdateStatus(_ status: UpdateStatus) {
        updateButton.isEnabled = true
        switch status {
        case .upToDate(let current):
            availableUpdateURL = nil
            updateButton.title = "檢查更新"
            updateStatusLabel.stringValue = "已是最新版本 (\(current))。"
            updateStatusLabel.textColor = NSColor(red: 0.25, green: 0.88, blue: 0.50, alpha: 1.0)
            topSegmentedControl.setLabel("設定", forSegment: 1)
        case .available(let version, let url):
            availableUpdateURL = url
            updateButton.title = "前往下載"
            updateStatusLabel.stringValue = "有新版本 \(version)，請前往 GitHub 下載。"
            updateStatusLabel.textColor = NSColor(red: 1.0, green: 0.65, blue: 0.20, alpha: 1.0)
            topSegmentedControl.setLabel("設定 ●", forSegment: 1)
        case .failed(let message):
            availableUpdateURL = nil
            updateButton.title = "檢查更新"
            updateStatusLabel.stringValue = message
            updateStatusLabel.textColor = NSColor(red: 1.0, green: 0.65, blue: 0.20, alpha: 1.0)
        }
    }

    @objc private func handleSaveWiFiSSID() {
        var ssid = wifiSSIDTextField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if ssid.isEmpty, let curSSID = CWWiFiClient.shared().interface()?.ssid(), !curSSID.isEmpty {
            ssid = curSSID
            wifiSSIDTextField.stringValue = ssid
        }

        guard !ssid.isEmpty, ssid.utf8.count <= 32 else {
            let alert = NSAlert()
            alert.messageText = "請輸入有效的 Wi-Fi 名稱"
            alert.informativeText = "請在輸入框填入您家中的 Wi-Fi 名稱 (SSID)。"
            alert.runModal()
            return
        }

        let bindGateway = (wifiBindGatewayCheckbox.state == .on)
        LocationGatekeeper.shared.setTargetWiFi(ssid: ssid, bindCurrentGateway: bindGateway)
        reloadSettingsValues()
        onSettingsChanged?()

        let alert = NSAlert()
        alert.messageText = "Wi-Fi 綁定成功"
        alert.informativeText = "已綁定 Wi-Fi: \(ssid)\n現在僅在連上該 Wi-Fi 時才會與溫濕度計連線；離網或切換其他網路時將徹底休眠停機。"
        alert.runModal()
    }

    @objc private func handleClearWiFiSSID() {
        LocationGatekeeper.shared.clearWiFiSettings()
        wifiSSIDTextField.stringValue = ""
        reloadSettingsValues()
        onSettingsChanged?()
    }

    @objc private func handleToggleGeofence() {
        if !LocationGatekeeper.shared.hasHomeLocation {
            handleRecordHomeLocation()
            return
        }
        LocationGatekeeper.shared.isEnabled.toggle()
        geofenceCheckbox.state = LocationGatekeeper.shared.isEnabled ? .on : .off
        updatePresenceStatus()
        onSettingsChanged?()
    }

    @objc private func handleRecordHomeLocation() {
        LocationGatekeeper.shared.recordCurrentAsHome { [weak self] success, msg in
            DispatchQueue.main.async {
                self?.reloadSettingsValues()
                self?.onSettingsChanged?()
                let alert = NSAlert()
                alert.messageText = success ? "居家位置設定成功" : "設定提示"
                alert.informativeText = msg
                alert.runModal()
            }
        }
    }

    @objc private func handleClearHomeLocation() {
        LocationGatekeeper.shared.clearHomeLocation()
        reloadSettingsValues()
        onSettingsChanged?()
    }

    @objc private func handleSelectRadius() {
        guard let r = geofenceRadiusPopUp.selectedItem?.representedObject as? Double else { return }
        LocationGatekeeper.shared.geofenceRadius = r
        onSettingsChanged?()
    }

    @objc private func handleSelectInterval() {
        guard let sec = intervalPopUp.selectedItem?.representedObject as? Double else { return }
        if sec < 0 {
            // 自訂：游標移到同列的輸入欄，不開額外視窗
            customIntervalField.window?.makeFirstResponder(customIntervalField)
            return
        }
        onIntervalChanged?(sec)
        reloadSettingsValues()
        onSettingsChanged?()
    }

    @objc private func handleCustomIntervalEntered() {
        let text = customIntervalField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        // 0.5 分鐘 ~ 24 小時；無效輸入就還原成目前設定
        if let mins = Double(text), mins >= 0.5, mins <= 1440 {
            onIntervalChanged?(mins * 60.0)
            onSettingsChanged?()
        }
        reloadSettingsValues()
        customIntervalField.window?.makeFirstResponder(nil)
    }

    @objc private func handleSelectStyle() {
        let tag = stylePopUp.selectedTag()
        if let style = DisplayStyle(rawValue: tag) {
            onStyleChanged?(style)
            onSettingsChanged?()
        }
    }

    @objc private func handleToggleHideWhenDisconnected() {
        let hide = (hideWhenDisconnectedCheckbox.state == .on)
        onHideWhenDisconnectedChanged?(hide)
        onSettingsChanged?()
    }

    @objc private func handleToggleHumidityAlert() {
        NotificationManager.shared.isHumidityAlertEnabled = (humidityAlertCheckbox.state == .on)
        reloadSettingsValues()
        onSettingsChanged?()
    }

    /// 上限需大於下限且皆在 0~100；輸入無效就還原成目前設定
    @objc private func handleHumidityThresholdEntered() {
        let high = Int(humidityHighField.stringValue.trimmingCharacters(in: .whitespaces))
        let low = Int(humidityLowField.stringValue.trimmingCharacters(in: .whitespaces))
        if let h = high, let l = low, (0...100).contains(h), (0...100).contains(l), l < h {
            NotificationManager.shared.humidityHigh = h
            NotificationManager.shared.humidityLow = l
        }
        reloadSettingsValues()
        humidityHighField.window?.makeFirstResponder(nil)
    }

    @objc private func handleToggleLowBatteryNotification() {
        NotificationManager.shared.isEnabled = (lowBatteryCheckbox.state == .on)
        onSettingsChanged?()
    }

    // MARK: - 裝置區塊
    private func addDevicesSection(at cursor: inout CGFloat) {
        let card = beginSection("裝置", at: &cursor)
        let manage = NSButton(title: "管理…", target: self, action: #selector(handleManageDevices(_:)))
        manage.bezelStyle = .rounded
        manage.frame.size = NSSize(width: 72, height: 24)
        let search = NSButton(title: "搜尋新裝置…", target: self, action: #selector(handleSearchDevices))
        search.bezelStyle = .rounded
        search.frame.size = NSSize(width: 104, height: 24)
        addRow(to: card, title: "尚未加入裝置", caption: "每台可設為狀態列顯示、改名或移除；移除不會刪除歷史紀錄。",
               controls: [manage, search])
        deviceSummaryTitle = card.lastTitle
        endSection(card, at: &cursor)
    }

    func reloadDeviceSection() {
        guard let title = deviceSummaryTitle else { return }
        let devices = coordinator?.devices ?? []
        if devices.isEmpty {
            title.stringValue = "尚未加入裝置"
        } else {
            let primary = devices.first { $0.id == coordinator?.primaryID }?.name ?? "-"
            title.stringValue = "共 \(devices.count) 台 · 狀態列顯示：\(primary)"
        }
    }

    @objc private func handleManageDevices(_ sender: NSButton) {
        guard let coordinator = coordinator else { return }
        let menu = DeviceMenuBuilder.deviceMenu(for: coordinator)
        _ = menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    @objc private func handleSearchDevices() {
        coordinator?.openDeviceSearch()
    }

    // MARK: - 登入時自動啟動
    func reloadLaunchAtLogin() {
        guard let checkbox = launchAtLoginCheckbox else { return }
        let state = LoginItemManager.currentState()
        checkbox.state = state.isOn ? .on : .off
        launchAtLoginCaption?.stringValue = state.caption
        launchAtLoginCaption?.toolTip = state.caption
    }

    @objc private func handleToggleLaunchAtLogin() {
        let state = LoginItemManager.setEnabled(launchAtLoginCheckbox.state == .on)
        launchAtLoginCheckbox.state = state.isOn ? .on : .off
        launchAtLoginCaption?.stringValue = state.caption
        launchAtLoginCaption?.toolTip = state.caption
        if case .requiresApproval = state {
            LoginItemManager.openLoginItemsSettings()
        }
    }
}
