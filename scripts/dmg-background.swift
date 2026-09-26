// Draws the disk image window background: the app on the left, Applications on
// the right and an arrow between them.
// Usage: swift scripts/dmg-background.swift <output.tiff> [style] [--preview]
// Styles: branded (default), dark, minimal. The TIFF holds 1x and 2x images so
// the background is sharp on Retina screens. --preview writes a PNG with the
// icons and labels drawn in, to judge the look without building a DMG.
// Geometry must match the Finder layout in scripts/build-dmg.sh.
import AppKit

let width: CGFloat = 660, height: CGFloat = 400
// Icon centres in Finder's top-left coordinates (build-dmg.sh uses the same numbers).
let appX: CGFloat = 170, appsX: CGFloat = 490, iconY: CGFloat = 185
// Where Finder centres a 13 pt label under a 128 pt icon, measured on macOS 26.
let labelY: CGFloat = 271

let arguments = CommandLine.arguments
let style = arguments.count > 2 && !arguments[2].hasPrefix("--") ? arguments[2] : "branded"
let preview = arguments.contains("--preview")
let dark = style == "dark"

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
}

func text(_ string: String, size: CGFloat, weight: NSFont.Weight, color: NSColor, top: CGFloat, kern: CGFloat = 0) {
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color,
        .paragraphStyle: paragraph, .kern: kern,
    ]
    (string as NSString).draw(in: NSRect(x: 0, y: height - top - size * 1.4, width: width, height: size * 1.4),
                              withAttributes: attributes)
}

func arrow(y: CGFloat, color stroke: NSColor, dashed: Bool, lineWidth: CGFloat, lift: CGFloat) {
    let start = NSPoint(x: appX + 86, y: y), end = NSPoint(x: appsX - 86, y: y)
    let path = NSBezierPath()
    path.move(to: start)
    path.curve(to: end, controlPoint1: NSPoint(x: start.x + 45, y: y + lift),
               controlPoint2: NSPoint(x: end.x - 45, y: y + lift))
    path.lineWidth = lineWidth
    path.lineCapStyle = .round
    if dashed { path.setLineDash([2, 9], count: 2, phase: 0) }
    stroke.setStroke()
    path.stroke()
    let angle = atan2(-lift, 45.0)
    let head = NSBezierPath()
    let size: CGFloat = 13
    for side in [-1.0, 1.0] {
        head.move(to: end)
        head.line(to: NSPoint(x: end.x - size * cos(angle + side * .pi / 5), y: end.y - size * sin(angle + side * .pi / 5)))
    }
    head.lineWidth = lineWidth
    head.lineCapStyle = .round
    head.lineJoinStyle = .round
    head.stroke()
}

func render(scale: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width * scale), pixelsHigh: Int(height * scale),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: width, height: height)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let bounds = NSRect(x: 0, y: 0, width: width, height: height)
    let y = height - iconY  // AppKit draws bottom-up

    switch style {
    case "minimal":
        color(0xf7f7f9).setFill(); bounds.fill()
        arrow(y: y + 6, color: color(0xa1a1a6), dashed: true, lineWidth: 3, lift: 0)
    case "branded":
        NSGradient(starting: color(0xffffff), ending: color(0xeef2f8))!.draw(in: bounds, angle: -90)
        text("Keysrs", size: 30, weight: .bold, color: color(0x1d1d1f), top: 28, kern: -0.6)
        text("Your AI plan usage and API keys, on your Mac.", size: 14, weight: .regular, color: color(0x6e6e73), top: 68)
        arrow(y: y + 4, color: color(0x0071e3), dashed: false, lineWidth: 4, lift: 26)
        text("Drag to Applications to install", size: 13, weight: .medium, color: color(0x6e6e73), top: 330)
    default:
        // Dark: the icon's own near-black, a faint blue glow behind the row.
        NSGradient(starting: color(0x1c1c20), ending: color(0x0e0e11))!.draw(in: bounds, angle: -90)
        NSGradient(starting: color(0x2d6cdf, 0.18), ending: color(0x2d6cdf, 0))!
            .draw(fromCenter: NSPoint(x: width / 2, y: y), radius: 0,
                  toCenter: NSPoint(x: width / 2, y: y), radius: 300, options: [])
        arrow(y: y + 6, color: color(0xffffff, 0.55), dashed: false, lineWidth: 3, lift: 22)
        text("Drag Keysrs to Applications", size: 13, weight: .medium, color: color(0xffffff, 0.45), top: 330)
        // Finder draws icon labels in black over a custom background, whatever the
        // appearance, so each label sits on a light pill to stay readable.
        for (x, labelWidth) in [(appX, 72.0), (appsX, 110.0)] {
            color(0xf2f2f5, 0.92).setFill()
            NSBezierPath(roundedRect: NSRect(x: x - labelWidth / 2, y: height - labelY - 11, width: labelWidth, height: 22),
                         xRadius: 11, yRadius: 11).fill()
        }
    }

    if preview {
        let labelColor = dark ? color(0xffffff) : color(0x1d1d1f)
        let keysrs = NSImage(contentsOfFile: "Assets/icon/png/keysrs-icon-512.png")!
        let apps = NSWorkspace.shared.icon(forFile: "/Applications")
        for (image, x, name) in [(keysrs, appX, "Keysrs"), (apps, appsX, "Applications")] {
            image.draw(in: NSRect(x: x - 64, y: y - 64 + 12, width: 128, height: 128))
            let paragraph = NSMutableParagraphStyle(); paragraph.alignment = .center
            (name as NSString).draw(in: NSRect(x: x - 80, y: y - 78, width: 160, height: 18), withAttributes: [
                .font: NSFont.systemFont(ofSize: 13), .foregroundColor: labelColor, .paragraphStyle: paragraph,
            ])
        }
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let output = URL(fileURLWithPath: arguments[1])
if preview {
    try render(scale: 2).representation(using: .png, properties: [:])!.write(to: output)
} else {
    let data = NSBitmapImageRep.tiffRepresentationOfImageReps(in: [render(scale: 1), render(scale: 2)],
                                                              using: .lzw, factor: 0)!
    try data.write(to: output)
}
