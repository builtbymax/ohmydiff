import AppKit

// Renders the app icon at 1024 pt, then writes every size the asset catalog lists.
// Usage: swift scripts/make-icon.swift ohmydiff/Assets.xcassets/AppIcon.appiconset
let output = URL(fileURLWithPath: CommandLine.arguments[1])

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func drawIcon(in context: CGContext) {
    // macOS icon grid: an 824 pt body centered in 1024, leaving room for the shadow.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = .black.withAlphaComponent(0.35)
    shadow.shadowBlurRadius = 28
    shadow.shadowOffset = NSSize(width: 0, height: -12)
    shadow.set()
    color(0x1B1E33).setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.saveGraphicsState()
    shape.addClip()
    NSGradient(starting: color(0x2E3354), ending: color(0x151729))!.draw(in: body, angle: -90)

    // Diff lines, top to bottom: context, deletion, addition, addition, context.
    let rows: [(tint: NSColor?, mark: NSColor?, width: CGFloat)] = [
        (nil, nil, 0.62),
        (color(0xF0524F), color(0xFF8A85), 0.70),
        (color(0x3FBF6A), color(0x7EE29D), 0.82),
        (color(0x3FBF6A), color(0x7EE29D), 0.56),
        (nil, nil, 0.68),
    ]
    let rowHeight: CGFloat = 108
    let gap: CGFloat = 26
    let total = CGFloat(rows.count) * rowHeight + CGFloat(rows.count - 1) * gap
    var y = body.midY + total / 2 - rowHeight
    for row in rows {
        let band = CGRect(x: body.minX, y: y, width: body.width, height: rowHeight)
        if let tint = row.tint {
            tint.withAlphaComponent(0.24).setFill()
            band.fill()
            // Gutter marker.
            row.mark!.setFill()
            CGRect(x: body.minX + 64, y: y + rowHeight / 2 - 9, width: 58, height: 18).fill()
            if row.tint == rows[2].tint {
                CGRect(x: body.minX + 84, y: y + rowHeight / 2 - 29, width: 18, height: 58).fill()
            }
        }
        // The "code" on the line.
        let codeColor = row.tint.map { $0.blended(withFraction: 0.35, of: .white)! } ?? color(0x8C93B8)
        codeColor.setFill()
        let start = body.minX + 168
        let width = (body.maxX - 72 - start) * row.width
        NSBezierPath(roundedRect: CGRect(x: start, y: y + rowHeight / 2 - 20, width: width, height: 40), xRadius: 20, yRadius: 20).fill()
        y -= rowHeight + gap
    }
    NSGraphicsContext.restoreGraphicsState()

    // A faint rim keeps the edge visible on dark backgrounds.
    color(0xFFFFFF, 0.08).setStroke()
    let rim = NSBezierPath(roundedRect: body.insetBy(dx: 1.5, dy: 1.5), xRadius: 184, yRadius: 184)
    rim.lineWidth = 3
    rim.stroke()
}

let sizes: [(points: Int, scale: Int)] = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)]
for (points, scale) in sizes {
    let pixels = points * scale
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    let graphics = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = graphics
    graphics.imageInterpolation = .high
    let context = graphics.cgContext
    context.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
    drawIcon(in: context)
    NSGraphicsContext.restoreGraphicsState()
    let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
    try! rep.representation(using: .png, properties: [:])!.write(to: output.appending(path: name))
}
print("wrote \(sizes.count) icons to \(output.path)")
