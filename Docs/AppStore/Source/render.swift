import AppKit
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

private let canvasWidth = 1260
private let canvasHeight = 2736
private let canvasSize = NSSize(width: canvasWidth, height: canvasHeight)

private struct Slide {
    let headline: String
    let subtitle: String
    let badge: String?
    let source: String
    let secondarySource: String?
    let output: String
    let background: [NSColor]
    let accent: NSColor
}

private extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(
            calibratedRed: CGFloat((hex >> 16) & 0xff) / 255,
            green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255,
            alpha: alpha
        )
    }
}

private func topRect(_ x: CGFloat, _ top: CGFloat, _ width: CGFloat, _ height: CGFloat) -> NSRect {
    NSRect(x: x, y: CGFloat(canvasHeight) - top - height, width: width, height: height)
}

private func roundedPath(_ rect: NSRect, radius: CGFloat) -> NSBezierPath {
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
}

private func drawText(
    _ text: String,
    rect: NSRect,
    font: NSFont,
    color: NSColor,
    lineHeight: CGFloat? = nil,
    tracking: CGFloat = 0,
    alignment: NSTextAlignment = .left
) {
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = alignment
    paragraph.lineBreakMode = .byWordWrapping
    if let lineHeight {
        paragraph.minimumLineHeight = lineHeight
        paragraph.maximumLineHeight = lineHeight
    }

    let attributed = NSAttributedString(
        string: text,
        attributes: [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraph,
            .kern: tracking
        ]
    )
    attributed.draw(
        with: rect,
        options: [.usesLineFragmentOrigin, .usesFontLeading],
        context: nil
    )
}

private func textWidth(
    _ text: String,
    font: NSFont,
    tracking: CGFloat = 0
) -> CGFloat {
    ceil(
        NSAttributedString(
            string: text,
            attributes: [.font: font, .kern: tracking]
        ).size().width
    )
}

private func drawBadge(
    _ text: String,
    top: CGFloat,
    font: NSFont
) {
    let tracking: CGFloat = 4
    let height: CGFloat = 96
    let crownWidth: CGFloat = 42
    let spacing: CGFloat = 14
    let labelWidth = textWidth(text, font: font, tracking: tracking)
    let contentWidth = crownWidth + spacing + labelWidth
    let width = max(220, contentWidth + 56)
    let x: CGFloat = 48
    let rect = topRect(x, top, width, height)
    let path = roundedPath(rect, radius: height / 2)

    NSColor(hex: 0x171A2B).setFill()
    path.fill()

    let contentX = x + (width - contentWidth) / 2
    let crownRect = topRect(contentX, top + 23, crownWidth, 42)
    if let symbol = NSImage(
        systemSymbolName: "crown.fill",
        accessibilityDescription: nil
    )?.withSymbolConfiguration(
        NSImage.SymbolConfiguration(pointSize: 38, weight: .semibold)
    ) {
        let tintedSymbol = NSImage(size: crownRect.size)
        tintedSymbol.lockFocus()
        symbol.draw(
            in: NSRect(origin: .zero, size: crownRect.size),
            from: NSRect(origin: .zero, size: symbol.size),
            operation: .sourceOver,
            fraction: 1,
            respectFlipped: false,
            hints: [.interpolation: NSImageInterpolation.high]
        )
        NSGraphicsContext.current?.compositingOperation = .sourceIn
        NSColor(hex: 0xFBBF24).setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: crownRect.size)).fill()
        tintedSymbol.unlockFocus()
        tintedSymbol.draw(
            in: crownRect,
            from: NSRect(origin: .zero, size: tintedSymbol.size),
            operation: .sourceOver,
            fraction: 1,
            respectFlipped: false,
            hints: [.interpolation: NSImageInterpolation.high]
        )
    }

    drawText(
        text,
        rect: topRect(
            contentX + crownWidth + spacing,
            top + 9,
            labelWidth + 4,
            66
        ),
        font: font,
        color: NSColor.white,
        lineHeight: 64,
        tracking: tracking,
        alignment: .left
    )
}

private func drawImage(_ image: NSImage, in rect: NSRect) {
    image.draw(
        in: rect,
        from: NSRect(origin: .zero, size: image.size),
        operation: .sourceOver,
        fraction: 1,
        respectFlipped: false,
        hints: [.interpolation: NSImageInterpolation.high]
    )
}

private func loadFont(at url: URL, size: CGFloat) throws -> NSFont {
    guard let provider = CGDataProvider(url: url as CFURL),
          let graphicsFont = CGFont(provider) else {
        throw NSError(
            domain: "EagleInboxStoreRender",
            code: 7,
            userInfo: [NSLocalizedDescriptionKey: "Could not load font at \(url.path)"]
        )
    }
    return CTFontCreateWithGraphicsFont(graphicsFont, size, nil, nil) as NSFont
}

