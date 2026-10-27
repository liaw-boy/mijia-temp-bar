import AppKit

enum ChartDataType: Int {
    case temperature = 0
    case humidity = 1
    case voltage = 2
}

final class ChartView: NSView {
    var dataType: ChartDataType = .temperature {
        didSet {
            needsDisplay = true
        }
    }

    private var points: [HistoryPoint] = []
    private var trackingArea: NSTrackingArea?
    private var hoveredPointIndex: Int?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor(white: 0.12, alpha: 0.9).cgColor
        layer?.borderColor = NSColor(white: 0.25, alpha: 0.6).cgColor
        layer?.borderWidth = 1.0
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func updatePoints(_ newPoints: [HistoryPoint]) {
        self.points = newPoints
        self.needsDisplay = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea!)
    }

    override func mouseMoved(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        guard points.count >= 2 else { return }

        let graphRect = bounds.insetBy(dx: 48, dy: 36)
        if graphRect.contains(location) {
            let ratio = max(0.0, min(1.0, (location.x - graphRect.minX) / graphRect.width))
            let index = Int(round(ratio * Double(points.count - 1)))
            if index >= 0 && index < points.count {
                hoveredPointIndex = index
                needsDisplay = true
                return
            }
        }
        if hoveredPointIndex != nil {
            hoveredPointIndex = nil
            needsDisplay = true
        }
    }

    override func mouseExited(with event: NSEvent) {
        hoveredPointIndex = nil
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        let b = bounds
        let graphRect = NSRect(x: 52, y: 32, width: b.width - 70, height: b.height - 54)

        if points.isEmpty {
            let emptyMsg = "尚無歷史數據，等待設備讀取中..." as NSString
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 13),
                .foregroundColor: NSColor.secondaryLabelColor
            ]
            let size = emptyMsg.size(withAttributes: attrs)
            emptyMsg.draw(at: NSPoint(x: (b.width - size.width) / 2, y: (b.height - size.height) / 2), withAttributes: attrs)
            return
        }

        // 提取當前模式數值
        let values: [Double]
        let unit: String
        let mainColor: NSColor
        let secondaryColor: NSColor

        switch dataType {
        case .temperature:
            values = points.map { $0.temperature }
            unit = "°C"
            mainColor = NSColor(red: 1.0, green: 0.52, blue: 0.15, alpha: 1.0) // 暖橙
            secondaryColor = NSColor(red: 1.0, green: 0.35, blue: 0.10, alpha: 0.25)
        case .humidity:
            values = points.map { $0.humidity }
            unit = "%"
            mainColor = NSColor(red: 0.10, green: 0.65, blue: 1.0, alpha: 1.0) // 湛藍
            secondaryColor = NSColor(red: 0.10, green: 0.50, blue: 0.95, alpha: 0.25)
        case .voltage:
            values = points.map { $0.voltage }
            unit = "V"
            mainColor = NSColor(red: 0.15, green: 0.85, blue: 0.50, alpha: 1.0) // 翡翠綠
            secondaryColor = NSColor(red: 0.10, green: 0.70, blue: 0.40, alpha: 0.25)
        }

        var minVal = values.min() ?? 0.0
        var maxVal = values.max() ?? 100.0
        if maxVal - minVal < 0.2 {
            maxVal += 0.5
            minVal -= 0.5
        } else {
            let padding = (maxVal - minVal) * 0.12
            maxVal += padding
            minVal -= padding
        }

        // 繪製水平網格線與 Y 軸標籤
        let gridSteps = 4
        let labelAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular),
            .foregroundColor: NSColor.tertiaryLabelColor
        ]

        ctx.setStrokeColor(NSColor(white: 0.28, alpha: 0.5).cgColor)
        ctx.setLineWidth(1.0)
        ctx.setLineDash(phase: 0, lengths: [3, 3])

        for i in 0...gridSteps {
            let ratio = CGFloat(i) / CGFloat(gridSteps)
            let y = graphRect.minY + ratio * graphRect.height
            let val = minVal + Double(ratio) * (maxVal - minVal)

            ctx.move(to: CGPoint(x: graphRect.minX, y: y))
            ctx.addLine(to: CGPoint(x: graphRect.maxX, y: y))
            ctx.strokePath()

            let valStr = String(format: (dataType == .voltage) ? "%.2f%@" : "%.1f%@", val, unit) as NSString
            let strSize = valStr.size(withAttributes: labelAttrs)
            valStr.draw(at: NSPoint(x: graphRect.minX - strSize.width - 8, y: y - strSize.height / 2), withAttributes: labelAttrs)
        }
        ctx.setLineDash(phase: 0, lengths: []) // 重置虛線

        // 繪製 X 軸時間標籤 (頭、中、尾)
        let df = DateFormatter()
        df.dateFormat = "HH:mm"
        if let firstDate = points.first?.timestamp, let lastDate = points.last?.timestamp {
            let startStr = df.string(from: firstDate) as NSString
            let endStr = df.string(from: lastDate) as NSString
            startStr.draw(at: NSPoint(x: graphRect.minX, y: 10), withAttributes: labelAttrs)
            let endSize = endStr.size(withAttributes: labelAttrs)
            endStr.draw(at: NSPoint(x: graphRect.maxX - endSize.width, y: 10), withAttributes: labelAttrs)
        }

        // 計算座標點集合
        var coords: [CGPoint] = []
        for i in 0..<points.count {
            let x = graphRect.minX + (CGFloat(i) / CGFloat(points.count - 1)) * graphRect.width
            let valRatio = CGFloat((values[i] - minVal) / (maxVal - minVal))
            let y = graphRect.minY + valRatio * graphRect.height
            coords.append(CGPoint(x: x, y: y))
        }

        // 建立漸層面積區域
        if let first = coords.first, let last = coords.last {
            let areaPath = CGMutablePath()
            areaPath.move(to: CGPoint(x: first.x, y: graphRect.minY))
            for pt in coords {
                areaPath.addLine(to: pt)
            }
            areaPath.addLine(to: CGPoint(x: last.x, y: graphRect.minY))
            areaPath.closeSubpath()

            ctx.saveGState()
            ctx.addPath(areaPath)
            ctx.clip()

            let colors = [secondaryColor.cgColor, NSColor(white: 0.1, alpha: 0.0).cgColor] as CFArray
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            if let gradient = CGGradient(colorsSpace: colorSpace, colors: colors, locations: [1.0, 0.0]) {
                ctx.drawLinearGradient(
                    gradient,
                    start: CGPoint(x: graphRect.midX, y: graphRect.maxY),
                    end: CGPoint(x: graphRect.midX, y: graphRect.minY),
                    options: []
                )
            }
            ctx.restoreGState()
        }

        // 繪製主折線
        ctx.setStrokeColor(mainColor.cgColor)
        ctx.setLineWidth(2.6)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)

        let linePath = CGMutablePath()
        if let first = coords.first {
            linePath.move(to: first)
            for pt in coords.dropFirst() {
                linePath.addLine(to: pt)
            }
        }
        ctx.addPath(linePath)
        ctx.strokePath()

        // 繪製極值標籤 (最高/最低)
        if let maxIndex = values.firstIndex(of: values.max() ?? 0.0), maxIndex < coords.count {
            drawCalloutBadge(at: coords[maxIndex], text: String(format: "最高 %.1f%@", values[maxIndex], unit), color: mainColor, isTop: true, in: ctx)
        }
        if let minIndex = values.firstIndex(of: values.min() ?? 0.0), minIndex < coords.count && minIndex != values.firstIndex(of: values.max() ?? 0.0) {
            drawCalloutBadge(at: coords[minIndex], text: String(format: "最低 %.1f%@", values[minIndex], unit), color: mainColor, isTop: false, in: ctx)
        }

        // 繪製游標懸停指示 (Hover Tooltip)
        if let hoverIdx = hoveredPointIndex, hoverIdx < coords.count {
            let pt = coords[hoverIdx]
            let p = points[hoverIdx]

            // 垂直游標對齊線
            ctx.setStrokeColor(NSColor(white: 0.8, alpha: 0.4).cgColor)
            ctx.setLineWidth(1.0)
            ctx.setLineDash(phase: 0, lengths: [2, 2])
            ctx.move(to: CGPoint(x: pt.x, y: graphRect.minY))
            ctx.addLine(to: CGPoint(x: pt.x, y: graphRect.maxY))
            ctx.strokePath()
            ctx.setLineDash(phase: 0, lengths: [])

            // 聚焦圓點
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.setStrokeColor(mainColor.cgColor)
            ctx.setLineWidth(2.5)
            ctx.fillEllipse(in: CGRect(x: pt.x - 5, y: pt.y - 5, width: 10, height: 10))
            ctx.strokeEllipse(in: CGRect(x: pt.x - 5, y: pt.y - 5, width: 10, height: 10))

            // 氣泡提示框
            let timeStr = df.string(from: p.timestamp)
            let tipText = String(format: "%@  %.1f%@", timeStr, values[hoverIdx], unit) as NSString
            let tipAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .bold),
                .foregroundColor: NSColor.white
            ]
            let tipSize = tipText.size(withAttributes: tipAttrs)
            let bubbleRect = NSRect(
                x: max(graphRect.minX, min(graphRect.maxX - tipSize.width - 16, pt.x - (tipSize.width + 16) / 2)),
                y: min(graphRect.maxY - 28, pt.y + 12),
                width: tipSize.width + 16,
                height: 24
            )

            let bubblePath = NSBezierPath(roundedRect: bubbleRect, xRadius: 6, yRadius: 6)
            NSColor(white: 0.08, alpha: 0.92).setFill()
            bubblePath.fill()
            mainColor.setStroke()
            bubblePath.lineWidth = 1.0
            bubblePath.stroke()

            tipText.draw(at: NSPoint(x: bubbleRect.minX + 8, y: bubbleRect.minY + 4), withAttributes: tipAttrs)
        }
    }

    private func drawCalloutBadge(at point: CGPoint, text: String, color: NSColor, isTop: Bool, in ctx: CGContext) {
        // 外圈圓點
        ctx.setFillColor(color.cgColor)
        ctx.fillEllipse(in: CGRect(x: point.x - 3.5, y: point.y - 3.5, width: 7, height: 7))
    }
}
