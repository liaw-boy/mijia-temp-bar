import Foundation

enum DeviceKind: String {
    case stock      // 原廠韌體：GATT 即連即斷讀取
    case broadcast  // 開源韌體：解析廣播封包

    var title: String { self == .stock ? "原廠直連" : "開源廣播" }
}

struct DeviceRecord: Equatable {
    let id: String     // CBPeripheral.identifier 的 uuidString (大寫)
    let name: String   // 使用者自訂名稱
    let kind: DeviceKind

    var dictionary: [String: String] { ["id": id, "name": name, "kind": kind.rawValue] }
}

enum DeviceNameError: Error, LocalizedError {
    case blank, tooLong

    var errorDescription: String? {
        switch self {
        case .blank: return "名稱不可空白"
        case .tooLong: return "名稱最多 \(DeviceList.maxNameLength) 個字"
        }
    }
}

/// 裝置清單操作 (純函式，與 Linux 版 devices.py 相同規則)
enum DeviceList {
    static let maxNameLength = 24
    static let defaultPrefix = "溫濕度計"

    static func normalizeID(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }

    /// 把裝置 id 轉成安全的檔名 (只留英數字)
    static func fileID(_ id: String) -> String {
        let safe = String(id.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) && $0.isASCII })
        return safe.isEmpty ? "unknown" : safe
    }

    static func cleanName(_ name: String) throws -> String {
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.isEmpty { throw DeviceNameError.blank }
        if cleaned.count > maxNameLength { throw DeviceNameError.tooLong }
        return cleaned
    }

    /// 「溫濕度計 N」，N 取最小的未使用編號
    static func defaultName(existing: [DeviceRecord]) -> String {
        let used = Set(existing.map(\.name))
        var n = 1
        while used.contains("\(defaultPrefix) \(n)") { n += 1 }
        return "\(defaultPrefix) \(n)"
    }

    /// 從設定值還原：丟棄格式錯誤的項目，id 重複只留第一筆
    static func parse(_ raw: Any?) -> [DeviceRecord] {
        guard let items = raw as? [Any] else { return [] }
        var result: [DeviceRecord] = []
        for item in items {
            guard let dict = item as? [String: Any], let rawID = dict["id"] as? String,
                  let kindRaw = dict["kind"] as? String, let kind = DeviceKind(rawValue: kindRaw) else { continue }
            // Mac 的裝置 id 是 CBPeripheral.identifier；不是 UUID 的 (手動改壞的設定) 直接丟棄
            guard let uuid = UUID(uuidString: rawID.trimmingCharacters(in: .whitespacesAndNewlines)) else { continue }
            let id = uuid.uuidString
            guard !result.contains(where: { $0.id == id }) else { continue }
            let name = (try? cleanName(dict["name"] as? String ?? "")) ?? defaultName(existing: result)
            result.append(DeviceRecord(id: id, name: name, kind: kind))
        }
        return result
    }

    static func serialize(_ devices: [DeviceRecord]) -> [[String: String]] {
        devices.map(\.dictionary)
    }

    static func add(_ existing: [DeviceRecord], _ new: [DeviceRecord]) -> [DeviceRecord] {
        var result = existing
        for d in new {
            let id = normalizeID(d.id)
            if !result.contains(where: { $0.id == id }) {
                result.append(DeviceRecord(id: id, name: d.name, kind: d.kind))
            }
        }
        return result
    }

    static func remove(_ existing: [DeviceRecord], id: String) -> [DeviceRecord] {
        existing.filter { $0.id != id }
    }

    static func rename(_ existing: [DeviceRecord], id: String, to name: String) throws -> [DeviceRecord] {
        let cleaned = try cleanName(name)
        return existing.map { $0.id == id ? DeviceRecord(id: $0.id, name: cleaned, kind: $0.kind) : $0 }
    }

    /// 主裝置不在清單中時改用第一台；清單為空時為 nil
    static func resolvePrimary(_ devices: [DeviceRecord], _ primaryID: String?) -> String? {
        if let p = primaryID, devices.contains(where: { $0.id == p }) { return p }
        return devices.first?.id
    }
}

/// 設定存取介面 (UserDefaults 或測試用替身)
protocol KeyValueStore: AnyObject {
    func object(forKey key: String) -> Any?
    func set(_ value: Any?, forKey key: String)
}

extension UserDefaults: KeyValueStore {}