private func drawScreenshotCard(
    source: String,
    root: URL,
    outerRect: NSRect,
    outerRadius: CGFloat,
    rotation: CGFloat = 0,
    shadowBlur: CGFloat = 64,
    shadowOffset: CGFloat = -34
) throws {
    NSGraphicsContext.saveGraphicsState()

    if rotation != 0 {
        let transform = NSAffineTransform()
        transform.translateX(by: outerRect.midX, yBy: outerRect.midY)
        transform.rotate(byDegrees: rotation)
        transform.translateX(by: -outerRect.midX, yBy: -outerRect.midY)
        transform.concat()
    }

    let shadow = NSShadow()
    shadow.shadowColor = NSColor(hex: 0x0C2844, alpha: 0.22)
    shadow.shadowBlurRadius = shadowBlur
    shadow.shadowOffset = NSSize(width: 0, height: shadowOffset)
    shadow.set()
    let frameColor = NSColor(
        deviceWhite: CGFloat(0x11) / 255,
        alpha: 1
    )
    frameColor.setFill()
    roundedPath(outerRect, radius: outerRadius).fill()

    NSGraphicsContext.saveGraphicsState()
    NSShadow().set()
    let innerRect = outerRect.insetBy(dx: 15, dy: 15)
    roundedPath(innerRect, radius: outerRadius - 16).addClip()

    let sourceURL = root.appendingPathComponent(source)
    guard let screenshot = NSImage(contentsOf: sourceURL) else {
        throw NSError(
            domain: "EagleInboxStoreRender",
            code: 3,
            userInfo: [NSLocalizedDescriptionKey: "Could not load \(sourceURL.path)"]
        )
    }
    drawImage(screenshot, in: innerRect)
    NSGraphicsContext.restoreGraphicsState()

    frameColor.setStroke()
    let innerBorder = roundedPath(innerRect.insetBy(dx: 1, dy: 1), radius: outerRadius - 17)
    innerBorder.lineWidth = 2
    innerBorder.stroke()

    NSGraphicsContext.restoreGraphicsState()
}

