import AppKit

/// 依 LYWSD03MMC 外觀繪製的即時示意圖：白色圓角機身 + 灰綠 LCD + 七段顯示，數值隨感測數據更新
final class DeviceView: NSView {
    var temperature: Double? { didSet { needsDisplay = true } }
    var humidity: Double? { didSet { needsDisplay = true } }
    var batteryPercent: Int? { didSet { needsDisplay = true } }

    private let ink = NSColor(red: 0.13, green: 0.15, blue: 0.14, alpha: 0.92)

    // 七段順序: a(上) b(右上) c(右下) d(下) e(左下) f(左上) g(中)
    private let segmentMap: [Character: [Bool]] = [
        "0": [true, true, true, true, true, true, false],
        "1": [false, true, true, false, false, false, false],
        "2": [true, true, false, true, true, false, true],
        "3": [true, true, true, true, false, false, true],
        "4": [false, true, true, false, false, true, true],
        "5": [true, false, true, true, false, true, true],
        "6": [true, false, true, true, true, true, true],
        "7": [true, true, true, false, false, false, false],
        "8": [true, true, true, true, true, true, true],
        "9": [true, true, true, true, false, true, true],
        "-": [false, false, false, false, false, false, true]
    ]

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let s = min(bounds.width, bounds.height)
        let body = NSRect(x: (bounds.width - s) / 2 + s * 0.04, y: (bounds.height - s) / 2 + s * 0.04, width: s * 0.92, height: s * 0.92)

