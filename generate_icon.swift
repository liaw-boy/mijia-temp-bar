import AppKit
import CoreGraphics
import Foundation

let iconsetPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset"
let fm = FileManager.default
try? fm.removeItem(atPath: iconsetPath)
try fm.createDirectory(atPath: iconsetPath, withIntermediateDirectories: true)

/// Google Stitch (Vibe Design / Tech Noir) AppIcon 渲染器
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

    let pad = s * 0.095
    let rect = CGRect(x: pad, y: pad, width: s - pad * 2, height: s - pad * 2)
    let corner = rect.width * 0.225
    let squircle = CGPath(roundedRect: rect, cornerWidth: corner, cornerHeight: corner, transform: nil)

    // 1. 外部柔和多層立體投影 (Stitch High-Elevation Shadow)
    ctx.saveGState()
    ctx.setShadow(
        offset: CGSize(width: 0, height: -s * 0.03),
        blur: s * 0.06,
        color: CGColor(red: 0.02, green: 0.03, blue: 0.08, alpha: 0.65)
    )

    // 2. 底板裁切
    ctx.addPath(squircle)
    ctx.clip()

    let space = CGColorSpaceCreateDeviceRGB()

    // 3. Google Stitch 經典黑曜石背景 (Tech Noir Dark Gradient: #080B11 -> #131B2A)
    let bgColors = [
        CGColor(red: 0.08, green: 0.11, blue: 0.18, alpha: 1.0),
        CGColor(red: 0.03, green: 0.04, blue: 0.07, alpha: 1.0)
    ] as CFArray
    let bgGrad = CGGradient(colorsSpace: space, colors: bgColors, locations: [0.0, 1.0])!
    ctx.drawLinearGradient(bgGrad, start: CGPoint(x: s * 0.1, y: s * 0.9), end: CGPoint(x: s * 0.9, y: s * 0.1), options: [])
    ctx.restoreGState()

    // 再次進入 squircle 區域繪製內容
    ctx.saveGState()
    ctx.addPath(squircle)
    ctx.clip()

    // 4. Stitch 畫布微型點陣網格紋理 (Subtle AI Canvas Dot Matrix)
    ctx.saveGState()
    let gridCount = 9
    let step = rect.width / CGFloat(gridCount + 1)
    for xIdx in 1...gridCount {
        for yIdx in 1...gridCount {
            let ptX = rect.minX + CGFloat(xIdx) * step
            let ptY = rect.minY + CGFloat(yIdx) * step
            // 距離中心越遠越淡
            let dist = hypot(ptX - s * 0.5, ptY - s * 0.5) / (s * 0.4)
            let alpha = max(0.0, (1.0 - dist) * 0.10)
            ctx.setFillColor(CGColor(red: 0.5, green: 0.65, blue: 0.9, alpha: alpha))
            ctx.addArc(center: CGPoint(x: ptX, y: ptY), radius: s * 0.005, startAngle: 0, endAngle: .pi * 2, clockwise: true)
            ctx.fillPath()
        }
    }
    ctx.restoreGState()

    // 5. Google Stitch 標誌性「電光藍紫 ＋ 暖橙」雙向霓虹光暈 (Vibe Ambient Neon Glow)
    // 左側橙粉暖光暈 (Temperature Thermal Glow)
    let thermalGlow = [
        CGColor(red: 1.0, green: 0.35, blue: 0.20, alpha: 0.35),
        CGColor(red: 1.0, green: 0.20, blue: 0.40, alpha: 0.0)
    ] as CFArray
    if let g1 = CGGradient(colorsSpace: space, colors: thermalGlow, locations: [0.0, 1.0]) {
        ctx.drawRadialGradient(g1, startCenter: CGPoint(x: s * 0.35, y: s * 0.62), startRadius: 0, endCenter: CGPoint(x: s * 0.35, y: s * 0.62), endRadius: s * 0.38, options: [])
    }
    // 右側電光青藍光暈 (Humidity Cyan Glow)
    let cyanGlow = [
        CGColor(red: 0.0, green: 0.85, blue: 1.0, alpha: 0.30),
        CGColor(red: 0.25, green: 0.40, blue: 1.0, alpha: 0.0)
    ] as CFArray
    if let g2 = CGGradient(colorsSpace: space, colors: cyanGlow, locations: [0.0, 1.0]) {
        ctx.drawRadialGradient(g2, startCenter: CGPoint(x: s * 0.65, y: s * 0.40), startRadius: 0, endCenter: CGPoint(x: s * 0.65, y: s * 0.40), endRadius: s * 0.40, options: [])
    }

    // 6. 核心設計：Stitch 招牌「懸浮氣候膠囊卡片 (Floating Vibe Capsule)」
    let cardW = s * 0.52
    let cardH = s * 0.52
    let cardRect = CGRect(x: (s - cardW) * 0.5, y: (s - cardH) * 0.5 - s * 0.01, width: cardW, height: cardH)
    let cardRadius = cardW * 0.35
    let cardPath = CGPath(roundedRect: cardRect, cornerWidth: cardRadius, cornerHeight: cardRadius, transform: nil)

    // 卡片柔和暗部投影
    ctx.saveGState()
    ctx.setShadow(
        offset: CGSize(width: 0, height: -s * 0.02),
        blur: s * 0.045,
        color: CGColor(red: 0.0, green: 0.0, blue: 0.0, alpha: 0.55)
    )
    // 毛玻璃卡片半透明底色 (Glassmorphism card)
    ctx.addPath(cardPath)
    ctx.setFillColor(CGColor(red: 0.12, green: 0.15, blue: 0.24, alpha: 0.75))
    ctx.fillPath()
    ctx.restoreGState()

    // 卡片精緻邊框 (Stitch Signature Gradient Border Stroke)
    ctx.saveGState()
    ctx.addPath(cardPath)
    ctx.setLineWidth(s * 0.016)
    ctx.setStrokeColor(CGColor(red: 0.35, green: 0.60, blue: 1.0, alpha: 0.35))
    ctx.strokePath()
    ctx.restoreGState()

    // 7. 卡片內部核心視覺：Stitch 風格的雙環動態指標 (Dual-Loop Climate Indicator)
    let iconCenter = CGPoint(x: cardRect.midX, y: cardRect.midY)

    // 7.1 左側熱能環（象徵溫度：橙紅弧線）
    ctx.saveGState()
    ctx.setLineWidth(s * 0.048)
    ctx.setLineCap(.round)
    ctx.setStrokeColor(CGColor(red: 1.0, green: 0.40, blue: 0.22, alpha: 0.95))
    ctx.addArc(
        center: CGPoint(x: iconCenter.x - s * 0.04, y: iconCenter.y + s * 0.03),
        radius: s * 0.13,
        startAngle: .pi * 0.2,
        endAngle: .pi * 1.5,
        clockwise: false
    )
    ctx.strokePath()
    ctx.restoreGState()

    // 7.2 右側水漾環（象徵濕度：電光青弧線）
    ctx.saveGState()
    ctx.setLineWidth(s * 0.048)
    ctx.setLineCap(.round)
    ctx.setStrokeColor(CGColor(red: 0.05, green: 0.88, blue: 0.98, alpha: 0.95))
    ctx.addArc(
        center: CGPoint(x: iconCenter.x + s * 0.04, y: iconCenter.y - s * 0.03),
        radius: s * 0.13,
        startAngle: .pi * 1.2,
        endAngle: .pi * 0.5,
        clockwise: false
    )
    ctx.strokePath()
    ctx.restoreGState()

    // 7.3 中心平衡光點 (Stitch Balance Nucleus)
    ctx.saveGState()
    ctx.setFillColor(CGColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 0.95))
    ctx.setShadow(offset: .zero, blur: s * 0.02, color: CGColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 0.8))
    ctx.addArc(center: iconCenter, radius: s * 0.022, startAngle: 0, endAngle: .pi * 2, clockwise: true)
    ctx.fillPath()
    ctx.restoreGState()

    // 8. Stitch AI 介面角落十字標記 (Tech Crosshairs)
    let markLen = s * 0.022
    let markInset = s * 0.16
    let corners = [
        CGPoint(x: rect.minX + markInset, y: rect.minY + markInset),
        CGPoint(x: rect.maxX - markInset, y: rect.minY + markInset),
        CGPoint(x: rect.minX + markInset, y: rect.maxY - markInset),
        CGPoint(x: rect.maxX - markInset, y: rect.maxY - markInset)
    ]
    ctx.saveGState()
    ctx.setStrokeColor(CGColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 0.22))
    ctx.setLineWidth(s * 0.008)
    for c in corners {
        ctx.move(to: CGPoint(x: c.x - markLen * 0.5, y: c.y))
        ctx.addLine(to: CGPoint(x: c.x + markLen * 0.5, y: c.y))
        ctx.move(to: CGPoint(x: c.x, y: c.y - markLen * 0.5))
        ctx.addLine(to: CGPoint(x: c.x, y: c.y + markLen * 0.5))
    }
    ctx.strokePath()
    ctx.restoreGState()

    // 9. Apple 頂層極細邊緣倒角光 (Bezel Edge Highlight)
    ctx.saveGState()
    ctx.addPath(squircle)
    ctx.setLineWidth(s * 0.014)
    ctx.setStrokeColor(CGColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 0.18))
    ctx.strokePath()
    ctx.restoreGState()

    ctx.restoreGState()

    guard let cgImage = ctx.makeImage() else { return nil }
    let finalRep = NSBitmapImageRep(cgImage: cgImage)
    return finalRep.representation(using: .png, properties: [:])
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
print("Generated Google Stitch Vibe Design icons in \(iconsetPath)")
