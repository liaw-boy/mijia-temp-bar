import Foundation

// 測試用替身：取代 Logger.swift，讓純邏輯檔不寫入使用者的日誌與 Application Support

let testRoot: URL = {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("mijia-tests-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}()

enum AppPaths {
    static let supportDir = testRoot.appendingPathComponent("support", isDirectory: true)
    static let logFile = testRoot.appendingPathComponent("test.log")
    static let statusJSON = testRoot.appendingPathComponent("status.json")
}

func mijiaLog(_ message: String) {}

/// 與 UserDefaults 相同介面的記憶體設定
final class MemoryStore: KeyValueStore {
    var data: [String: Any] = [:]
    init(_ initial: [String: Any] = [:]) { data = initial }
    func object(forKey key: String) -> Any? { data[key] }
    func set(_ value: Any?, forKey key: String) { data[key] = value }
}