        // 機身
        let bodyPath = NSBezierPath(roundedRect: body, xRadius: s * 0.2, yRadius: s * 0.2)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.03), blur: s * 0.06, color: NSColor.black.withAlphaComponent(0.35).cgColor)
        NSColor(white: 0.97, alpha: 1).setFill()
        bodyPath.fill()
        ctx.restoreGState()
        NSGradient(starting: .white, ending: NSColor(white: 0.9, alpha: 1))?.draw(in: bodyPath, angle: -90)
        NSColor(white: 0.78, alpha: 1).setStroke()
        bodyPath.lineWidth = max(0.5, s * 0.01)
        bodyPath.stroke()

        // LCD
        let lcd = body.insetBy(dx: body.width * 0.14, dy: body.height * 0.14)
        let lcdPath = NSBezierPath(roundedRect: lcd, xRadius: s * 0.04, yRadius: s * 0.04)
        NSGradient(starting: NSColor(red: 0.80, green: 0.83, blue: 0.80, alpha: 1),
                   ending: NSColor(red: 0.72, green: 0.76, blue: 0.72, alpha: 1))?.draw(in: lcdPath, angle: -90)
        NSColor(white: 0.45, alpha: 0.7).setStroke()
        lcdPath.lineWidth = max(0.5, s * 0.008)
        lcdPath.stroke()

        // 上排：溫度
        let tempText = temperature.map { String(format: "%.1f", $0) } ?? "--.-"
        let tempHeight = lcd.height * 0.36
        let tempArea = NSRect(x: lcd.minX + lcd.width * 0.08, y: lcd.minY + lcd.height * 0.44,
                              width: lcd.width * 0.72, height: tempHeight)
        drawSegments(tempText, in: tempArea, ctx: ctx)
        drawUnit("°C", at: NSPoint(x: tempArea.maxX + lcd.width * 0.02, y: tempArea.maxY - lcd.height * 0.13), size: lcd.height * 0.10)

        // 下排：顏文字 + 濕度
        let humText = humidity.map { String(format: "%.0f", $0) } ?? "--"
        let rowHeight = lcd.height * 0.22
        let row = NSRect(x: lcd.minX + lcd.width * 0.08, y: lcd.minY + lcd.height * 0.12, width: lcd.width * 0.84, height: rowHeight)
        drawText(face(for: humidity), in: NSRect(x: row.minX, y: row.minY, width: row.width * 0.46, height: rowHeight), size: lcd.height * 0.11)
        let humArea = NSRect(x: row.minX + row.width * 0.42, y: row.minY, width: row.width * 0.40, height: rowHeight)
        drawSegments(humText, in: humArea, ctx: ctx, alignRight: true)
        drawUnit("%", at: NSPoint(x: humArea.maxX + lcd.width * 0.03, y: row.minY), size: lcd.height * 0.09)

        // 電量偏低時顯示電池圖示 (與實機一致)
        if let bat = batteryPercent, bat <= 15 {
            let bw = lcd.width * 0.16, bh = lcd.height * 0.08
            let br = NSRect(x: lcd.minX + lcd.width * 0.08, y: lcd.maxY - lcd.height * 0.14, width: bw, height: bh)
            ink.setStroke()
            let bp = NSBezierPath(rect: br)
            bp.lineWidth = max(0.5, s * 0.01)
            bp.stroke()
            ink.setFill()
            NSBezierPath(rect: NSRect(x: br.minX, y: br.minY, width: br.width * 0.25, height: br.height)).fill()
        }
    }

    // MARK: - 顏文字：舒適 / 偏乾 / 偏濕
    private func face(for humidity: Double?) -> String {
        guard let h = humidity else { return "(-_-)" }
        if h < 40 { return "(-_-)" }
        if h > 65 { return "(>_<)" }
        return "(^_^)"
    }

    private func drawText(_ text: String, in rect: NSRect, size: CGFloat) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: max(4, size), weight: .semibold), .foregroundColor: ink
        ]
        let sz = (text as NSString).size(withAttributes: attrs)
        (text as NSString).draw(at: NSPoint(x: rect.minX, y: rect.midY - sz.height / 2), withAttributes: attrs)
    }

    private func drawUnit(_ text: String, at point: NSPoint, size: CGFloat) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: max(3, size), weight: .semibold), .foregroundColor: ink
        ]
        (text as NSString).draw(at: point, withAttributes: attrs)
    }

    // MARK: - 七段顯示
    /// 在 area 內由左(或右)排列字元，高度固定為 area.height，過寬時等比縮小
    private func drawSegments(_ text: String, in area: NSRect, ctx: CGContext, alignRight: Bool = false) {
        let chars = Array(text)
        func unitWidth(_ c: Character) -> CGFloat { c == "." ? 0.28 : 0.62 }
        let natural = chars.reduce(CGFloat(0)) { $0 + unitWidth($1) } * area.height
        let scale = min(1, (area.width - area.height * 0.12) / max(natural, 1))
        let h = area.height * scale
        let widthTotal = chars.reduce(CGFloat(0)) { $0 + unitWidth($1) } * h
        var x = alignRight ? area.maxX - widthTotal : area.minX
        let y = area.minY + (area.height - h) / 2
        let t = h * 0.14

        ctx.saveGState()
        // 實機 LCD 數字微傾斜
        let lean: CGFloat = 0.12
        let shear = CGAffineTransform(a: 1, b: 0, c: lean, d: 1, tx: -lean * y, ty: 0)
        for c in chars {
            let w = unitWidth(c) * h
            if c == "." {
                ink.setFill()
                let d = t * 1.1
                let dot = NSBezierPath(rect: NSRect(x: x + (w - d) / 2, y: y, width: d, height: d))
                dot.transform(using: AffineTransform(m11: shear.a, m12: shear.b, m21: shear.c, m22: shear.d, tX: shear.tx, tY: shear.ty))
                dot.fill()
            } else if let segs = segmentMap[c] {
                drawDigit(segs, origin: NSPoint(x: x, y: y), width: w * 0.86, height: h, thickness: t, shear: shear)
            }
            x += w
        }
        ctx.restoreGState()
    }

    private func drawDigit(_ segs: [Bool], origin o: NSPoint, width w: CGFloat, height h: CGFloat, thickness t: CGFloat, shear: CGAffineTransform) {
        let half = h / 2
        func hSeg(_ y: CGFloat) -> NSBezierPath {
            let p = NSBezierPath()
            let x0 = o.x + t * 0.6, x1 = o.x + w - t * 0.6
            p.move(to: NSPoint(x: x0, y: y))
            p.line(to: NSPoint(x: x0 + t * 0.5, y: y + t / 2))
            p.line(to: NSPoint(x: x1 - t * 0.5, y: y + t / 2))
            p.line(to: NSPoint(x: x1, y: y))
            p.line(to: NSPoint(x: x1 - t * 0.5, y: y - t / 2))
            p.line(to: NSPoint(x: x0 + t * 0.5, y: y - t / 2))
            p.close()
            return p
        }
        func vSeg(_ x: CGFloat, _ y0: CGFloat, _ y1: CGFloat) -> NSBezierPath {
            let p = NSBezierPath()
            p.move(to: NSPoint(x: x, y: y0 + t * 0.35))
            p.line(to: NSPoint(x: x + t / 2, y: y0 + t * 0.85))
            p.line(to: NSPoint(x: x + t / 2, y: y1 - t * 0.85))
            p.line(to: NSPoint(x: x, y: y1 - t * 0.35))
            p.line(to: NSPoint(x: x - t / 2, y: y1 - t * 0.85))
            p.line(to: NSPoint(x: x - t / 2, y: y0 + t * 0.85))
            p.close()
            return p
        }
        let top = o.y + h - t / 2, mid = o.y + half, bot = o.y + t / 2
        let left = o.x + t / 2, right = o.x + w - t / 2
        let paths = [
            hSeg(top), vSeg(right, mid, o.y + h), vSeg(right, o.y, mid),
            hSeg(bot), vSeg(left, o.y, mid), vSeg(left, mid, o.y + h), hSeg(mid)
        ]
        ink.setFill()
        let m = AffineTransform(m11: shear.a, m12: shear.b, m21: shear.c, m22: shear.d, tX: shear.tx, tY: shear.ty)
        for (i, p) in paths.enumerated() where segs[i] {
            p.transform(using: m)
            p.fill()
        }
    }
}
