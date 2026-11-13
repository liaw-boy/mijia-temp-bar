import Foundation

// 純邏輯測試 (不需要 AppKit / CoreBluetooth)：./test_mac.sh 編譯執行。測試數據與 Linux 版 linux/tests 相同。

var failures = 0
var passed = 0

func check(_ condition: @autoclosure () -> Bool, _ message: String, file: String = #file, line: Int = #line) {
    if condition() {
        passed += 1
    } else {
        failures += 1
        print("✗ \(message) (\(URL(fileURLWithPath: file).lastPathComponent):\(line))")
    }
}

func hex(_ s: String) -> Data {
    var data = Data()
    var i = s.startIndex
    while i < s.endIndex {
        let j = s.index(i, offsetBy: 2)
        data.append(UInt8(s[i..<j], radix: 16)!)
        i = j
    }
    return data
}

let A = "88630D87-3210-EEC1-3500-85ECCF03B726"
let B = "11111111-2222-3333-4444-555555555555"

// MARK: - 解析
do {
    let m = AdvertisementParser.parseStockGATT(hex("1b09203c0b"))!
    check(m.temperature == 23.31 && m.humidity == 32 && m.voltage == 2.876 && m.batteryPercent == 86, "原廠 GATT 實機數據")
    check(AdvertisementParser.parseStockGATT(hex("f3fd50b80b"))!.temperature == -5.25, "原廠 GATT 負溫度")
    check(AdvertisementParser.parseStockGATT(hex("1b0920")) == nil, "原廠 GATT 長度不足")
    check(AdvertisementParser.batteryFromVoltage(2.6) == 55, "電壓換算電量")

    let mac = hex("a4c1388c9b32")
    var atc = mac; atc.append(hex("00eb2d57" + "0b86" + "01"))   // 23.5°C 45% 87% 2950mV
    let a = AdvertisementParser.parseEnvironmental(atc)!
    check(a.temperature == 23.5 && a.humidity == 45 && a.batteryPercent == 87 && a.voltage == 2.95 && a.mode == AdvertisementParser.modeATC, "ATC1441")

    var pvvx = Data(mac.reversed()); pvvx.append(hex("000a" + "0014" + "860b" + "57" + "0105"))  // 25.60°C 51.20%
    let p = AdvertisementParser.parseEnvironmental(pvvx)!
    check(p.temperature == 25.6 && p.humidity == 51.2 && p.mode == AdvertisementParser.modePVVX, "pvvx 不被誤判為 ATC")
    check(AdvertisementParser.parseEnvironmental(Data(repeating: 0xff, count: 13)) == nil, "廣播亂碼")

    let bt = AdvertisementParser.parseBTHome(hex("40" + "0001" + "015a" + "022909" + "03d711" + "0c860b"))!
    check(bt.temperature == 23.45 && bt.humidity == 45.67 && bt.batteryPercent == 90 && bt.voltage == 2.95, "BTHome v2")
    let bt2 = AdvertisementParser.parseBTHome(hex("40" + "45eb00" + "2e2d"))!
    check(bt2.temperature == 23.5 && bt2.humidity == 45 && bt2.batteryPercent == 100, "BTHome 替代物件")
    check(AdvertisementParser.parseBTHome(hex("40" + "022909" + "03d711" + "ff0102"))?.humidity == 45.67, "BTHome 遇未知物件停止")
    check(AdvertisementParser.parseBTHome(hex("41" + "022909" + "03d711")) == nil, "BTHome 加密封包忽略")
    check(AdvertisementParser.parseBTHome(hex("40" + "015a" + "022909")) == nil, "BTHome 缺濕度")
}