enum DeviceKeys {
    static let devices = "Devices"
    static let primary = "PrimaryDeviceID"
    static let legacyTarget = "TargetPeripheralUUID"
    static let legacyUnclaimed = "LegacyHistoryUnclaimed"
    static let legacyLowBattery = "LastLowBatteryNotificationDate"
    static let lowBatteryDates = "LowBatteryAlertDates"
    static let migrationPending = "MigrationPending"  // 上次遷移中途失敗；之後即使已有 Devices 也要再做一次
}

/// 裝置清單與主裝置的保存。只在主執行緒使用。
final class DeviceStore {
    private let store: KeyValueStore
    let historyDir: URL
    let legacyHistory: URL
    private(set) var devices: [DeviceRecord] = []
    private(set) var primaryID: String?

    init(store: KeyValueStore, historyDir: URL, legacyHistory: URL) {
        self.store = store
        self.historyDir = historyDir
        self.legacyHistory = legacyHistory
        reload()
    }

    func reload() {
        devices = DeviceList.parse(store.object(forKey: DeviceKeys.devices))
        primaryID = DeviceList.resolvePrimary(devices, store.object(forKey: DeviceKeys.primary) as? String)
    }

    func device(_ id: String?) -> DeviceRecord? {
        devices.first { $0.id == id }
    }

    var primary: DeviceRecord? { device(primaryID) }

    /// 主裝置排第一，其餘照清單順序 (輪詢時主裝置優先)
    var orderedIDs: [String] {
        var ids = devices.map(\.id)
        if let p = primaryID, let i = ids.firstIndex(of: p) {
            ids.remove(at: i)
            ids.insert(p, at: 0)
        }
        return ids
    }

    func historyURL(for id: String) -> URL {
        historyDir.appendingPathComponent("\(DeviceList.fileID(id)).json")
    }

    /// 加入新裝置 (已存在的略過)，回傳實際加入的裝置
    @discardableResult
    func add(_ newDevices: [DeviceRecord]) -> [DeviceRecord] {
        let before = Set(devices.map(\.id))
        let updated = DeviceList.add(devices, newDevices)
        let added = updated.filter { !before.contains($0.id) }
        if let first = added.first, store.object(forKey: DeviceKeys.legacyUnclaimed) as? Bool == true {
            claimLegacyHistory(for: first.id)
        }
        save(updated, primaryID)
        return added
    }

    private func claimLegacyHistory(for id: String) {
        do {
            _ = try FileOps.copyWithoutOverwrite(from: legacyHistory, to: historyURL(for: id))
            store.set(false, forKey: DeviceKeys.legacyUnclaimed)
            mijiaLog("舊歷史已交給第一台加入的裝置 \(id)")
        } catch {
            mijiaLog("無法把舊歷史複製給 \(id): \(error.localizedDescription)")
        }
    }

    /// 只從清單移除；該裝置的歷史檔保留在磁碟上
    func remove(_ id: String) {
        save(DeviceList.remove(devices, id: id), primaryID)
    }

    func rename(_ id: String, to name: String) throws {
        save(try DeviceList.rename(devices, id: id, to: name), primaryID)
    }

    func setPrimary(_ id: String) {
        guard device(id) != nil else { return }
        save(devices, id)
    }

    private func save(_ updated: [DeviceRecord], _ primary: String?) {
        let resolved = DeviceList.resolvePrimary(updated, primary)
        store.set(DeviceList.serialize(updated), forKey: DeviceKeys.devices)
        store.set(resolved, forKey: DeviceKeys.primary)
        devices = updated
        primaryID = resolved
    }
}

/// 檔案操作：只新增、絕不覆寫
enum FileOps {
    /// 複製檔案但絕不覆寫：先完整寫到同目錄的暫存檔，再搬到目的地 (目的地已存在時搬移會失敗，即放棄)。
    /// 回傳是否真的建立了目的地；來源不存在或目的地已存在都回傳 false，其他錯誤照常丟出。
    static func copyWithoutOverwrite(from src: URL, to dest: URL) throws -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: src.path), !fm.fileExists(atPath: dest.path) else { return false }
        try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        let tmp = dest.deletingLastPathComponent().appendingPathComponent(".\(dest.lastPathComponent).\(UUID().uuidString)")
        try fm.copyItem(at: src, to: tmp)
        defer { try? fm.removeItem(at: tmp) }
        do {
            try fm.moveItem(at: tmp, to: dest)
        } catch where fm.fileExists(atPath: dest.path) {
            return false
        }
        return true
    }
}
