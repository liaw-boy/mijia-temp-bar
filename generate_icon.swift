import AppKit
import CoreGraphics
import Foundation

let iconsetPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset"
let fm = FileManager.default
try? fm.removeItem(atPath: iconsetPath)
try fm.createDirectory(atPath: iconsetPath, withIntermediateDirectories: true)

/// 深色圓角底 + 平滑趨勢曲線 + 發光端點的 AppIcon 渲染器
func renderIcon(pixelSize: Int) -> Data? {
    let s = CGFloat(pixelSize)
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixelSize,
        pixelsHigh: pixelSize,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ), let ctx = NSGraphicsContext(bitmapImageRep: rep)?.cgContext else {
        return nil
    }

    ctx.setAllowsAntialiasing(true)
    ctx.setShouldAntialias(true)
    let space = CGColorSpaceCreateDeviceRGB()

    let pad = s * 0.09
    let rect = CGRect(x: pad, y: pad, width: s - pad * 2, height: s - pad * 2)
    let corner = rect.width * 0.225
    let squircle = CGPath(roundedRect: rect, cornerWidth: corner, cornerHeight: corner, transform: nil)

    // 1. 外部投影
    ctx.saveGState()
    ctx.setShadow(
        offset: CGSize(width: 0, height: -s * 0.03),
        blur: s * 0.055,
        color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.35)
    )
    ctx.addPath(squircle)
    ctx.setFillColor(CGColor(red: 0.08, green: 0.09, blue: 0.13, alpha: 1))
    ctx.fillPath()
    ctx.restoreGState()

    // 2. 深色背景漸層
    ctx.saveGState()
    ctx.addPath(squircle)
    ctx.clip()
    let bg = CGGradient(colorsSpace: space, colors: [
        CGColor(red: 0.14, green: 0.16, blue: 0.22, alpha: 1),
        CGColor(red: 0.05, green: 0.06, blue: 0.09, alpha: 1)
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: rect.minX, y: rect.maxY), end: CGPoint(x: rect.maxX, y: rect.minY), options: [])

    // 3. 淡淡的水平參考線
    ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.06))
    ctx.setLineWidth(max(1, s * 0.004))
    for i in 1...3 {
        let gy = rect.minY + rect.height * (0.22 + 0.18 * CGFloat(i))
        ctx.move(to: CGPoint(x: rect.minX + rect.width * 0.12, y: gy))
        ctx.addLine(to: CGPoint(x: rect.maxX - rect.width * 0.12, y: gy))
    }
    ctx.strokePath()

    // 4. 趨勢曲線 (Catmull-Rom 轉 Bezier 的平滑折線)
    let ys: [CGFloat] = [0.30, 0.40, 0.34, 0.52, 0.47, 0.66, 0.78]
    let x0 = rect.minX + rect.width * 0.14
    let x1 = rect.maxX - rect.width * 0.14
    let pts: [CGPoint] = ys.enumerated().map { i, v in
        CGPoint(x: x0 + (x1 - x0) * CGFloat(i) / CGFloat(ys.count - 1), y: rect.minY + rect.height * v)
    }
    let curve = CGMutablePath()
    curve.move(to: pts[0])
    for i in 0..<(pts.count - 1) {
        let p0 = pts[max(i - 1, 0)], p1 = pts[i], p2 = pts[i + 1], p3 = pts[min(i + 2, pts.count - 1)]
        let c1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6)
        let c2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
        curve.addCurve(to: p2, control1: c1, control2: c2)
    }

    // 4.1 曲線下方的漸層填色
    ctx.saveGState()
    let area = CGMutablePath()
    area.addPath(curve)
    area.addLine(to: CGPoint(x: pts.last!.x, y: rect.minY + rect.height * 0.16))
    area.addLine(to: CGPoint(x: pts[0].x, y: rect.minY + rect.height * 0.16))
    area.closeSubpath()
    ctx.addPath(area)
    ctx.clip()
    let fill = CGGradient(colorsSpace: space, colors: [
        CGColor(red: 1.0, green: 0.48, blue: 0.12, alpha: 0.30),
        CGColor(red: 1.0, green: 0.48, blue: 0.12, alpha: 0.0)
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(fill, start: CGPoint(x: 0, y: rect.minY + rect.height * 0.8), end: CGPoint(x: 0, y: rect.minY + rect.height * 0.16), options: [])
    ctx.restoreGState()

    // 4.2 曲線本體：左藍 → 右橙，帶柔光
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: s * 0.03, color: CGColor(red: 1.0, green: 0.55, blue: 0.2, alpha: 0.7))
    ctx.setLineWidth(s * 0.045)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.addPath(curve)
    ctx.replacePathWithStrokedPath()
    ctx.clip()
    let stroke = CGGradient(colorsSpace: space, colors: [
        CGColor(red: 0.05, green: 0.68, blue: 1.0, alpha: 1),
        CGColor(red: 1.0, green: 0.48, blue: 0.12, alpha: 1)
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(stroke, start: CGPoint(x: x0, y: 0), end: CGPoint(x: x1, y: 0), options: [])
    ctx.restoreGState()

    // 5. 端點發光圓點
    let end = pts.last!
    let r = s * 0.05
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: s * 0.05, color: CGColor(red: 1.0, green: 0.55, blue: 0.2, alpha: 0.95))
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    ctx.fillEllipse(in: CGRect(x: end.x - r, y: end.y - r, width: r * 2, height: r * 2))
    ctx.restoreGState()

    ctx.restoreGState()

    // 6. 邊緣高光
    ctx.saveGState()
    ctx.addPath(squircle)
    ctx.setLineWidth(s * 0.008)
    ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.12))
    ctx.strokePath()
    ctx.restoreGState()

    guard let cgImage = ctx.makeImage() else { return nil }
    return NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:])
}

let sizes: [(String, Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

for (name, px) in sizes {
    let dest = URL(fileURLWithPath: iconsetPath).appendingPathComponent(name).path
    if let data = renderIcon(pixelSize: px) {
        try? data.write(to: URL(fileURLWithPath: dest))
    }
}

print("Generated app icons in \(iconsetPath)")
