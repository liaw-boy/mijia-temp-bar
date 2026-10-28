import AppKit
import CoreGraphics
import Foundation

let iconsetPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset"
let fm = FileManager.default
try? fm.removeItem(atPath: iconsetPath)
try fm.createDirectory(atPath: iconsetPath, withIntermediateDirectories: true)

/// 擬真極簡小米溫濕度計 2 (LYWSD03MMC) Apple 原生質感 AppIcon 渲染器
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

    let pad = s * 0.09
    let rect = CGRect(x: pad, y: pad, width: s - pad * 2, height: s - pad * 2)
    let corner = rect.width * 0.225
    let squircle = CGPath(roundedRect: rect, cornerWidth: corner, cornerHeight: corner, transform: nil)

    let space = CGColorSpaceCreateDeviceRGB()

    // 1. 外部柔和立體投影 (Apple Standard App Elevation Shadow)
    ctx.saveGState()
    ctx.setShadow(
        offset: CGSize(width: 0, height: -s * 0.03),
        blur: s * 0.055,
        color: CGColor(red: 0.06, green: 0.10, blue: 0.18, alpha: 0.28)
    )

    // 2. 底板裁切
    ctx.addPath(squircle)
    ctx.clip()

    // 3. 背景漸層：清新典雅的現代 Apple 家居晨光柔和背景 (#F8FAFC -> #E2E8F0)
    let bgColors = [
        CGColor(red: 0.97, green: 0.98, blue: 1.0, alpha: 1.0),
        CGColor(red: 0.88, green: 0.91, blue: 0.95, alpha: 1.0)
    ] as CFArray
    let bgGrad = CGGradient(colorsSpace: space, colors: bgColors, locations: [0.0, 1.0])!
    ctx.drawLinearGradient(bgGrad, start: CGPoint(x: rect.minX, y: rect.maxY), end: CGPoint(x: rect.maxX, y: rect.minY), options: [])
    ctx.restoreGState()

    // 再次進入 squircle 區域繪製主體
    ctx.saveGState()
    ctx.addPath(squircle)
    ctx.clip()

    // 4. 頂部環境柔和高光與邊框倒角
    ctx.saveGState()
    ctx.addPath(squircle)
    ctx.setLineWidth(s * 0.012)
    ctx.setStrokeColor(CGColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 0.85))
    ctx.strokePath()
    ctx.restoreGState()

    // 5. 核心主體：擬真小米米家藍牙溫濕度計 2 (LYWSD03MMC) 純白方形機身
    let devSize = rect.width * 0.74
    let devRect = CGRect(
        x: (s - devSize) * 0.5,
        y: (s - devSize) * 0.5 - s * 0.005,
        width: devSize,
        height: devSize
    )
    let devRadius = devSize * 0.18
    let devPath = CGPath(roundedRect: devRect, cornerWidth: devRadius, cornerHeight: devRadius, transform: nil)

    // 5.1 機身立體陰影 (Ambient + Key Light Dropshadow)
    ctx.saveGState()
    ctx.setShadow(
        offset: CGSize(width: 0, height: -s * 0.022),
        blur: s * 0.04,
        color: CGColor(red: 0.12, green: 0.16, blue: 0.25, alpha: 0.22)
    )
    ctx.addPath(devPath)
    ctx.setFillColor(CGColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 1.0))
    ctx.fillPath()
    ctx.restoreGState()

    // 5.2 機身微幅啞光白漸層
    ctx.saveGState()
    ctx.addPath(devPath)
    ctx.clip()
    let bodyColors = [
        CGColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 1.0),
        CGColor(red: 0.95, green: 0.96, blue: 0.97, alpha: 1.0)
    ] as CFArray
    let bodyGrad = CGGradient(colorsSpace: space, colors: bodyColors, locations: [0.0, 1.0])!
    ctx.drawLinearGradient(bodyGrad, start: CGPoint(x: devRect.midX, y: devRect.maxY), end: CGPoint(x: devRect.midX, y: devRect.minY), options: [])

    // 機身邊框細線
    ctx.addPath(devPath)
    ctx.setLineWidth(s * 0.008)
    ctx.setStrokeColor(CGColor(red: 0.85, green: 0.88, blue: 0.92, alpha: 0.9))
    ctx.strokePath()
    ctx.restoreGState()

    // 5.3 機身頂部微型通氣感應孔 (LYWSD03MMC 特色傳感器開孔)
    let slotW = devSize * 0.18
    let slotH = devSize * 0.022
    let slotRect = CGRect(x: devRect.midX - slotW * 0.5, y: devRect.maxY - devSize * 0.055, width: slotW, height: slotH)
    let slotPath = CGPath(roundedRect: slotRect, cornerWidth: slotH * 0.5, cornerHeight: slotH * 0.5, transform: nil)
    ctx.saveGState()
    ctx.addPath(slotPath)
    ctx.setFillColor(CGColor(red: 0.82, green: 0.85, blue: 0.88, alpha: 0.9))
    ctx.fillPath()
    ctx.restoreGState()

    // 6. 正中央高擬真液晶顯示螢幕 (E-Ink / Segment LCD Display)
    let screenW = devSize * 0.76
    let screenH = devSize * 0.70
    let screenRect = CGRect(
        x: devRect.midX - screenW * 0.5,
        y: devRect.midY - screenH * 0.5 - devSize * 0.015,
        width: screenW,
        height: screenH
    )
    let screenRadius = devSize * 0.08
    let screenPath = CGPath(roundedRect: screenRect, cornerWidth: screenRadius, cornerHeight: screenRadius, transform: nil)

    // 螢幕微凹槽內陰影與背景
    ctx.saveGState()
    ctx.addPath(screenPath)
    // 液晶螢幕特有的清透淡灰綠色調 (#ECF1EC -> #E2E8E2)
    let lcdColors = [
        CGColor(red: 0.93, green: 0.95, blue: 0.93, alpha: 1.0),
        CGColor(red: 0.88, green: 0.91, blue: 0.88, alpha: 1.0)
    ] as CFArray
    let lcdGrad = CGGradient(colorsSpace: space, colors: lcdColors, locations: [0.0, 1.0])!
    ctx.drawLinearGradient(lcdGrad, start: CGPoint(x: screenRect.midX, y: screenRect.maxY), end: CGPoint(x: screenRect.midX, y: screenRect.minY), options: [])

    // 螢幕精緻內邊框
    ctx.addPath(screenPath)
    ctx.setLineWidth(s * 0.007)
    ctx.setStrokeColor(CGColor(red: 0.78, green: 0.82, blue: 0.80, alpha: 0.8))
    ctx.strokePath()
    ctx.restoreGState()

    // 7. 螢幕內部數據與圖示繪製 (LCD Digits & Icons)
    let textColor = NSColor(red: 0.12, green: 0.16, blue: 0.14, alpha: 0.92)

    // 7.1 上排溫度大字 (例如: 26.8°C)
    let tempStr = "26.8"
    let tempFontSize = screenH * 0.36
    let tempFont = NSFont.monospacedDigitSystemFont(ofSize: tempFontSize, weight: .bold)
    let tempAttrs: [NSAttributedString.Key: Any] = [
        .font: tempFont,
        .foregroundColor: textColor
    ]
    let tempSize = (tempStr as NSString).size(withAttributes: tempAttrs)
    let tempPoint = NSPoint(x: screenRect.minX + screenW * 0.12, y: screenRect.midY + screenH * 0.04)
    (tempStr as NSString).draw(at: tempPoint, withAttributes: tempAttrs)

    // 上排 °C 符號
    let unitStr = "°C"
    let unitFontSize = screenH * 0.18
    let unitFont = NSFont.systemFont(ofSize: unitFontSize, weight: .semibold)
    let unitAttrs: [NSAttributedString.Key: Any] = [
        .font: unitFont,
        .foregroundColor: textColor.withAlphaComponent(0.85)
    ]
    let unitPoint = NSPoint(x: tempPoint.x + tempSize.width + s * 0.006, y: tempPoint.y + tempFontSize * 0.35)
    (unitStr as NSString).draw(at: unitPoint, withAttributes: unitAttrs)

    // 7.2 下排濕度數值 (例如: 58%)
    let humStr = "58%"
    let humFontSize = screenH * 0.28
    let humFont = NSFont.monospacedDigitSystemFont(ofSize: humFontSize, weight: .semibold)
    let humAttrs: [NSAttributedString.Key: Any] = [
        .font: humFont,
        .foregroundColor: textColor
    ]
    let humSize = (humStr as NSString).size(withAttributes: humAttrs)
    let humPoint = NSPoint(x: screenRect.minX + screenW * 0.13, y: screenRect.minY + screenH * 0.10)
    (humStr as NSString).draw(at: humPoint, withAttributes: humAttrs)

    // 7.3 下排小米標誌性「舒適笑臉」圖示 😊 (Comfort Smile)
    let smileCenterX = humPoint.x + humSize.width + screenW * 0.16
    let smileCenterY = humPoint.y + humFontSize * 0.45
    let smileRadius = screenH * 0.11

    ctx.saveGState()
    ctx.setLineWidth(s * 0.010)
    ctx.setLineCap(.round)
    ctx.setStrokeColor(textColor.cgColor)

    // 眼睛兩點
    let eyeOffset = smileRadius * 0.45
    ctx.setFillColor(textColor.cgColor)
    ctx.fillEllipse(in: CGRect(x: smileCenterX - eyeOffset - s * 0.007, y: smileCenterY + smileRadius * 0.2, width: s * 0.014, height: s * 0.014))
    ctx.fillEllipse(in: CGRect(x: smileCenterX + eyeOffset - s * 0.007, y: smileCenterY + smileRadius * 0.2, width: s * 0.014, height: s * 0.014))

    // 弧形笑臉嘴巴
    ctx.addArc(center: CGPoint(x: smileCenterX, y: smileCenterY + smileRadius * 0.1), radius: smileRadius * 0.65, startAngle: .pi * 1.15, endAngle: .pi * 1.85, clockwise: false)
    ctx.strokePath()
    ctx.restoreGState()

    // 7.4 右上角精緻藍牙連線微標 (Bluetooth Symbol)
    let btCenter = CGPoint(x: screenRect.maxX - screenW * 0.14, y: screenRect.maxY - screenH * 0.18)
    ctx.saveGState()
    ctx.setLineWidth(s * 0.008)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.setStrokeColor(CGColor(red: 0.10, green: 0.55, blue: 0.95, alpha: 0.85))

    let bH = screenH * 0.14
    let bW = bH * 0.55
    ctx.move(to: CGPoint(x: btCenter.x, y: btCenter.y - bH * 0.5))
    ctx.addLine(to: CGPoint(x: btCenter.x, y: btCenter.y + bH * 0.5))
    ctx.addLine(to: CGPoint(x: btCenter.x + bW, y: btCenter.y + bH * 0.25))
    ctx.addLine(to: CGPoint(x: btCenter.x - bW * 0.7, y: btCenter.y - bH * 0.2))
    ctx.move(to: CGPoint(x: btCenter.x - bW * 0.7, y: btCenter.y + bH * 0.2))
    ctx.addLine(to: CGPoint(x: btCenter.x + bW, y: btCenter.y - bH * 0.25))
    ctx.addLine(to: CGPoint(x: btCenter.x, y: btCenter.y - bH * 0.5))
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

// 另外匯出一份 64x64 的高清硬體圖示到 Resources/device.png 供視窗標頭使用
let resDir = "Resources"
try? fm.createDirectory(atPath: resDir, withIntermediateDirectories: true)
if let devData = renderIcon(pixelSize: 128) {
    try? devData.write(to: URL(fileURLWithPath: "\(resDir)/device.png"))
}

print("Generated Apple-Minimalist Xiaomi LYWSD03MMC hardware icons in \(iconsetPath)")
