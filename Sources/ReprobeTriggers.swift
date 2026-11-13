import AppKit
import Network

/// 換地方偵測：電腦從睡眠喚醒或網路變動 (例如換了 Wi-Fi) 時，通知所有裝置立刻重讀一次。
/// 帶筆電移動時，原本那台會連不到、新地方那台會連上，狀態列就能改顯示附近那台，不必等到下一次輪詢。
final class ReprobeTriggers {
    private let debounce: TimeInterval = 5     // 網路變動常會連續觸發多次，合併成一次
    private let minGap: TimeInterval = 60      // 兩次重新偵測至少間隔 60 秒
    private let onTrigger: (String) -> Void
    private let pathMonitor = NWPathMonitor()
    private var pendingTimer: Timer?
    private var pendingReason = ""
    private var lastFired = Date.distantPast
    private var sawFirstPath = false
    private var wakeObserver: NSObjectProtocol?

    init(onTrigger: @escaping (String) -> Void) {
        self.onTrigger = onTrigger
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.schedule("從睡眠喚醒")
        }
        pathMonitor.pathUpdateHandler = { [weak self] _ in
            DispatchQueue.main.async {
                guard let self = self else { return }
                // 開始監看時會先收到一次目前的狀態，那不是變動
                if self.sawFirstPath { self.schedule("網路變動") } else { self.sawFirstPath = true }
            }
        }
        pathMonitor.start(queue: DispatchQueue.global(qos: .utility))
    }

    deinit {
        pathMonitor.cancel()
        if let observer = wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }

    private func schedule(_ reason: String) {
        pendingReason = reason
        guard pendingTimer == nil else { return }
        let t = Timer(timeInterval: debounce, repeats: false) { [weak self] _ in self?.fire() }
        RunLoop.main.add(t, forMode: .common)
        pendingTimer = t
    }

    private func fire() {
        pendingTimer = nil
        guard Date().timeIntervalSince(lastFired) >= minGap else { return }
        lastFired = Date()
        onTrigger(pendingReason)
    }
}