// MARK: - 退避與排程
do {
    check(Backoff.retryDelay(failures: 1, interval: 300) == 60, "退避 1 次")
    check(Backoff.retryDelay(failures: 2, interval: 30) == 30, "退避不超過間隔")
    check(Backoff.retryDelay(failures: 3, interval: 300) == 300, "退避 3 次")
    check(Backoff.retryDelay(failures: 5, interval: 300) == 900, "退避 5 次")
    check(Backoff.retryDelay(failures: 6, interval: 3600) == 3600, "退避不短於間隔")
    check(Backoff.connectTimeout(failures: 2) == 20 && Backoff.connectTimeout(failures: 3) == 8, "連線逾時")

    let now = Date(timeIntervalSince1970: 100)
    let d = { (s: Double) in Date(timeIntervalSince1970: s) }
    check(Backoff.pickNextDue(due: [:], order: [], now: now, maxWait: 60) == (nil, 60), "沒有裝置")
    check(Backoff.pickNextDue(due: [A: d(90), B: d(50)], order: [A, B], now: now).id == A, "到期依優先順序")
    check(Backoff.pickNextDue(due: [A: d(90), B: d(50)], order: [B, A], now: now).id == B, "到期依優先順序 2")
    check(Backoff.pickNextDue(due: [A: d(130), B: d(110)], order: [A, B], now: now, maxWait: 60) == (nil, 10), "等最早到期")
    check(Backoff.pickNextDue(due: [A: d(1000)], order: [A], now: now, maxWait: 60) == (nil, 60), "等待上限")
    check(Backoff.dueAfterIntervalChange(lastSuccess: nil, interval: 300, now: d(1000)) == d(1000), "改間隔：沒成功過")
    check(Backoff.dueAfterIntervalChange(lastSuccess: d(900), interval: 300, now: d(1000)) == d(1200), "改間隔：重新起算")
    check(Backoff.isBroadcastStale(lastSeen: d(800), interval: 30, now: d(1000)), "廣播過期 (最少 2 分鐘)")
    check(!Backoff.isBroadcastStale(lastSeen: d(900), interval: 30, now: d(1000)), "廣播未過期")
}

// MARK: - 裝置清單
do {
    let a = DeviceRecord(id: A, name: "客廳", kind: .stock)
    let b = DeviceRecord(id: B, name: "臥室", kind: .broadcast)
    check(DeviceList.parse(DeviceList.serialize([a, b])) == [a, b], "清單往返")
    let messy: [Any] = [["id": A.lowercased(), "name": "客廳", "kind": "stock"], ["id": A, "name": "重複", "kind": "stock"],
                        ["id": "", "name": "空", "kind": "stock"], ["id": B, "name": "x", "kind": "unknown"], "壞的"]
    check(DeviceList.parse(messy) == [a], "丟棄格式錯誤與重複")
    check(DeviceList.parse([["id": A, "name": "  ", "kind": "stock"]]).first?.name == "溫濕度計 1", "空白名稱給預設")
    check(DeviceList.defaultName(existing: [DeviceRecord(id: A, name: "溫濕度計 1", kind: .stock)]) == "溫濕度計 2", "預設名稱編號")
    check(DeviceList.fileID("A4:C1:38:8C:9B:32") == "A4C1388C9B32" && DeviceList.fileID("../..") == "unknown", "安全檔名")
    check((try? DeviceList.rename([a], id: A, to: "   ")) == nil, "空白名稱拒絕")
    check((try? DeviceList.cleanName(String(repeating: "字", count: 25))) == nil, "名稱過長拒絕")
    check(DeviceList.resolvePrimary([a, b], "missing") == A && DeviceList.resolvePrimary([], A) == nil, "主裝置解析")
}

