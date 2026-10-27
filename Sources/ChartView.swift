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
    private var hoveredPoint: HistoryPoint?
    private var hoveredPointCoord: CGPoint?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor(red: 0.08, green: 0.09, blue: 0.12, alpha: 0.95).cgColor
        layer?.borderColor = NSColor(white: 1.0, alpha: 0.08).cgColor
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
        guard points.count >= 2,
              let startTime = points.first?.timestamp,
              let endTime = points.last?.timestamp else { return }

        let isOverview = (dataType == .overview)
        let graphRect = NSRect(x: 54, y: 34, width: bounds.width - (isOverview ? 104 : 76), height: bounds.height - 54)

        if graphRect.contains(location) {
            let totalSpan = max(60.0, endTime.timeIntervalSince(startTime))
            let hoverSec = Double((location.x - graphRect.minX) / graphRect.width) * totalSpan
            let targetTime = startTime.addingTimeInterval(hoverSec)

            // 尋找時間最接近的點
            var nearest = points[0]
            var minDiff = abs(points[0].timestamp.timeIntervalSince(targetTime))
            for p in points {
                let diff = abs(p.timestamp.timeIntervalSince(targetTime))
                if diff < minDiff {
                    minDiff = diff
                    nearest = p
                }
            }

            let ptX = graphRect.minX + CGFloat(nearest.timestamp.timeIntervalSince(startTime) / totalSpan) * graphRect.width
            hoveredPoint = nearest
            hoveredPointCoord = CGPoint(x: ptX, y: location.y)
            needsDisplay = true
            return
        }

        if hoveredPoint != nil {
            hoveredPoint = nil
            hoveredPointCoord = nil
            needsDisplay = true
        }
    }

    override func mouseExited(with event: NSEvent) {
        hoveredPoint = nil
        hoveredPointCoord = nil
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        let b = bounds
        let isOverview = (dataType == .overview)
        let graphRect = NSRect(x: 54, y: 34, width: b.width - (isOverview ? 104 : 76), height: b.height - 54)

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

        guard let startTime = points.first?.timestamp,
              let endTime = points.last?.timestamp else { return }
        let totalSpan = max(60.0, endTime.timeIntervalSince(startTime))

        // 繪製 X 軸整點時間刻度與垂直參考線
        drawXAxisGridAndLabels(in: ctx, graphRect: graphRect, startTime: startTime, endTime: endTime, totalSpan: totalSpan)

        if isOverview {
            drawOverviewMode(in: ctx, graphRect: graphRect, startTime: startTime, totalSpan: totalSpan)
        } else {
            drawSingleMode(in: ctx, graphRect: graphRect, startTime: startTime, totalSpan: totalSpan)
        }
    }

    // MARK: - 繪製 X 軸時間線 (基於真實時間分佈)
    private func drawXAxisGridAndLabels(in ctx: CGContext, graphRect: NSRect, startTime: Date, endTime: Date, totalSpan: TimeInterval) {
        let labelAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .regular),
            .foregroundColor: NSColor(white: 0.55, alpha: 1.0)
        ]
        let df = DateFormatter()
        df.dateFormat = "HH:mm"

        // 計算整點/半小時時間標記
        let stepInterval: TimeInterval
        if totalSpan > 3600 * 6 {
            stepInterval = 3600 * 2 // 2 小時一格
        } else if totalSpan > 3600 * 2 {
            stepInterval = 3600     // 1 小時一格
        } else if totalSpan > 1800 {
            stepInterval = 1800     // 30 分鐘一格
        } else {
            stepInterval = 600      // 10 分鐘一格
        }

        let cal = Calendar.current
        var current = startTime
        // 對齊到最近的整點時間
        let startComponents = cal.dateComponents([.year, .month, .day, .hour], from: startTime)
        if let baseDate = cal.date(from: startComponents) {
            current = baseDate
            while current < startTime {
                current = current.addingTimeInterval(stepInterval)
            }
        }

        while current <= endTime {
            let ratio = CGFloat(current.timeIntervalSince(startTime) / totalSpan)
            if ratio >= 0.05 && ratio <= 0.95 {
                let x = graphRect.minX + ratio * graphRect.width

                // 垂直虛線
                ctx.setStrokeColor(NSColor(white: 1.0, alpha: 0.06).cgColor)
                ctx.setLineWidth(1.0)
                ctx.setLineDash(phase: 0, lengths: [4, 4])
                ctx.move(to: CGPoint(x: x, y: graphRect.minY))
                ctx.addLine(to: CGPoint(x: x, y: graphRect.maxY))
                ctx.strokePath()

                // 時間文字
                let str = df.string(from: current) as NSString
                let size = str.size(withAttributes: labelAttrs)
                str.draw(at: NSPoint(x: x - size.width / 2, y: 12), withAttributes: labelAttrs)
            }
            current = current.addingTimeInterval(stepInterval)
        }
        ctx.setLineDash(phase: 0, lengths: [])

        // 始末兩端時間標記
        let startStr = df.string(from: startTime) as NSString
        startStr.draw(at: NSPoint(x: graphRect.minX, y: 12), withAttributes: labelAttrs)

        let endStr = df.string(from: endTime) as NSString
        let endSz = endStr.size(withAttributes: labelAttrs)
        endStr.draw(at: NSPoint(x: graphRect.maxX - endSz.width, y: 12), withAttributes: labelAttrs)
    }

    // MARK: - 綜合總覽模式 (雙 Y 軸)
    private func drawOverviewMode(in ctx: CGContext, graphRect: NSRect, startTime: Date, totalSpan: TimeInterval) {
        let temps = points.map { $0.temperature }
        let hums = points.map { $0.humidity }

        let rawMinT = temps.min() ?? 20.0
        let rawMaxT = temps.max() ?? 30.0
        let minT = floor(rawMinT * 2.0) / 2.0 - 0.5
        let maxT = ceil(rawMaxT * 2.0) / 2.0 + 0.5

        let rawMinH = hums.min() ?? 40.0
        let rawMaxH = hums.max() ?? 80.0
        let minH = max(0.0, floor(rawMinH / 5.0) * 5.0 - 5.0)
        let maxH = min(100.0, ceil(rawMaxH / 5.0) * 5.0 + 5.0)

        let tempColor = NSColor(red: 1.0, green: 0.48, blue: 0.12, alpha: 1.0) // 暖橙
        let humColor = NSColor(red: 0.05, green: 0.68, blue: 1.0, alpha: 1.0)   // 湛藍

        // 1. 水平參考線與雙 Y 軸刻度
        let gridLines = 4
        let labelAttrsT: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .bold),
            .foregroundColor: tempColor
        ]
        let labelAttrsH: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .bold),
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

            let valT = minT + Double(ratio) * (maxT - minT)
            let strT = String(format: "%.1f°", valT) as NSString
            let szT = strT.size(withAttributes: labelAttrsT)
            strT.draw(at: NSPoint(x: graphRect.minX - szT.width - 6, y: y - szT.height / 2), withAttributes: labelAttrsT)

            let valH = minH + Double(ratio) * (maxH - minH)
            let strH = String(format: "%.0f%%", valH) as NSString
            let szH = strH.size(withAttributes: labelAttrsH)
            strH.draw(at: NSPoint(x: graphRect.maxX + 6, y: y - szH.height / 2), withAttributes: labelAttrsH)
        }
        ctx.setLineDash(phase: 0, lengths: [])

        // 2. 基於真實時間計算座標點 (確保 X 嚴格單調遞增，永不折返交叉)
        var coordsT: [CGPoint] = []
        var coordsH: [CGPoint] = []

        for p in points {
            let xRatio = CGFloat(p.timestamp.timeIntervalSince(startTime) / totalSpan)
            let x = graphRect.minX + max(0.0, min(1.0, xRatio)) * graphRect.width

            let yT = graphRect.minY + CGFloat((p.temperature - minT) / (maxT - minT)) * graphRect.height
            let yH = graphRect.minY + CGFloat((p.humidity - minH) / (maxH - minH)) * graphRect.height

            coordsT.append(CGPoint(x: x, y: yT))
            coordsH.append(CGPoint(x: x, y: yH))
        }

        // 3. 繪製底部光暈與主折線
        drawGradientArea(coords: coordsT, minY: graphRect.minY, color: tempColor.withAlphaComponent(0.18), in: ctx)
        drawGradientArea(coords: coordsH, minY: graphRect.minY, color: humColor.withAlphaComponent(0.18), in: ctx)

        drawConnectedLine(coords: coordsT, color: tempColor, lineWidth: 2.4, in: ctx)
        drawConnectedLine(coords: coordsH, color: humColor, lineWidth: 2.4, in: ctx)

        // 4. 圖例
        let legY = graphRect.maxY + 4
        "● 溫度 (°C)".draw(at: NSPoint(x: graphRect.minX + 4, y: legY), withAttributes: [.font: NSFont.systemFont(ofSize: 11, weight: .bold), .foregroundColor: tempColor])
        "● 濕度 (%)".draw(at: NSPoint(x: graphRect.minX + 85, y: legY), withAttributes: [.font: NSFont.systemFont(ofSize: 11, weight: .bold), .foregroundColor: humColor])

        // 5. 懸停提示
        if let hPoint = hoveredPoint, hoveredPointCoord != nil {
            let xRatio = CGFloat(hPoint.timestamp.timeIntervalSince(startTime) / totalSpan)
            let x = graphRect.minX + max(0.0, min(1.0, xRatio)) * graphRect.width
            let yT = graphRect.minY + CGFloat((hPoint.temperature - minT) / (maxT - minT)) * graphRect.height
            let yH = graphRect.minY + CGFloat((hPoint.humidity - minH) / (maxH - minH)) * graphRect.height

            drawCrosshair(x: x, graphRect: graphRect, in: ctx)
            drawGlowDot(at: CGPoint(x: x, y: yT), color: tempColor, in: ctx)
            drawGlowDot(at: CGPoint(x: x, y: yH), color: humColor, in: ctx)

            let df = DateFormatter()
            df.dateFormat = "HH:mm:ss"
            let text = "\(df.string(from: hPoint.timestamp))  ·  🌡️ \(String(format: "%.1f°C", hPoint.temperature))   💧 \(String(format: "%.0f%%", hPoint.humidity))   🔋 \(hPoint.batteryPercent)%"
            drawHUDTooltip(text: text, at: CGPoint(x: x, y: max(yT, yH) + 14), graphRect: graphRect, in: ctx)
        }
    }

    // MARK: - 單一指標模式 (溫度 / 濕度 / 電壓)
    private func drawSingleMode(in ctx: CGContext, graphRect: NSRect, startTime: Date, totalSpan: TimeInterval) {
        let values: [Double]
        let mainColor: NSColor
        let valFormat: String

        switch dataType {
        case .temperature:
            values = points.map { $0.temperature }
            mainColor = NSColor(red: 1.0, green: 0.48, blue: 0.12, alpha: 1.0)
            valFormat = "%.1f°"
        case .humidity:
            values = points.map { $0.humidity }
            mainColor = NSColor(red: 0.05, green: 0.68, blue: 1.0, alpha: 1.0)
            valFormat = "%.0f%%"
        case .voltage:
            values = points.map { $0.voltage }
            mainColor = NSColor(red: 0.10, green: 0.88, blue: 0.52, alpha: 1.0)
            valFormat = "%.3fV"
        case .overview:
            return
        }

        let rawMin = values.min() ?? 0.0
        let rawMax = values.max() ?? 1.0

        let minVal: Double
        let maxVal: Double

        switch dataType {
        case .voltage:
            let span = max(0.02, rawMax - rawMin)
            let pad = span * 0.15
            minVal = rawMin - pad
            maxVal = rawMax + pad
        case .temperature:
            let span = max(0.8, rawMax - rawMin)
            let pad = span * 0.12
            minVal = rawMin - pad
            maxVal = rawMax + pad
        case .humidity:
            let span = max(3.0, rawMax - rawMin)
            let pad = span * 0.12
            minVal = max(0.0, rawMin - pad)
            maxVal = min(100.0, rawMax + pad)
        case .overview:
            return
        }

        // 1. 水平參考線與 Y 軸標籤
        let gridLines = 4
        let labelAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold),
            .foregroundColor: NSColor(white: 0.60, alpha: 1.0)
        ]

        for i in 0...gridLines {
            let ratio = CGFloat(i) / CGFloat(gridLines)
            let y = graphRect.minY + ratio * graphRect.height
            let val = minVal + Double(ratio) * (maxVal - minVal)

            ctx.setStrokeColor(NSColor(white: 1.0, alpha: 0.07).cgColor)
            ctx.setLineWidth(1.0)
            ctx.setLineDash(phase: 0, lengths: [4, 4])
            ctx.move(to: CGPoint(x: graphRect.minX, y: y))
            ctx.addLine(to: CGPoint(x: graphRect.maxX, y: y))
            ctx.strokePath()

            let str = String(format: valFormat, val) as NSString
            let sz = str.size(withAttributes: labelAttrs)
            str.draw(at: NSPoint(x: graphRect.minX - sz.width - 6, y: y - sz.height / 2), withAttributes: labelAttrs)
        }
        ctx.setLineDash(phase: 0, lengths: [])

        // 2. 基於時間計算座標
        var coords: [CGPoint] = []
        for (i, p) in points.enumerated() {
            let xRatio = CGFloat(p.timestamp.timeIntervalSince(startTime) / totalSpan)
            let x = graphRect.minX + max(0.0, min(1.0, xRatio)) * graphRect.width
            let val = values[i]
            let y = graphRect.minY + CGFloat((val - minVal) / (maxVal - minVal)) * graphRect.height
            coords.append(CGPoint(x: x, y: y))
        }

        // 3. 漸層區域與主線
        drawGradientArea(coords: coords, minY: graphRect.minY, color: mainColor.withAlphaComponent(0.25), in: ctx)
        drawConnectedLine(coords: coords, color: mainColor, lineWidth: 2.6, in: ctx)

        // 4. 懸停提示
        if let hPoint = hoveredPoint, let _ = hoveredPointCoord {
            let xRatio = CGFloat(hPoint.timestamp.timeIntervalSince(startTime) / totalSpan)
            let x = graphRect.minX + max(0.0, min(1.0, xRatio)) * graphRect.width

            let val: Double
            switch dataType {
            case .temperature: val = hPoint.temperature
            case .humidity: val = hPoint.humidity
            case .voltage: val = hPoint.voltage
            default: val = 0.0
            }

            let y = graphRect.minY + CGFloat((val - minVal) / (maxVal - minVal)) * graphRect.height
            let pt = CGPoint(x: x, y: y)

            drawCrosshair(x: x, graphRect: graphRect, in: ctx)
            drawGlowDot(at: pt, color: mainColor, in: ctx)

            let df = DateFormatter()
            df.dateFormat = "HH:mm:ss"
            let text: String
            switch dataType {
            case .temperature: text = "\(df.string(from: hPoint.timestamp))  ·  🌡️ \(String(format: "%.1f °C", val))"
            case .humidity: text = "\(df.string(from: hPoint.timestamp))  ·  💧 \(String(format: "%.0f %%", val))"
            case .voltage: text = "\(df.string(from: hPoint.timestamp))  ·  🔋 \(String(format: "%.3f V", val)) (\(hPoint.batteryPercent)%)"
            default: text = ""
            }

            drawHUDTooltip(text: text, at: CGPoint(x: x, y: y + 14), graphRect: graphRect, in: ctx)
        }
    }

    // MARK: - 精確折線與漸層渲染 (嚴格保證無自交或三角形黑塊 Bug)
    private func drawConnectedLine(coords: [CGPoint], color: NSColor, lineWidth: CGFloat, in ctx: CGContext) {
        guard coords.count >= 2 else { return }

        let path = CGMutablePath()
        path.move(to: coords[0])
        for pt in coords.dropFirst() {
            path.addLine(to: pt)
        }

        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: 5.0, color: color.withAlphaComponent(0.5).cgColor)
        ctx.setStrokeColor(color.cgColor)
        ctx.setLineWidth(lineWidth)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.addPath(path)
        ctx.strokePath()
        ctx.restoreGState()
    }

    private func drawGradientArea(coords: [CGPoint], minY: CGFloat, color: NSColor, in ctx: CGContext) {
        guard coords.count >= 2, let first = coords.first, let last = coords.last else { return }

        // 多邊形嚴格封閉：底角 -> 沿折線 -> 右底角 -> 閉合
        let areaPath = CGMutablePath()
        areaPath.move(to: CGPoint(x: first.x, y: minY))
        for pt in coords {
            areaPath.addLine(to: pt)
        }
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
                start: CGPoint(x: coords[0].x, y: minY + 180),
                end: CGPoint(x: coords[0].x, y: minY),
                options: []
            )
        }
        ctx.restoreGState()
    }

    private func drawCrosshair(x: CGFloat, graphRect: NSRect, in ctx: CGContext) {
        ctx.setStrokeColor(NSColor(white: 1.0, alpha: 0.35).cgColor)
        ctx.setLineWidth(1.0)
        ctx.setLineDash(phase: 0, lengths: [3, 3])
        ctx.move(to: CGPoint(x: x, y: graphRect.minY))
        ctx.addLine(to: CGPoint(x: x, y: graphRect.maxY))
        ctx.strokePath()
        ctx.setLineDash(phase: 0, lengths: [])
    }

    private func drawGlowDot(at point: CGPoint, color: NSColor, in ctx: CGContext) {
        ctx.setFillColor(color.cgColor)
        ctx.fillEllipse(in: CGRect(x: point.x - 5, y: point.y - 5, width: 10, height: 10))
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fillEllipse(in: CGRect(x: point.x - 2.5, y: point.y - 2.5, width: 5, height: 5))
    }

    private func drawHUDTooltip(text: String, at point: CGPoint, graphRect: NSRect, in ctx: CGContext) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .bold),
            .foregroundColor: NSColor.white
        ]
        let nsText = text as NSString
        let sz = nsText.size(withAttributes: attrs)
        let bubbleW = sz.width + 20
        let bubbleH: CGFloat = 26
        let x = max(graphRect.minX + 4, min(graphRect.maxX - bubbleW - 4, point.x - bubbleW / 2))
        let y = min(graphRect.maxY - bubbleH - 4, max(graphRect.minY + 4, point.y))
        let rect = NSRect(x: x, y: y, width: bubbleW, height: bubbleH)

        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -2), blur: 8, color: NSColor.black.withAlphaComponent(0.6).cgColor)
        let path = NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7)
        NSColor(red: 0.12, green: 0.14, blue: 0.18, alpha: 0.95).setFill()
        path.fill()
        NSColor(white: 1.0, alpha: 0.20).setStroke()
        path.lineWidth = 1.0
        path.stroke()
        ctx.restoreGState()

        nsText.draw(at: NSPoint(x: x + 10, y: y + 5), withAttributes: attrs)
    }
}
