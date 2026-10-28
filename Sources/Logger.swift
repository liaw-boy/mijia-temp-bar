import Foundation

/// 應用程式檔案路徑：放在使用者專屬目錄，而非全域可寫的 /tmp
enum AppPaths {
    static let supportDir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("MijiaTempBar", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        return dir
    }()

    static let logFile: URL = {
        let base = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("Logs/MijiaTempBar", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        return dir.appendingPathComponent("mijia_temp_bar.log")
    }()

    static let statusJSON = supportDir.appendingPathComponent("mijia_status.json")
}

private let maxLogBytes = 1_000_000

/// 日誌超過上限就輪替成 .1 (只保留一份舊檔)，避免無限成長
private func rotateLogIfNeeded(_ url: URL) {
    guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int, size > maxLogBytes else { return }
    let old = url.appendingPathExtension("1")
    try? FileManager.default.removeItem(at: old)
    try? FileManager.default.moveItem(at: url, to: old)
}

func mijiaLog(_ message: String) {
    let timestamp = ISO8601DateFormatter().string(from: Date())
    let line = "[\(timestamp)] \(message)\n"
    if let data = line.data(using: .utf8) {
        let url = AppPaths.logFile
        rotateLogIfNeeded(url)
        if FileManager.default.fileExists(atPath: url.path) {
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            }
        } else {
            FileManager.default.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600])
        }
    }
    NSLog("[MijiaTempBar] %@", message)
}