// MARK: - 遷移與裝置儲存
do {
    let dir = testRoot.appendingPathComponent("migrate", isDirectory: true)
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let legacy = dir.appendingPathComponent("history.json")
    try! Data("[]".utf8).write(to: legacy)
    let lowDate = Date(timeIntervalSince1970: 1234)
    let store = MemoryStore([DeviceKeys.legacyTarget: A.lowercased(), DeviceKeys.legacyLowBattery: lowDate])
    let ds = DeviceStore(store: store, historyDir: dir.appendingPathComponent("history"), legacyHistory: legacy)
    check((try? Migration.run(store: store, deviceStore: ds, logFile: AppPaths.logFile)) == true, "執行遷移")
    check(ds.devices.map(\.id) == [A] && ds.primaryID == A, "舊目標成為主裝置")
    check(FileManager.default.fileExists(atPath: ds.historyURL(for: A).path), "舊歷史已複製")
    check(FileManager.default.fileExists(atPath: legacy.path), "舊歷史保留")
    check(store.data[DeviceKeys.legacyTarget] as? String == A.lowercased(), "舊設定鍵保留")
    check((store.data[DeviceKeys.lowBatteryDates] as? [String: Date])?[A] == lowDate, "低電量冷卻遷移")
    ds.remove(A)
    check((try? Migration.run(store: store, deviceStore: ds, logFile: AppPaths.logFile)) == false && ds.devices.isEmpty, "移除後不會從舊鍵復活")

    let dest = dir.appendingPathComponent("keep.json")
    try! Data("keep".utf8).write(to: dest)
    check((try? FileOps.copyWithoutOverwrite(from: legacy, to: dest)) == false, "不覆寫既有檔案")
    check((try? String(contentsOf: dest, encoding: .utf8)) == "keep", "既有檔案內容不變")

    let s2 = MemoryStore()
    let ds2 = DeviceStore(store: s2, historyDir: dir.appendingPathComponent("h2"), legacyHistory: legacy)
    _ = try? Migration.run(store: s2, deviceStore: ds2, logFile: AppPaths.logFile)
    check(s2.data[DeviceKeys.legacyUnclaimed] as? Bool == true, "廣播用戶的舊歷史標為無主")
    ds2.add([DeviceRecord(id: B, name: "臥室", kind: .broadcast)])
    check(FileManager.default.fileExists(atPath: ds2.historyURL(for: B).path), "第一台加入的裝置接收舊歷史")
    check(ds2.primaryID == B && s2.data[DeviceKeys.legacyUnclaimed] as? Bool == false, "無主歷史已認領")
    ds2.add([DeviceRecord(id: A, name: "客廳", kind: .stock)])
    ds2.setPrimary(A)
    check(ds2.orderedIDs == [A, B], "主裝置排第一")
    try? ds2.rename(A, to: "書房")
    check(ds2.device(A)?.name == "書房", "改名")

    let log = "[2026-11-13T15:45:31Z] 收到原廠數據: 溫度=20.85°C, 濕度=21.0%, 電壓=2.789V, 電量=76%\n" +
              "[2026-11-13T15:50:31Z] 收到原廠數據: 溫度=21.0°C, 濕度=22.0%, 電壓=2.8V, 電量=77% [\(A)]\n雜訊行"
    let pts = Migration.parseLogPoints(log)
    check(pts.count == 2 && pts[0].temperature == 20.85 && pts[1].batteryPercent == 77, "日誌回填 (新舊格式)")
}

// MARK: - 歷史
do {
    let dir = testRoot.appendingPathComponent("hist", isDirectory: true)
    let h = HistoryManager.forDevice(A, in: dir)
    check(h === HistoryManager.forDevice(A, in: dir), "同一台共用實例")
    h.addPoint(temp: 20, hum: 50, volt: 3, battery: 100)
    check(HistoryManager.forDevice(B, in: dir).points.isEmpty, "每台獨立")
    check(h.todayTemperatureRange()?.min == 20, "今日範圍")
    let broken = dir.appendingPathComponent("broken.json")
    try! Data("{bad".utf8).write(to: broken)
    check(HistoryManager(storageURL: broken).points.isEmpty, "損毀檔讀為空")
    let backups = (try? FileManager.default.contentsOfDirectory(atPath: dir.path))?.filter { $0.hasPrefix("broken.corrupt-") } ?? []
    check(backups.count == 1, "損毀檔另存")
}

// MARK: - 通知規則
do {
    let t = { (s: Double) in Date(timeIntervalSince1970: s) }
    check(LowBatteryPolicy.next(lastAlert: nil, percent: 10, voltage: 2.5, now: t(1000)) == (true, t(1000)), "低電量首次通知")
    check(LowBatteryPolicy.next(lastAlert: t(1000), percent: 10, voltage: 2.5, now: t(1500)) == (false, t(1000)), "低電量冷卻")
    check(LowBatteryPolicy.next(lastAlert: t(1000), percent: 80, voltage: 3.0, now: t(1500)) == (false, nil), "換電池重置")
    check(LowBatteryPolicy.next(lastAlert: t(1000), percent: 25, voltage: 2.8, now: t(1500)) == (false, t(1000)), "未回升保留冷卻")

    var m = HumidityMonitor()
    check(m.check(humidity: 75, high: 70, low: 30, now: t(0)) == .high, "濕度過高通知")
    check(m.check(humidity: 76, high: 70, low: 30, now: t(20)) == nil, "持續超標不重複")
    check(m.check(humidity: 69, high: 70, low: 30, now: t(30)) == nil, "緩衝區內")
    check(m.check(humidity: 75, high: 70, low: 30, now: t(40)) == nil, "未重新武裝")
    check(m.check(humidity: 75, high: 70, low: 30, now: t(HumidityMonitor.repeatInterval)) == .high, "3 小時再提醒")
    var other = HumidityMonitor()
    check(other.check(humidity: 55, high: 70, low: 30, now: t(1)) == nil && m.state == .high, "每台狀態獨立")
}

