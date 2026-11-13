import AppKit

/// 搜尋新裝置視窗：掃描中 (進度條) → 勾選清單 → 加入所選。
/// 用獨立視窗而非彈出式儀表板：儀表板一失去焦點就會收起，會打斷 20 秒的掃描。
final class DeviceSearchWindowController: NSWindowController, NSWindowDelegate {
    private let duration: TimeInterval
    private let existingIDs: () -> Set<String>
    var onAdd: (([DiscoveredDevice]) -> Void)?
    var onRetry: (() -> Void)?
    var onClose: (() -> Void)?

    private let stack = NSStackView()
    private var progress: NSProgressIndicator?
    private var countLabel: NSTextField?
    private var checks: [(NSButton, DiscoveredDevice)] = []

    init(duration: TimeInterval, existingIDs: @escaping () -> Set<String>) {
        self.duration = duration
        self.existingIDs = existingIDs
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 520, height: 180),
                            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        panel.title = "搜尋新裝置"
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        super.init(window: panel)
        panel.delegate = self

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 18, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView = NSView()
        panel.contentView?.addSubview(stack)
        if let content = panel.contentView {
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                stack.topAnchor.constraint(equalTo: content.topAnchor),
                stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
                stack.widthAnchor.constraint(equalToConstant: 520)
            ])
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - 階段一：掃描中

    func showSearching() {
        clear()
        let title = NSTextField(labelWithString: "正在搜尋附近的溫濕度計… (約 \(Int(duration)) 秒)")
        title.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        let bar = NSProgressIndicator()
        bar.isIndeterminate = false
        bar.minValue = 0
        bar.maxValue = 1
        bar.widthAnchor.constraint(equalToConstant: 480).isActive = true
        let count = NSTextField(labelWithString: "請讓溫濕度計靠近這台電腦 (藍牙就緒後才開始計時)。")
        count.textColor = .secondaryLabelColor
        progress = bar
        countLabel = count
        stack.addArrangedSubview(title)
        stack.addArrangedSubview(bar)
        stack.addArrangedSubview(count)
        stack.addArrangedSubview(buttonRow([button("取消", #selector(handleClose))]))
        present()
    }

    /// 掃描中的進度回報 (progress 0~1，藍牙就緒後才會前進)
    func update(_ found: [DiscoveredDevice], progress value: Double) {
        let n = DeviceDiscovery.newCandidates(found, existingIDs: existingIDs()).count
        progress?.doubleValue = value
        countLabel?.stringValue = "已找到 \(n) 台尚未加入的溫濕度計"
    }

    // MARK: - 階段二：勾選清單

    func finish(_ found: [DiscoveredDevice]) {
        clear()
        let fresh = DeviceDiscovery.newCandidates(found, existingIDs: existingIDs())
        if fresh.isEmpty {
            let hint = NSTextField(wrappingLabelWithString: "沒有找到新的溫濕度計。請確認溫濕度計在電腦附近、電池有電，而且沒有被手機米家 App 等其他裝置連線佔用。")
            hint.preferredMaxLayoutWidth = 480
            stack.addArrangedSubview(hint)
            stack.addArrangedSubview(buttonRow([button("重新搜尋", #selector(handleRetry)), button("關閉", #selector(handleClose))]))
        } else {
            stack.addArrangedSubview(NSTextField(labelWithString: "勾選要加入的溫濕度計 (訊號越強越靠近)："))
            for c in fresh {
                let check = NSButton(checkboxWithTitle: DeviceDiscovery.label(c), target: nil, action: nil)
                check.state = fresh.count == 1 ? .on : .off
                check.toolTip = c.id
                checks.append((check, c))
                stack.addArrangedSubview(check)
            }
            let add = button("加入所選", #selector(handleAdd))
            add.keyEquivalent = "\r"
            stack.addArrangedSubview(buttonRow([button("重新搜尋", #selector(handleRetry)), button("取消", #selector(handleClose)), add]))
        }
        present()
    }

    // MARK: - 事件

    @objc private func handleAdd() {
        let chosen = checks.filter { $0.0.state == .on }.map(\.1)
        let add = onAdd  // close() 會觸發 onClose，控制器可能隨之被釋放
        close()
        if !chosen.isEmpty { add?(chosen) }
    }

    @objc private func handleRetry() {
        onRetry?()
    }

    @objc private func handleClose() {
        close()
    }

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }

    // MARK: - 版面

    private func present() {
        window?.layoutIfNeeded()
        if let w = window, let size = w.contentView?.fittingSize {
            w.setContentSize(size)
        }
        if window?.isVisible == false { window?.center() }
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    private func clear() {
        checks = []
        progress = nil
        countLabel = nil
        for v in stack.arrangedSubviews {
            stack.removeArrangedSubview(v)
            v.removeFromSuperview()
        }
    }

    private func button(_ title: String, _ action: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.bezelStyle = .rounded
        return b
    }

    /// 按鈕靠右排列的一列
    private func buttonRow(_ buttons: [NSButton]) -> NSView {
        let row = NSStackView(views: buttons)
        row.orientation = .horizontal
        row.spacing = 8
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let container = NSStackView(views: [spacer, row])
        container.orientation = .horizontal
        container.distribution = .fill
        container.widthAnchor.constraint(equalToConstant: 480).isActive = true
        return container
    }
}
