import AppKit
import Network

/// 換地方偵測：電腦從睡眠喚醒、或換到另一個網路 (預設閘道不同) 時，通知所有裝置立刻重讀一次。
/// 帶筆電移動時，原本那台會連不到、新地方那台會連上，狀態列就能改顯示附近那台，不必等到下一次輪詢。
/// 網路變動通知很頻繁 (VPN、AirDrop 等虛擬介面)，比對預設閘道後只在真的換網路時觸發，避免多耗溫濕度計的電池。
final class ReprobeTriggers {
    private static let networkReason = "換到另一個網路"
    private let debounce: TimeInterval = 5      // 網路變動常會連續觸發多次，合併成一次
    private let macRetryDelay: TimeInterval = 3 // 剛換網路時閘道硬體位址可能還沒查到，等幾秒再讀一次
    private let onTrigger: (String) -> Void
    private let readSignature: () -> NetworkSignature
    private let pathMonitor = NWPathMonitor()
    /// 依序讀閘道，結果也依序回到主執行緒，不會被較舊的結果蓋掉
    private let readQueue = DispatchQueue(label: "com.boywei.MijiaTempBar.gateway", qos: .utility)
    private var gate = ReprobeGate()
    private var pendingTimer: Timer?
    private var pendingMoveTimer: Timer?
    private var pendingWake = false
    private var wakeObserver: NSObjectProtocol?

    /// readSignature 會執行 route、arp 指令，在背景執行緒呼叫
    init(readSignature: @escaping () -> NetworkSignature = NetworkSignature.readCurrent,
         onTrigger: @escaping (String) -> Void) {
        self.readSignature = readSignature
        self.onTrigger = onTrigger
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.pendingWake = true
            self?.schedule()
        }
        // 開始監看時會先收到一次目前的狀態：第一次比對只記下目前的網路，不會觸發
        pathMonitor.pathUpdateHandler = { [weak self] _ in
            DispatchQueue.main.async { self?.schedule() }
        }
        pathMonitor.start(queue: DispatchQueue.global(qos: .utility))
    }

    deinit {
        pathMonitor.cancel()
        pendingTimer?.invalidate()
        pendingMoveTimer?.invalidate()
        if let observer = wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }

    private func schedule() {
        guard pendingTimer == nil else { return }
        pendingTimer = addTimer(after: debounce) { [weak self] in self?.fire() }
    }

    private func fire() {
        pendingTimer = nil
        if pendingWake {
            pendingWake = false
            if gate.afterWake() { onTrigger("從睡眠喚醒") }
        }
        // 每次都比對網路 (喚醒後也要更新記錄)；讀閘道放到背景，比對回主執行緒做
        let read = readSignature
        let retryDelay = macRetryDelay
        readQueue.async { [weak self] in
            let first = read()
            let needsRetry = first.isKnown && first.gatewayMAC == nil
            if needsRetry { Thread.sleep(forTimeInterval: retryDelay) }
            let current = needsRetry ? read() : first
            DispatchQueue.main.async { [weak self] in self?.compare(current) }
        }
    }

    private func compare(_ current: NetworkSignature) {
        if gate.afterNetworkChange(current) { onTrigger(ReprobeTriggers.networkReason) }
        schedulePendingMove()
    }

    /// 保底間隔內又換了網路：間隔到了補讀一次
    private func schedulePendingMove() {
        guard let due = gate.pendingDueAt, pendingMoveTimer == nil else { return }
        pendingMoveTimer = addTimer(after: max(1, due.timeIntervalSinceNow + 1)) { [weak self] in
            guard let self = self else { return }
            self.pendingMoveTimer = nil
            if self.gate.afterPendingDue() {
                self.onTrigger(ReprobeTriggers.networkReason)
            } else {
                self.schedulePendingMove()
            }
        }
    }

    private func addTimer(after interval: TimeInterval, _ action: @escaping () -> Void) -> Timer {
        let t = Timer(timeInterval: interval, repeats: false) { _ in action() }
        RunLoop.main.add(t, forMode: .common)
        return t
    }
}
