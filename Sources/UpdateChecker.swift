import Foundation

enum UpdateStatus {
    case upToDate(current: String)
    case available(version: String, url: URL)
    case failed(String)
}

/// 以 GitHub Releases 檢查是否有新版本 (只讀取公開資訊，不自動安裝)
final class UpdateChecker {
    static let shared = UpdateChecker()

    private let repo = "liaw-boy/mijia-temp-bar"
    private let autoCheckKey = "AutoCheckUpdates"
    private let lastCheckKey = "LastUpdateCheckDate"
    private let checkInterval: TimeInterval = 24 * 3600

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    var autoCheckEnabled: Bool {
        get {
            UserDefaults.standard.object(forKey: autoCheckKey) == nil ? true : UserDefaults.standard.bool(forKey: autoCheckKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: autoCheckKey) }
    }

    /// 啟動時呼叫：已開啟自動檢查且距上次超過一天才會連網
    func checkIfDue(completion: @escaping (UpdateStatus) -> Void) {
        guard autoCheckEnabled else { return }
        if let last = UserDefaults.standard.object(forKey: lastCheckKey) as? Date,
           Date().timeIntervalSince(last) < checkInterval {
            return
        }
        check(completion: completion)
    }

    /// 結果一律在主執行緒回呼
    func check(completion: @escaping (UpdateStatus) -> Void) {
        // 讀 releases 清單自己挑 v 前綴的版本，不用 /releases/latest：同一個 repo 也發 linux-v 版，可能被設成 Latest
        guard let apiURL = URL(string: "https://api.github.com/repos/\(repo)/releases?per_page=30") else { return }
        var request = URLRequest(url: apiURL, timeoutInterval: 10)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("MijiaTempBar/\(currentVersion)", forHTTPHeaderField: "User-Agent")

        let session = URLSession(configuration: .ephemeral)
        session.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }
            let status = self.parse(data: data, response: response, error: error)
            DispatchQueue.main.async {
                if case .failed = status {} else {
                    UserDefaults.standard.set(Date(), forKey: self.lastCheckKey)
                }
                completion(status)
            }
        }.resume()
    }

    private func parse(data: Data?, response: URLResponse?, error: Error?) -> UpdateStatus {
        if error != nil { return .failed("無法連線，請檢查網路") }
        guard let http = response as? HTTPURLResponse else { return .failed("無法取得版本資訊") }
        if http.statusCode == 404 { return .upToDate(current: currentVersion) } // 尚未發佈任何版本
        guard http.statusCode == 200, let data = data,
              let json = try? JSONSerialization.jsonObject(with: data) else {
            return .failed("版本資訊格式不正確")
        }
        return Self.pickLatest(json, current: currentVersion, repo: repo)
    }

    /// 從 releases 清單挑出 macOS 版 (v 加數字開頭，排除 linux-v、草稿與預覽版) 中最新的一筆並與目前版本比對
    static func pickLatest(_ json: Any, current: String, repo: String) -> UpdateStatus {
        guard let releases = json as? [[String: Any]] else { return .failed("版本資訊格式不正確") }
        var best: (version: String, url: URL)?
        for item in releases {
            guard item["draft"] as? Bool != true, item["prerelease"] as? Bool != true,
                  let tag = item["tag_name"] as? String, tag.hasPrefix("v"),
                  tag.dropFirst().first?.isNumber == true,
                  let htmlString = item["html_url"] as? String, let url = URL(string: htmlString),
                  isTrustedReleaseURL(url, repo: repo) else { continue }
            let version = String(tag.dropFirst())
            if best == nil || isNewer(version, than: best!.version) {
                best = (version, url)
            }
        }
        if let best = best, isNewer(best.version, than: current) {
            return .available(version: best.version, url: best.url)
        }
        return .upToDate(current: current)
    }

    /// 只接受本專案 GitHub 頁面，避免被導向其他網址
    static func isTrustedReleaseURL(_ url: URL, repo: String) -> Bool {
        // 擋掉 ..：瀏覽器會把 /<repo>/../../x 正規化成別人的頁面 (url.path 已解開百分比編碼)
        url.scheme == "https" && url.host == "github.com" && url.port == nil && url.user == nil
            && url.path.hasPrefix("/\(repo)/") && !url.path.split(separator: "/").contains("..")
    }

    /// 逐段比較數字版本 (1.10.0 > 1.9.2)；無法解析的段視為 0
    static func isNewer(_ a: String, than b: String) -> Bool {
        func parts(_ v: String) -> [Int] {
            v.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        }
        let pa = parts(a), pb = parts(b)
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
