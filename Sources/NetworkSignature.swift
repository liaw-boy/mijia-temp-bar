import Foundation

/// 目前所在網路的特徵 (預設閘道的 IP 與硬體位址)。網路變動通知很頻繁 (VPN、AirDrop 等虛擬介面一變就會通知)，
/// 每次都把所有溫濕度計重讀一次會多耗它們的電池；只有閘道換了才算換地方。
struct NetworkSignature: Equatable {
    /// VPN 等虛擬介面：經由它們的預設路由不代表所在地點
    static let virtualInterfacePrefixes = ["utun", "ipsec", "ppp", "tun", "tap", "wg", "tailscale", "zt"]

    var gatewayIP: String?
    var gatewayMAC: String?

    /// 沒有預設閘道 = 目前沒有網路，無法判斷在哪裡
    var isKnown: Bool { gatewayIP != nil }

    /// 是否換到另一個網路：兩邊都有閘道硬體位址就比對它 (不同地方的路由器常用同一個 IP)，否則比對 IP。
    /// 之前或現在沒有網路時無法判斷，視為沒換。
    static func isDifferentPlace(previous: NetworkSignature?, current: NetworkSignature) -> Bool {
        guard let previous = previous, previous.isKnown, current.isKnown else { return false }
        if let a = previous.gatewayMAC, let b = current.gatewayMAC {
            return a.caseInsensitiveCompare(b) != .orderedSame
        }
        return previous.gatewayIP != current.gatewayIP
    }

    static func isVirtualInterface(_ name: String) -> Bool {
        virtualInterfacePrefixes.contains { name.hasPrefix($0) }
    }

    /// 解析 `route -n get default` 的輸出
    static func parseRoute(_ output: String) -> (gateway: String?, interface: String?) {
        var gateway: String?
        var interface: String?
        for line in output.components(separatedBy: .newlines) {
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, !parts[1].isEmpty else { continue }
            if parts[0] == "gateway" { gateway = parts[1] }
            if parts[0] == "interface" { interface = parts[1] }
        }
        return (gateway, interface)
    }

    /// 解析 `arp -n <IP>` 的輸出，例如 `? (192.168.2.1) at 0:11:22:aa:bb:cc on en0 ifscope [ethernet]`；
    /// 還沒查到 (incomplete) 或沒有紀錄時為 nil
    static func parseARP(_ output: String) -> String? {
        let parts = output.split(separator: " ").map(String.init)
        guard let at = parts.firstIndex(of: "at"), at + 1 < parts.count, parts[at + 1].contains(":") else { return nil }
        return parts[at + 1].lowercased()
    }

    /// 讀目前的預設閘道 (會執行 route、arp 指令，請在背景執行緒呼叫)。
    /// 預設路由走 VPN 等虛擬介面時視為無法判斷，不觸發也不改記錄。
    static func readCurrent() -> NetworkSignature {
        let route = parseRoute(run("/sbin/route", ["-n", "get", "default"]) ?? "")
        guard let ip = route.gateway else { return NetworkSignature() }
        if let name = route.interface, isVirtualInterface(name) { return NetworkSignature() }
        return NetworkSignature(gatewayIP: ip, gatewayMAC: run("/usr/sbin/arp", ["-n", ip]).flatMap(parseARP))
    }

    private static func run(_ path: String, _ arguments: [String]) -> String? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }
}

/// 重新偵測的觸發規則：記住上次的網路特徵、喚醒與換網路各自上次觸發的時間，
/// 以及保底間隔內發生、還沒重讀的換網路 (純邏輯，可單元測試)
struct ReprobeGate {
    static let wakeGap: TimeInterval = 60        // 喚醒觸發的重新偵測至少間隔 60 秒
    static let networkGap: TimeInterval = 600    // 換網路觸發的保底間隔 10 分鐘 (網路在兩台路由器間反覆切換時)

    private(set) var baseline: NetworkSignature?
    private(set) var lastWake = Date.distantPast
    private(set) var lastNetwork = Date.distantPast
    private(set) var pendingMove = false

    /// 還沒重讀的換網路要在什麼時候補讀；沒有則為 nil
    var pendingDueAt: Date? { pendingMove ? lastNetwork.addingTimeInterval(ReprobeGate.networkGap) : nil }

    /// 從睡眠喚醒：可能已經換了地方，間隔夠就全部重讀 (也涵蓋還沒補讀的換網路)
    mutating func afterWake(now: Date = Date()) -> Bool {
        guard now.timeIntervalSince(lastWake) >= ReprobeGate.wakeGap else { return false }
        lastWake = now
        pendingMove = false
        return true
    }

    /// 網路變動：只有換到另一個網路 (預設閘道不同) 才全部重讀。
    /// 虛擬介面的假變動、斷線後重連同一個網路都不觸發；沒有網路時維持原本的記錄。
    /// 喚醒後一分鐘內連上的網路只更新記錄 (喚醒時已全部重讀)；保底間隔內的換網路先記著，由 afterPendingDue 補讀。
    mutating func afterNetworkChange(_ current: NetworkSignature, now: Date = Date()) -> Bool {
        guard current.isKnown else { return false }
        let moved = NetworkSignature.isDifferentPlace(previous: baseline, current: current)
        // 同一個閘道 IP 但硬體位址還沒查到時，保留原本查到的硬體位址
        let keepPrevious = !moved && current.gatewayMAC == nil && baseline?.gatewayIP == current.gatewayIP
        if !keepPrevious { baseline = current }
        guard moved else { return false }
        if now.timeIntervalSince(lastWake) < ReprobeGate.wakeGap {
            pendingMove = false
            return false
        }
        if now.timeIntervalSince(lastNetwork) < ReprobeGate.networkGap {
            pendingMove = true
            return false
        }
        lastNetwork = now
        pendingMove = false
        return true
    }

    /// 保底間隔到了：補讀之前記著的換網路
    mutating func afterPendingDue(now: Date = Date()) -> Bool {
        guard let due = pendingDueAt, now >= due else { return false }
        lastNetwork = now
        pendingMove = false
        return true
    }
}
