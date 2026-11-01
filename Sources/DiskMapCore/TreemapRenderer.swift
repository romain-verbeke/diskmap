import CoreGraphics
import CoreText
import Foundation

public enum ColorMode: String, CaseIterable, Sendable {
    case fileType = "File type"
    case lastModified = "Last modified"
}

public struct RGB: Sendable {
    public let red, green, blue: CGFloat

    init(hex: UInt32) {
        red = CGFloat((hex >> 16) & 0xFF) / 255
        green = CGFloat((hex >> 8) & 0xFF) / 255
        blue = CGFloat(hex & 0xFF) / 255
    }

    public var cgColor: CGColor { CGColor(red: red, green: green, blue: blue, alpha: 1) }
}

public enum Palette {
    private static let darkText = RGB(hex: 0x14181F)
    private static let lightText = RGB(hex: 0xFFFFFF)

    public static func color(for category: FileCategory) -> RGB {
        switch category {
        case .other: RGB(hex: 0xC4C7CC)
        case .video: RGB(hex: 0x5B8DEF)
        case .audio: RGB(hex: 0x6CC6E8)
        case .images: RGB(hex: 0x4DB6A5)
        case .documents: RGB(hex: 0x8FCB7E)
        case .archives: RGB(hex: 0xB9C46A)
        case .developer: RGB(hex: 0xF2A33A)
        case .apps: RGB(hex: 0xA98BE8)
        case .cache: RGB(hex: 0xE8768A)
        case .system: RGB(hex: 0x9AA3AE)
        }
    }

    public static let ageBuckets: [(label: String, maxDays: Double, color: RGB, text: RGB)] = [
        ("This week", 7, RGB(hex: 0xDBE8FA), darkText),
        ("This month", 31, RGB(hex: 0x9DC1F0), darkText),
        ("This year", 365, RGB(hex: 0x5B8DEF), darkText),
        ("Over a year ago", .infinity, RGB(hex: 0x1F4E9E), lightText),
    ]

    static func style(for cell: TreemapCell, mode: ColorMode, now: TimeInterval) -> (fill: RGB, text: RGB) {
        switch mode {
        case .fileType:
            return (color(for: cell.category), darkText)
        case .lastModified:
            let days = (now - TimeInterval(cell.modTime)) / 86_400
            let bucket = ageBuckets.first { days <= $0.maxDays } ?? ageBuckets[ageBuckets.count - 1]
            return (bucket.color, bucket.text)
        }
    }
}

/// Draws cells with Core Graphics. Shared by the app and the command-line tool.
public enum TreemapRenderer {
    public struct Style: Sendable {
        public var colorMode: ColorMode = .fileType
        public var isDark = false
        public var selected: NodeID?
        public var hovered: Int?
        /// Scales cell rectangles while a new layout is being computed during a resize.
        public var scaleX: CGFloat = 1
        public var scaleY: CGFloat = 1

        public init() {}
    }

    /// Expects a context whose origin is at the top left, with y increasing downward.
    public static func draw(_ cells: [TreemapCell], in context: CGContext, dirtyRect: CGRect, style: Style) {
        let frameColor = style.isDark ? RGB(hex: 0x2B2B2E) : RGB(hex: 0xF2F2F4)
        let headerColor = style.isDark ? RGB(hex: 0x3A3A3E) : RGB(hex: 0xE2E2E6)
        let headerText = style.isDark ? RGB(hex: 0xF2F2F4) : RGB(hex: 0x1D1D1F)
        let selection = style.isDark ? RGB(hex: 0xFFFFFF) : RGB(hex: 0x14181F)
        let now = Date().timeIntervalSince1970
        let boldFont = CTFontCreateUIFontForLanguage(.emphasizedSystem, 11, nil)
            ?? CTFontCreateWithName("Helvetica-Bold" as CFString, 11, nil)
        let font = CTFontCreateUIFontForLanguage(.system, 10, nil)
            ?? CTFontCreateWithName("Helvetica" as CFString, 10, nil)

        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)