// MARK: - 顯示規則與搜尋
do {
    let r = SensorReading(temperature: 24.5, humidity: 68, batteryPercent: 76, voltage: 2.789, rssi: nil,
                          deviceName: "客廳", lastUpdated: Date(), mode: AdvertisementParser.modeStock)
    let up = DeviceState().withReading(r)
    let down = up.withStatus("設備未在連線範圍內", reachable: false)
    check(DisplayRules.trayValues(up) == (24.5, 68), "可連線顯示數字")
    check(DisplayRules.trayValues(DeviceState(reading: r, reachable: nil, status: "快取", cached: true)) == (24.5, 68), "快取顯示數字")
    check(DisplayRules.trayValues(down) == (nil, nil) && down.reading != nil, "連不到顯示 --")
    check(DisplayRules.shouldHideIcon(hideEnabled: true, deviceIDs: [A, B], states: [A: down, B: down]), "全部連不到才隱藏")
    check(!DisplayRules.shouldHideIcon(hideEnabled: true, deviceIDs: [A, B], states: [A: down, B: up]), "有一台可連不隱藏")
    check(!DisplayRules.shouldHideIcon(hideEnabled: true, deviceIDs: [A, B], states: [A: down]), "未確認不隱藏")
    check(!DisplayRules.shouldHideIcon(hideEnabled: true, deviceIDs: [], states: [:]), "沒有裝置不隱藏")
    check(DisplayRules.summaryText(name: "客廳", state: up) == "客廳 · 24.5° · 68%", "摘要")
    check(DisplayRules.summaryText(name: "客廳", state: down) == "客廳 · -- (設備未在連線範圍內)", "摘要連不到")
    check(DisplayRules.summaryText(name: "臥室", state: DeviceState()) == "臥室 · 等待讀取", "摘要等待")

    let bt = hex("40" + "0001" + "015a" + "022909" + "03d711" + "0c860b")
    let stock = DeviceDiscovery.candidate(id: A, name: "LYWSD03MMC", rssi: -61, serviceData: [:])
    check(stock?.kind == .stock && stock?.measurement == nil, "搜尋：原廠名稱")
    check(DeviceDiscovery.candidate(id: A, name: "LYWSD03MMC", rssi: -50, serviceData: ["FCD2": bt])?.kind == .broadcast, "搜尋：可解析廣播優先")
    check(DeviceDiscovery.candidate(id: A, name: "", rssi: -50, serviceData: ["FCD2": bt])?.name == "BTHome 溫濕度計", "搜尋：無名稱")
    check(DeviceDiscovery.candidate(id: A, name: "Phone", rssi: -40, serviceData: [:]) == nil, "搜尋：無關裝置")
    let c1 = DiscoveredDevice(id: A, name: "a", kind: .stock, rssi: -80, measurement: nil)
    let c2 = DiscoveredDevice(id: B, name: "b", kind: .stock, rssi: nil, measurement: nil)
    let c3 = DiscoveredDevice(id: "C", name: "c", kind: .stock, rssi: -40, measurement: nil)
    check(DeviceDiscovery.newCandidates([c1, c2, c3], existingIDs: [A]).map(\.id) == ["C", B], "搜尋：排除已加入並依訊號排序")
    check(DeviceDiscovery.merge(DiscoveredDevice(id: A, name: "x", kind: .broadcast, rssi: -50, measurement: nil),
                                DiscoveredDevice(id: A, name: "", kind: .stock, rssi: -70, measurement: nil)) ==
          DiscoveredDevice(id: A, name: "x", kind: .broadcast, rssi: -50, measurement: nil), "搜尋：合併")

    let payload = StatusFile.payload(devices: [DeviceRecord(id: A, name: "客廳", kind: .stock), DeviceRecord(id: B, name: "臥室", kind: .broadcast)],
                                     states: [A: up], primaryID: A, interval: 300, adapterStatus: nil)
    check(payload["temperature"] as? Double == 24.5 && payload["deviceName"] as? String == "客廳", "狀態檔頂層為主裝置")
    check((payload["devices"] as? [[String: Any]])?.count == 2 && payload["primaryDeviceId"] as? String == A, "狀態檔裝置陣列")
    check(StatusFile.payload(devices: [], states: [:], primaryID: nil, interval: 300, adapterStatus: "電腦藍牙已關閉")["status"] as? String == "電腦藍牙已關閉", "狀態檔藍牙狀態")
}

try? FileManager.default.removeItem(at: testRoot)
print("通過 \(passed) 項，失敗 \(failures) 項")
exit(failures == 0 ? 0 : 1)
