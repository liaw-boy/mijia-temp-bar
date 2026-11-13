import AppKit

enum DisplayStyle: Int {
    case statsBadge = 0 // 雙行微型膠囊風格 (TMP / HUM 雙行對齊)
    case stacked = 1    // 純數字雙行堆疊 (26.1° / 63%)
    case horizontal = 2 // 橫向完整 (🌡️ 26.1°C  💧 65%)
    case tempOnly = 3   // 僅溫度 (🌡️ 26.1°C)
    case compact = 4    // 緊湊單行 (26.1° 65%)
}

/// 狀態列圖示繪製：數值為 nil (主裝置連不到) 時顯示 --
enum StatusItemRenderer {
    /// 套用到狀態列按鈕
    static func apply(style: DisplayStyle, temp: Double?, hum: Double?, to button: NSStatusBarButton) {
        let t = DisplayRules.formatTemp(temp)
        let h = DisplayRules.formatHum(hum)
        switch style {
        case .statsBadge:
            button.title = ""
            button.image = makeStatsBadgeImage(temp: "\(t)°", hum: "\(h)%")
            button.imagePosition = .imageOnly
        case .stacked:
            button.title = ""
            button.image = makeStackedImage(temp: "\(t)°", hum: "\(h)%")
            button.imagePosition = .imageOnly
        case .horizontal:
            button.image = nil
            button.title = "🌡️ \(t)°C  💧 \(h)%"
        case .tempOnly:
            button.image = nil
            button.title = "🌡️ \(t)°C"
        case .compact:
            button.image = nil
            button.title = "\(t)° \(h)%"
        }
    }

    /// 產生 [TMP] / [HUM] 雙行微型膠囊影像 (上下完全貼滿 24pt 版)
    static func makeStatsBadgeImage(temp topVal: String, hum bottomVal: String) -> NSImage {
        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let textColor = isDark ? NSColor.white : NSColor(white: 0.1, alpha: 1.0)

        // 徹底吃滿 Mac 狀態列 24pt 高度：數字 11.2pt 粗黑體、膠囊字 8.2pt 超粗黑體
        let badgeAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 8.2, weight: .black),
            .foregroundColor: NSColor.white
        ]
        let valAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11.2, weight: .bold),
            .foregroundColor: textColor
        ]
        let maxValWidth = max((topVal as NSString).size(withAttributes: valAttrs).width,
                              (bottomVal as NSString).size(withAttributes: valAttrs).width)

        // 膠囊尺寸：高度 10.5pt，完全貼滿上下半部
        let badgeWidth: CGFloat = 25.0, badgeHeight: CGFloat = 10.5, badgeRadius: CGFloat = 2.5, gap: CGFloat = 4.5
        let totalWidth = badgeWidth + gap + maxValWidth + 2.0

        let image = NSImage(size: NSSize(width: totalWidth, height: 24.0), flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            let rows: [(String, String, CGFloat, CGColor)] = [
                ("TMP", topVal, 12.5, CGColor(red: 0.92, green: 0.35, blue: 0.10, alpha: 1.0)),   // 熱能暖橙 #EA580C
                ("HUM", bottomVal, 1.0, CGColor(red: 0.05, green: 0.55, blue: 0.88, alpha: 1.0))  // 濕度湛藍 #0284C7
            ]
            for (label, value, y, color) in rows {
                let rect = CGRect(x: 1.0, y: y, width: badgeWidth, height: badgeHeight)
                ctx.setFillColor(color)
                ctx.addPath(CGPath(roundedRect: rect, cornerWidth: badgeRadius, cornerHeight: badgeRadius, transform: nil))
                ctx.fillPath()
                let labelSize = (label as NSString).size(withAttributes: badgeAttrs)
                (label as NSString).draw(at: CGPoint(x: rect.midX - labelSize.width * 0.5,
                                                     y: rect.midY - labelSize.height * 0.5 + 0.5), withAttributes: badgeAttrs)
                (value as NSString).draw(at: CGPoint(x: rect.maxX + gap, y: y - 1.2), withAttributes: valAttrs)
            }
            return true
        }
        image.isTemplate = false
        return image
    }

    /// 純數字雙行堆疊 (上下吃滿版)
    static func makeStackedImage(temp topText: String, hum bottomText: String) -> NSImage {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11.0, weight: .bold),
            .foregroundColor: NSColor.black
        ]
        let sizeTop = (topText as NSString).size(withAttributes: attrs)
        let sizeBottom = (bottomText as NSString).size(withAttributes: attrs)
        let totalWidth = ceil(max(sizeTop.width, sizeBottom.width)) + 6.0

        let image = NSImage(size: NSSize(width: totalWidth, height: 24.0), flipped: false) { _ in
            (topText as NSString).draw(at: NSPoint(x: (totalWidth - sizeTop.width) / 2.0, y: 12.5), withAttributes: attrs)
            (bottomText as NSString).draw(at: NSPoint(x: (totalWidth - sizeBottom.width) / 2.0, y: 1.0), withAttributes: attrs)
            return true
        }
        image.isTemplate = true
        return image
    }
}