private func render(
    slide: Slide,
    root: URL,
    headlineFont: NSFont,
    subtitleFont: NSFont,
    badgeFont: NSFont
) throws {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.noneSkipLast.rawValue
    guard let cgContext = CGContext(
        data: nil,
        width: canvasWidth,
        height: canvasHeight,
        bitsPerComponent: 8,
        bytesPerRow: canvasWidth * 4,
        space: colorSpace,
        bitmapInfo: bitmapInfo
    ) else {
        throw NSError(domain: "EagleInboxStoreRender", code: 1)
    }

    let context = NSGraphicsContext(cgContext: cgContext, flipped: false)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.imageInterpolation = .high

    let fullRect = NSRect(origin: .zero, size: canvasSize)
    NSGradient(colors: slide.background)?.draw(in: fullRect, angle: 120)

    let isSingleLineHeadline = !slide.headline.contains("\n")
    let headlineTop: CGFloat = isSingleLineHeadline ? 215 : 135
    let subtitleTop: CGFloat = isSingleLineHeadline ? 390 : 445

    drawText(
        slide.headline,
        rect: topRect(55, headlineTop, 1150, isSingleLineHeadline ? 160 : 310),
        font: headlineFont,
        color: .white,
        lineHeight: 146,
        tracking: -1.8,
        alignment: .center
    )

    let subtitleTracking: CGFloat = -0.2
    let subtitleWidth = min(
        textWidth(slide.subtitle, font: subtitleFont, tracking: subtitleTracking),
        1040
    )
    let subtitleGroupWidth = 16 + 18 + subtitleWidth
    let subtitleGroupX = (CGFloat(canvasWidth) - subtitleGroupWidth) / 2

    slide.accent.setFill()
    let subtitleBulletOpticalOffset: CGFloat = 5
    NSBezierPath(
        ovalIn: topRect(
            subtitleGroupX,
            subtitleTop + 23 + subtitleBulletOpticalOffset,
            16,
            16
        )
    ).fill()
    drawText(
        slide.subtitle,
        rect: topRect(subtitleGroupX + 34, subtitleTop, subtitleWidth + 4, 70),
        font: subtitleFont,
        color: NSColor.white.withAlphaComponent(0.84),
        tracking: subtitleTracking
    )

    if let badge = slide.badge {
        drawBadge(
            badge,
            top: 48,
            font: badgeFont
        )
    }

    if let secondarySource = slide.secondarySource {
        let cardWidth: CGFloat = 820
        let innerWidth = cardWidth - 30
        let cardHeight = innerWidth * 2736 / 1260 + 30

        try drawScreenshotCard(
            source: slide.source,
            root: root,
            outerRect: topRect(-60, 760, cardWidth, cardHeight),
            outerRadius: 82,
            rotation: -6.5,
            shadowBlur: 46,
            shadowOffset: -24
        )
        try drawScreenshotCard(
            source: secondarySource,
            root: root,
            outerRect: topRect(500, 620, cardWidth, cardHeight),
            outerRadius: 82,
            rotation: 6.5,
            shadowBlur: 46,
            shadowOffset: -24
        )
    } else {
        try drawScreenshotCard(
            source: slide.source,
            root: root,
            outerRect: topRect(165, 610, 930, 1984),
            outerRadius: 92
        )
    }

    NSGraphicsContext.restoreGraphicsState()

    guard let outputImage = cgContext.makeImage() else {
        throw NSError(domain: "EagleInboxStoreRender", code: 4)
    }
    let outputURL = root.appendingPathComponent(slide.output)
    guard let destination = CGImageDestinationCreateWithURL(
        outputURL as CFURL,
        UTType.png.identifier as CFString,
        1,
        nil
    ) else {
        throw NSError(domain: "EagleInboxStoreRender", code: 5)
    }
    CGImageDestinationAddImage(destination, outputImage, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw NSError(domain: "EagleInboxStoreRender", code: 6)
    }
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
let headlineFont = try loadFont(
    at: root.appendingPathComponent("Docs/AppStore/Source/Fonts/ZenMaruGothic-Black.ttf"),
    size: 126
)
let subtitleFont = try loadFont(
    at: root.appendingPathComponent("Docs/AppStore/Source/Fonts/ZenMaruGothic-Bold.ttf"),
    size: 42
)
let badgeFont = try loadFont(
    at: root.appendingPathComponent("Docs/AppStore/Source/Fonts/ZenMaruGothic-Black.ttf"),
    size: 40
)

private let vividBackground = [
    NSColor(hex: 0x007A8A),
    NSColor(hex: 0x1D4ED8),
    NSColor(hex: 0x5B21B6)
]

private let slides: [Slide] = [
    Slide(
        headline: "Straight to Eagle.",
        subtitle: "Pick your media and send it all together.",
        badge: nil,
        source: "Docs/Screenshots/upload-queue-photo-url.png",
        secondarySource: nil,
        output: "Docs/AppStore/Final/01-send-items.png",
        background: vividBackground,
        accent: NSColor(hex: 0x5EEAD4)
    ),
    Slide(
        headline: "Quick access from\nthe Share Sheet.",
        subtitle: "Share photos, files, and web pages.",
        badge: nil,
        source: "Docs/Screenshots/share-menu.png",
        secondarySource: nil,
        output: "Docs/AppStore/Final/02-share-sheet.png",
        background: vividBackground,
        accent: NSColor(hex: 0x7DD3FC)
    ),
    Slide(
        headline: "Tags and folders.",
        subtitle: "Apply Eagle tags and folders before sending.",
        badge: nil,
        source: "Docs/Screenshots/folders-selected-recent-all.png",
        secondarySource: "Docs/Screenshots/tags-selected.png",
        output: "Docs/AppStore/Final/03-organize-tags.png",
        background: vividBackground,
        accent: NSColor(hex: 0xFDBA74)
    ),
    Slide(
        headline: "Unlock more\nwith Pro.",
        subtitle: "Unlimited connections and every Shortcut action.",
        badge: nil,
        source: "Docs/Screenshots/pro-upgrade.png",
        secondarySource: nil,
        output: "Docs/AppStore/Final/04-pro-upgrade.png",
        background: vividBackground,
        accent: NSColor(hex: 0xFBBF24)
    ),
    Slide(
        headline: "One press.\nStraight to Eagle.",
        subtitle: "Run a Shortcut from the Action Button.",
        badge: "PRO",
        source: "Docs/Screenshots/action-button-shortcut.png",
        secondarySource: nil,
        output: "Docs/AppStore/Final/05-action-button.png",
        background: vividBackground,
        accent: NSColor(hex: 0xC4B5FD)
    )
]

private let requestedOutput = CommandLine.arguments.dropFirst().first
private let slidesToRender = requestedOutput.map { output in
    slides.filter { $0.output.hasSuffix(output) }
} ?? slides

guard !slidesToRender.isEmpty else {
    throw NSError(
        domain: "EagleInboxStoreRender",
        code: 8,
        userInfo: [NSLocalizedDescriptionKey: "No slide matches \(requestedOutput ?? "")"]
    )
}

for slide in slidesToRender {
    try render(
        slide: slide,
        root: root,
        headlineFont: headlineFont,
        subtitleFont: subtitleFont,
        badgeFont: badgeFont
    )
    print("Rendered \(slide.output)")
}
