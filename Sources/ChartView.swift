import AppKit

enum ChartDataType: Int {
    case overview = 0
    case temperature = 1
    case humidity = 2
    case voltage = 3
}

final class ChartView: NSView {
    var dataType: ChartDataType = .overview {
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

        let isOverview = (dataType == .overview)
        let graphRect = NSRect(x: 54, y: 36, width: bounds.width - (isOverview ? 104 : 78), height: bounds.height - 58)

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
        let isOverview = (dataType == .overview)
        let graphRect = NSRect(x: 54, y: 36, width: b.width - (isOverview ? 106 : 78), height: b.height - 58)

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

        let df = DateFormatter()
        df.dateFormat = "HH:mm"

        if isOverview {
            drawOverviewChart(in: ctx, graphRect: graphRect, df: df)
        } else {
            drawSingleMetricChart(in: ctx, graphRect: graphRect, df: df)
        }
    }

    // MARK: - 綜合總覽圖表 (雙 Y 軸：左邊溫度，右邊濕度)
    private func drawOverviewChart(in ctx: CGContext, graphRect: NSRect, df: DateFormatter) {
        let temps = points.map { $0.temperature }
        let hums = points.map { $0.humidity }

        let rawMinT = temps.min() ?? 20.0
        let rawMaxT = temps.max() ?? 30.0
        let spanT = max(1.0, rawMaxT - rawMinT)
        let padT = spanT * 0.18
        let minT = rawMinT - padT
        let maxT = rawMaxT + padT

        let rawMinH = hums.min() ?? 40.0
        let rawMaxH = hums.max() ?? 80.0
        let spanH = max(4.0, rawMaxH - rawMinH)
        let padH = spanH * 0.18
        let minH = max(0.0, rawMinH - padH)
        let maxH = min(100.0, rawMaxH + padH)

        let tempColor = NSColor(red: 1.0, green: 0.48, blue: 0.12, alpha: 1.0) // 暖橙
        let humColor = NSColor(red: 0.05, green: 0.68, blue: 1.0, alpha: 1.0)   // 湛藍

        // 1. 水平參考線與雙側 Y 軸標籤 (左橙溫度，右藍濕度)
        let gridLines = 4
        let labelAttrsT: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold),
            .foregroundColor: tempColor
        ]
        let labelAttrsH: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold),
            .foregroundColor: humColor
        ]

        for i in 0...gridLines {
            let ratio = CGFloat(i) / CGFloat(gridLines)
            let y = graphRect.minY + ratio * graphRect.height

            ctx.setStrokeColor(NSColor(white: 1.0, alpha: 0.07).cgColor)
            ctx.setLineWidth(1.0)
            ctx.setLineDash(phase: 0, lengths: [4, 4])
            ctx.move(to: CGPoint(x: graphRect.minX, y: y))
            ctx.addLine(to: CGPoint(x: graphRect.maxX, y: y))
            ctx.strokePath()

            // 左側溫度
            let valT = minT + Double(ratio) * (maxT - minT)
            let strT = String(format: "%.1f°", valT) as NSString
            let sizeT = strT.size(withAttributes: labelAttrsT)
            strT.draw(at: NSPoint(x: graphRect.minX - sizeT.width - 6, y: y - sizeT.height / 2), withAttributes: labelAttrsT)

            // 右側濕度
            let valH = minH + Double(ratio) * (maxH - minH)
            let strH = String(format: "%.0f%%", valH) as NSString
            let sizeH = strH.size(withAttributes: labelAttrsH)
            strH.draw(at: NSPoint(x: graphRect.maxX + 6, y: y - sizeH.height / 2), withAttributes: labelAttrsH)
        }
        ctx.setLineDash(phase: 0, lengths: [])

        // 2. 底部 X 軸時間標籤
        drawXAxisTimestamps(in: ctx, graphRect: graphRect, df: df)

        // 3. 計算溫度座標點
        var coordsT: [CGPoint] = []
        var coordsH: [CGPoint] = []
        for i in 0..<points.count {
            let x = graphRect.minX + (CGFloat(i) / CGFloat(points.count - 1)) * graphRect.width
            let yT = graphRect.minY + CGFloat((temps[i] - minT) / (maxT - minT)) * graphRect.height
            let yH = graphRect.minY + CGFloat((hums[i] - minH) / (maxH - minH)) * graphRect.height
            coordsT.append(CGPoint(x: x, y: yT))
            coordsH.append(CGPoint(x: x, y: yH))
        }

        // 4. 繪製平滑曲線與微光暈面積
        drawSplineArea(coords: coordsT, minY: graphRect.minY, color: tempColor.withAlphaComponent(0.20), in: ctx)
        drawSplineArea(coords: coordsH, minY: graphRect.minY, color: humColor.withAlphaComponent(0.20), in: ctx)

        drawSplineLine(coords: coordsT, color: tempColor, lineWidth: 2.6, in: ctx)
        drawSplineLine(coords: coordsH, color: humColor, lineWidth: 2.6, in: ctx)

        // 5. 圖例標籤 (Top Legends)
        let legendY = graphRect.maxY + 4
        let legT = "● 溫度 (°C)" as NSString
        let legH = "● 濕度 (%)" as NSString
        legT.draw(at: NSPoint(x: graphRect.minX + 4, y: legendY), withAttributes: [.font: NSFont.systemFont(ofSize: 11, weight: .bold), .foregroundColor: tempColor])
        legH.draw(at: NSPoint(x: graphRect.minX + 85, y: legendY), withAttributes: [.font: NSFont.systemFont(ofSize: 11, weight: .bold), .foregroundColor: humColor])

        // 6. 懸停提示 (Hover Tooltip: 顯示時間、溫度、濕度、電量)
        if let hIdx = hoveredPointIndex, hIdx < points.count {
            let ptT = coordsT[hIdx]
            let ptH = coordsH[hIdx]
            let p = points[hIdx]

            // 垂直對齊線
            ctx.setStrokeColor(NSColor(white: 1.0, alpha: 0.45).cgColor)
            ctx.setLineWidth(1.0)
            ctx.setLineDash(phase: 0, lengths: [3, 3])
            ctx.move(to: CGPoint(x: ptT.x, y: graphRect.minY))
            ctx.addLine(to: CGPoint(x: ptT.x, y: graphRect.maxY))
            ctx.strokePath()
            ctx.setLineDash(phase: 0, lengths: [])

            // 光點
            drawGlowDot(at: ptT, color: tempColor, in: ctx)
            drawGlowDot(at: ptH, color: humColor, in: ctx)

            // 綜合多數值氣泡
            let timeStr = df.string(from: p.timestamp)
            let fullText = "\(timeStr)  ·  🌡️ \(String(format: "%.1f°C", p.temperature))   💧 \(String(format: "%.0f%%", p.humidity))   🔋 \(p.batteryPercent)%" as NSString

            let bubbleAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .bold),
                .foregroundColor: NSColor.white
            ]
            let textSz = fullText.size(withAttributes: bubbleAttrs)
            let bubbleW = textSz.width + 20
            let bubbleH: CGFloat = 26
            let bubbleX = max(graphRect.minX + 4, min(graphRect.maxX - bubbleW - 4, ptT.x - bubbleW / 2))
            let bubbleY = min(graphRect.maxY - bubbleH - 4, max(graphRect.minY + 4, max(ptT.y, ptH.y) + 14))
            let bubbleRect = NSRect(x: bubbleX, y: bubbleY, width: bubbleW, height: bubbleH)

            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -2), blur: 8, color: NSColor.black.withAlphaComponent(0.6).cgColor)
            let bubblePath = NSBezierPath(roundedRect: bubbleRect, xRadius: 7, yRadius: 7)
            NSColor(red: 0.12, green: 0.14, blue: 0.18, alpha: 0.95).setFill()
            bubblePath.fill()
            NSColor(white: 0.4, alpha: 0.8).setStroke()
            bubblePath.lineWidth = 1.0
            bubblePath.stroke()
            ctx.restoreGState()

            fullText.draw(at: NSPoint(x: bubbleX + 10, y: bubbleY + 5), withAttributes: bubbleAttrs)
        }
    }

    // MARK: - 單一指標圖表 (溫度 / 濕度 / 電壓)
    private func drawSingleMetricChart(in ctx: CGContext, graphRect: NSRect, df: DateFormatter) {
        let values: [Double]
        let mainColor: NSColor
        let gradientTopColor: NSColor

        switch dataType {
        case .temperature:
            values = points.map { $0.temperature }
            mainColor = NSColor(red: 1.0, green: 0.48, blue: 0.12, alpha: 1.0)
            gradientTopColor = NSColor(red: 1.0, green: 0.45, blue: 0.10, alpha: 0.35)
        case .humidity:
            values = points.map { $0.humidity }
            mainColor = NSColor(red: 0.05, green: 0.68, blue: 1.0, alpha: 1.0)
            gradientTopColor = NSColor(red: 0.05, green: 0.60, blue: 0.95, alpha: 0.35)
        case .voltage:
            values = points.map { $0.voltage }
            mainColor = NSColor(red: 0.10, green: 0.88, blue: 0.52, alpha: 1.0)
            gradientTopColor = NSColor(red: 0.10, green: 0.80, blue: 0.45, alpha: 0.35)
        case .overview:
            return
        }

        let rawMin = values.min() ?? 0.0
        let rawMax = values.max() ?? 1.0

        var minVal: Double
        var maxVal: Double

        switch dataType {
        case .voltage:
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
        case .overview:
            return
        }

        // 1. 水平參考線與 Y 軸標籤
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

        // 2. 底部 X 軸時間標籤
        drawXAxisTimestamps(in: ctx, graphRect: graphRect, df: df)

        // 3. 計算座標點
        var coords: [CGPoint] = []
        for i in 0..<points.count {
            let x = graphRect.minX + (CGFloat(i) / CGFloat(points.count - 1)) * graphRect.width
            let valRatio = CGFloat((values[i] - minVal) / (maxVal - minVal))
            let y = graphRect.minY + valRatio * graphRect.height
            coords.append(CGPoint(x: x, y: y))
        }

        // 4. 漸層區域
        drawSplineArea(coords: coords, minY: graphRect.minY, color: gradientTopColor, in: ctx)

        // 5. 主折線
        drawSplineLine(coords: coords, color: mainColor, lineWidth: 2.8, in: ctx)

        // 6. 懸停指示
        if let hIdx = hoveredPointIndex, hIdx < coords.count {
            let pt = coords[hIdx]
            let p = points[hIdx]

            ctx.setStrokeColor(NSColor(white: 1.0, alpha: 0.45).cgColor)
            ctx.setLineWidth(1.0)
            ctx.setLineDash(phase: 0, lengths: [3, 3])
            ctx.move(to: CGPoint(x: pt.x, y: graphRect.minY))
            ctx.addLine(to: CGPoint(x: pt.x, y: graphRect.maxY))
            ctx.strokePath()
            ctx.setLineDash(phase: 0, lengths: [])

            drawGlowDot(at: pt, color: mainColor, in: ctx)

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

    // MARK: - 輔助繪圖工具函數
    private func drawXAxisTimestamps(in ctx: CGContext, graphRect: NSRect, df: DateFormatter) {
        let labelAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .regular),
            .foregroundColor: NSColor(white: 0.55, alpha: 1.0)
        ]
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

                ctx.setStrokeColor(NSColor(white: 1.0, alpha: 0.15).cgColor)
                ctx.move(to: CGPoint(x: x, y: graphRect.minY))
                ctx.addLine(to: CGPoint(x: x, y: graphRect.minY - 4))
                ctx.strokePath()
            }
        }
    }

    private func drawSplineLine(coords: [CGPoint], color: NSColor, lineWidth: CGFloat, in ctx: CGContext) {
        guard !coords.isEmpty else { return }
        let linePath = makeSplinePath(coords: coords)

        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: 6.0, color: color.withAlphaComponent(0.5).cgColor)
        ctx.setStrokeColor(color.cgColor)
        ctx.setLineWidth(lineWidth)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.addPath(linePath)
        ctx.strokePath()
        ctx.restoreGState()
    }

    private func drawSplineArea(coords: [CGPoint], minY: CGFloat, color: NSColor, in ctx: CGContext) {
        guard let first = coords.first, let last = coords.last else { return }
        let linePath = makeSplinePath(coords: coords)

        let areaPath = CGMutablePath()
        areaPath.move(to: CGPoint(x: first.x, y: minY))
        areaPath.addPath(linePath)
        areaPath.addLine(to: CGPoint(x: last.x, y: minY))
        areaPath.closeSubpath()

        ctx.saveGState()
        ctx.addPath(areaPath)
        ctx.clip()

        let colors = [color.cgColor, NSColor(white: 0.1, alpha: 0.0).cgColor] as CFArray
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        if let gradient = CGGradient(colorsSpace: colorSpace, colors: colors, locations: [1.0, 0.0]) {
            ctx.drawLinearGradient(
                gradient,
                start: CGPoint(x: first.x, y: minY + 150),
                end: CGPoint(x: first.x, y: minY),
                options: []
            )
        }
        ctx.restoreGState()
    }

    private func makeSplinePath(coords: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        guard let first = coords.first else { return path }
        path.move(to: first)

        if coords.count == 2 {
            path.addLine(to: coords[1])
        } else if coords.count > 2 {
            for i in 0..<(coords.count - 1) {
                let p0 = (i > 0) ? coords[i - 1] : coords[i]
                let p1 = coords[i]
                let p2 = coords[i + 1]
                let p3 = (i + 2 < coords.count) ? coords[i + 2] : p2

                let cp1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6.0, y: p1.y + (p2.y - p0.y) / 6.0)
                let cp2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6.0, y: p2.y - (p3.y - p1.y) / 6.0)
                path.addCurve(to: p2, control1: cp1, control2: cp2)
            }
        }
        return path
    }

    private func drawGlowDot(at point: CGPoint, color: NSColor, in ctx: CGContext) {
        ctx.setFillColor(color.cgColor)
        ctx.fillEllipse(in: CGRect(x: point.x - 6, y: point.y - 6, width: 12, height: 12))
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fillEllipse(in: CGRect(x: point.x - 3, y: point.y - 3, width: 6, height: 6))
    }
}