        for (index, cell) in cells.enumerated() {
            let rect = CGRect(
                x: cell.rect.minX * style.scaleX, y: cell.rect.minY * style.scaleY,
                width: cell.rect.width * style.scaleX, height: cell.rect.height * style.scaleY)
            guard rect.intersects(dirtyRect) else { continue }

            switch cell.kind {
            case .frame:
                context.setFillColor(frameColor.cgColor)
                context.fill(rect)
            case .header:
                context.setFillColor(headerColor.cgColor)
                context.fill(rect)
                if rect.width > 30 {
                    drawLabel(cell.name, size: formatBytes(cell.size), font: boldFont, sizeFont: font, in: rect, color: headerText, context: context)
                }
            case .tile, .aggregate:
                let colors = Palette.style(for: cell, mode: style.colorMode, now: now)
                context.setFillColor(colors.fill.cgColor)
                context.fill(rect)
                if !cell.name.isEmpty && rect.width >= 40 && rect.height >= 16 {
                    if rect.height >= 30 {
                        drawStacked(cell.name, size: formatBytes(cell.size), font: boldFont, sizeFont: font, in: rect, color: colors.text, context: context)
                    } else {
                        drawLine(cell.name, font: font, at: CGPoint(x: rect.minX + 4, y: rect.midY + 3.5), maxWidth: rect.width - 8, color: colors.text, context: context)
                    }
                }
            }

            if style.hovered == index {
                context.setFillColor(CGColor(gray: 1, alpha: 0.22))
                context.fill(rect)
            }
            if cell.kind != .frame, cell.kind != .aggregate, cell.node == style.selected {
                context.setStrokeColor(selection.cgColor)
                context.setLineWidth(2)
                context.stroke(rect.insetBy(dx: 1, dy: 1))
            }
        }
    }

    private static func drawStacked(_ name: String, size: String, font: CTFont, sizeFont: CTFont, in rect: CGRect, color: RGB, context: CGContext) {
        drawLine(name, font: font, at: CGPoint(x: rect.minX + 5, y: rect.minY + 14), maxWidth: rect.width - 10, color: color, context: context)
        drawLine(size, font: sizeFont, at: CGPoint(x: rect.minX + 5, y: rect.minY + 26), maxWidth: rect.width - 10, color: color, context: context)
    }

    private static func drawLabel(_ name: String, size: String, font: CTFont, sizeFont: CTFont, in rect: CGRect, color: RGB, context: CGContext) {
        let baseline = rect.minY + 13
        let sizeWidth: CGFloat = rect.width > 110 ? 58 : 0
        if sizeWidth > 0 {
            let line = makeLine(size, font: sizeFont, color: color)
            let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
            draw(line, at: CGPoint(x: rect.maxX - width - 5, y: baseline), context: context)
        }
        drawLine(name, font: font, at: CGPoint(x: rect.minX + 5, y: baseline), maxWidth: rect.width - 10 - sizeWidth, color: color, context: context)
    }

    private static func makeLine(_ text: String, font: CTFont, color: RGB) -> CTLine {
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color.cgColor,
        ]
        return CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
    }

    private static func drawLine(_ text: String, font: CTFont, at point: CGPoint, maxWidth: CGFloat, color: RGB, context: CGContext) {
        guard maxWidth > 8 else { return }
        var line = makeLine(text, font: font, color: color)
        if CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)) > maxWidth {
            let ellipsis = makeLine("…", font: font, color: color)
            guard let truncated = CTLineCreateTruncatedLine(line, Double(maxWidth), .end, ellipsis) else { return }
            line = truncated
        }
        draw(line, at: point, context: context)
    }

    private static func draw(_ line: CTLine, at point: CGPoint, context: CGContext) {
        context.textPosition = point
        CTLineDraw(line, context)
    }
}
