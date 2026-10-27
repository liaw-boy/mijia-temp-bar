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
        layer?.cornerRadius = 16
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor(red: 0.08, green: 0.09, blue: 0.12, alpha: 0.95).cgColor
        layer?.borderColor = NSColor(white: 1.0, alpha: 0.10).cgColor
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

        let graphRect = bounds.insetBy(dx: 56, dy: 40)
        if graphRect.contains(location) {
            let ratio = max(0.0, min(1.0, (location.x - graphRect.minX) / graphRect.width))
            let index = Int(round(ratio * Double(points.count - 1)))
            if index >= 0 && index < points.count {
                if hoveredPointIndex != index {
                    hoveredPointIndex = index
                    needsDisplay = true
                }
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
        // 留出左側 Y 軸標籤與底部 X 軸時間標籤空間
        let graphRect = NSRect(x: 58, y: 36, width: b.width - 78, height: b.height - 58)

        if points.isEmpty {
            let emptyMsg = "尚無採樣數據，設備連線後將自動繪製..." as NSString
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 13, weight: .medium),
                .foregroundColor: NSColor(white: 0.5, alpha: 1.0)
            ]
            let size = emptyMsg.size(withAttributes: attrs)
            emptyMsg.draw(at: NSPoint(x: (b.width - size.width) / 2, y: (b.height - size.height) / 2), withAttributes: attrs)
            return
        }

        // 數值與配色定義
        let values: [Double]
        let mainColor: NSColor
        let gradientTopColor: NSColor

        switch dataType {
        case .temperature:
            values = points.map { $0.temperature }
            mainColor = NSColor(red: 1.0, green: 0.48, blue: 0.12, alpha: 1.0) // 暖橙霓虹
            gradientTopColor = NSColor(red: 1.0, green: 0.45, blue: 0.10, alpha: 0.35)
        case .humidity:
            values = points.map { $0.humidity }
            mainColor = NSColor(red: 0.05, green: 0.68, blue: 1.0, alpha: 1.0) // 湛藍流光
            gradientTopColor = NSColor(red: 0.05, green: 0.60, blue: 0.95, alpha: 0.35)
        case .voltage:
            values = points.map { $0.voltage }
            mainColor = NSColor(red: 0.10, green: 0.88, blue: 0.52, alpha: 1.0) // 翡翠電光綠
            gradientTopColor = NSColor(red: 0.10, green: 0.80, blue: 0.45, alpha: 0.35)
        }

        let rawMin = values.min() ?? 0.0
        let rawMax = values.max() ?? 1.0

        // ★★★ 關鍵：極致精準的動態範圍縮放 (防止電壓被壓成一條死平線) ★★★
        var minVal: Double
        var maxVal: Double

        switch dataType {
        case .voltage:
            // 電壓變化幅度通常在 2.85V ~ 2.90V (50mV) 之間，上下給予 15mV 的邊距
            let span = max(0.015, rawMax - rawMin)
            let pad = span * 0.18
            minVal = rawMin - pad
            maxVal = rawMax + pad
        case .temperature:
            let span = max(0.8, rawMax - rawMin)
            let pad = span * 0.15
            minVal = rawMin - pad
            maxVal = rawMax + pad
        case .humidity:
            let span = max(3.0, rawMax - rawMin)
            let pad = span * 0.15
            minVal = max(0.0, rawMin - pad)
            maxVal = min(100.0, rawMax + pad)
        }

        // 1. 繪製水平參考線與 Y 軸標籤
        let gridLines = 4
        let labelAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .regular),
            .foregroundColor: NSColor(white: 0.55, alpha: 1.0)
        ]

        ctx.setLineWidth(1.0)
        for i in 0...gridLines {
            let ratio = CGFloat(i) / CGFloat(gridLines)
            let y = graphRect.minY + ratio * graphRect.height
            let val = minVal + Double(ratio) * (maxVal - minVal)

            ctx.setStrokeColor(NSColor(white: 1.0, alpha: 0.07).cgColor)
            ctx.setLineDash(phase: 0, lengths: [4, 4])
            ctx.move(to: CGPoint(x: graphRect.minX, y: y))
            ctx.addLine(to: CGPoint(x: graphRect.maxX, y: y))
            ctx.strokePath()

            let valStr = String(format: (dataType == .voltage) ? "%.3fV" : (dataType == .temperature ? "%.1f°" : "%.0f%%"), val) as NSString
            let size = valStr.size(withAttributes: labelAttrs)
            valStr.draw(at: NSPoint(x: graphRect.minX - size.width - 8, y: y - size.height / 2), withAttributes: labelAttrs)
        }
        ctx.setLineDash(phase: 0, lengths: [])

        // 2. 繪製 X 軸時間標籤 (沿時間軸均勻分佈 5 個時間點)
        let df = DateFormatter()
        df.dateFormat = "HH:mm"
        let timeSteps = 4
        for i in 0...timeSteps {
            let ratio = CGFloat(i) / CGFloat(timeSteps)
            let x = graphRect.minX + ratio * graphRect.width
            let ptIdx = Int(round(Double(points.count - 1) * Double(ratio)))

            if ptIdx < points.count {
                let dateStr = df.string(from: points[ptIdx].timestamp) as NSString
                let size = dateStr.size(withAttributes: labelAttrs)
                let textX = max(graphRect.minX, min(graphRect.maxX - size.width, x - size.width / 2))
                dateStr.draw(at: NSPoint(x: textX, y: 12), withAttributes: labelAttrs)

                // 底部時間微型垂直刻度
                ctx.setStrokeColor(NSColor(white: 1.0, alpha: 0.15).cgColor)
                ctx.move(to: CGPoint(x: x, y: graphRect.minY))
                ctx.addLine(to: CGPoint(x: x, y: graphRect.minY - 4))
                ctx.strokePath()
            }
        }

        // 3. 計算所有座標點
        var coords: [CGPoint] = []
        for i in 0..<points.count {
            let x = graphRect.minX + (CGFloat(i) / CGFloat(points.count - 1)) * graphRect.width
            let v = values[i]
            let valRatio = CGFloat((v - minVal) / (maxVal - minVal))
            let y = graphRect.minY + valRatio * graphRect.height
            coords.append(CGPoint(x: x, y: y))
        }

        // 4. 構建平滑貝茲曲線 (Smooth Spline)
        let linePath = CGMutablePath()
        if let first = coords.first {
            linePath.move(to: first)
            if coords.count == 2 {
                linePath.addLine(to: coords[1])
            } else if coords.count > 2 {
                for i in 0..<(coords.count - 1) {
                    let p0 = (i > 0) ? coords[i - 1] : coords[i]
                    let p1 = coords[i]
                    let p2 = coords[i + 1]
                    let p3 = (i + 2 < coords.count) ? coords[i + 2] : p2

                    let cp1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6.0, y: p1.y + (p2.y - p0.y) / 6.0)
                    let cp2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6.0, y: p2.y - (p3.y - p1.y) / 6.0)
                    linePath.addCurve(to: p2, control1: cp1, control2: cp2)
                }
            }
        }

        // 5. 繪製底部漸層光暈區域 (Gradient Area)
        if let first = coords.first, let last = coords.last {
            let areaPath = CGMutablePath()
            areaPath.move(to: CGPoint(x: first.x, y: graphRect.minY))
            areaPath.addPath(linePath)
            areaPath.addLine(to: CGPoint(x: last.x, y: graphRect.minY))
            areaPath.closeSubpath()

            ctx.saveGState()
            ctx.addPath(areaPath)
            ctx.clip()

            let colors = [gradientTopColor.cgColor, NSColor(white: 0.1, alpha: 0.0).cgColor] as CFArray
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

        // 6. 繪製主折線 (加微弱外發光)
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: 6.0, color: mainColor.withAlphaComponent(0.6).cgColor)
        ctx.setStrokeColor(mainColor.cgColor)
        ctx.setLineWidth(2.8)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.addPath(linePath)
        ctx.strokePath()
        ctx.restoreGState()

        // 7. 懸停互動氣泡 (Interactive Tooltip HUD)
        if let hIdx = hoveredPointIndex, hIdx < coords.count {
            let pt = coords[hIdx]
            let p = points[hIdx]

            // 垂直對齊光柱
            ctx.setStrokeColor(NSColor(white: 1.0, alpha: 0.45).cgColor)
            ctx.setLineWidth(1.0)
            ctx.setLineDash(phase: 0, lengths: [3, 3])
            ctx.move(to: CGPoint(x: pt.x, y: graphRect.minY))
            ctx.addLine(to: CGPoint(x: pt.x, y: graphRect.maxY))
            ctx.strokePath()
            ctx.setLineDash(phase: 0, lengths: [])

            // 光點同心圓
            ctx.setFillColor(mainColor.cgColor)
            ctx.fillEllipse(in: CGRect(x: pt.x - 6, y: pt.y - 6, width: 12, height: 12))
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fillEllipse(in: CGRect(x: pt.x - 3, y: pt.y - 3, width: 6, height: 6))

            // 精美懸浮膠囊氣泡
            let timeStr = df.string(from: p.timestamp)
            let valStr = String(format: (dataType == .voltage) ? "%.3f V" : (dataType == .temperature ? "%.1f °C" : "%.1f %%"), values[hIdx])
            let fullText = "\(timeStr) · \(valStr)" as NSString

            let bubbleAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .bold),
                .foregroundColor: NSColor.white
            ]
            let textSz = fullText.size(withAttributes: bubbleAttrs)
            let bubbleW = textSz.width + 20
            let bubbleH: CGFloat = 26
            let bubbleX = max(graphRect.minX + 4, min(graphRect.maxX - bubbleW - 4, pt.x - bubbleW / 2))
            let bubbleY = min(graphRect.maxY - bubbleH - 4, max(graphRect.minY + 4, pt.y + 14))
            let bubbleRect = NSRect(x: bubbleX, y: bubbleY, width: bubbleW, height: bubbleH)

            // 氣泡背景深色毛玻璃
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -2), blur: 8, color: NSColor.black.withAlphaComponent(0.6).cgColor)
            let bubblePath = NSBezierPath(roundedRect: bubbleRect, xRadius: 7, yRadius: 7)
            NSColor(red: 0.12, green: 0.14, blue: 0.18, alpha: 0.95).setFill()
            bubblePath.fill()
            mainColor.setStroke()
            bubblePath.lineWidth = 1.2
            bubblePath.stroke()
            ctx.restoreGState()

            fullText.draw(at: NSPoint(x: bubbleX + 10, y: bubbleY + 5), withAttributes: bubbleAttrs)
        }
    }
}
