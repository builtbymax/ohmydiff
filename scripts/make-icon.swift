import AppKit

// Renders the app icon at 1024 pt, then writes every size the asset catalog lists.
// Matches `Icon / A · Refined 85%` on the App Icons page of the OHMYDIFF Figma file.
// Usage: swift scripts/make-icon.swift ohmydiff/Assets.xcassets/AppIcon.appiconset
let output = URL(fileURLWithPath: CommandLine.arguments[1])

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func gradient(_ stops: [(UInt32, CGFloat, CGFloat)]) -> CGGradient {
    CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: stops.map { color($0.0, $0.2) } as CFArray,
        locations: stops.map(\.1))!
}

/// A square with Figma's smoothed corners (corner smoothing 0.6, like macOS icons), after the
/// figma-squircle construction. Built for the top edge and top-right corner, then rotated for the others.
func squircle(center: CGPoint, size: CGFloat, radius: CGFloat, smoothing: CGFloat = 0.6) -> CGPath {
    let toRadians = CGFloat.pi / 180
    let p = (1 + smoothing) * radius
    let arcMeasure = 90 * (1 - smoothing)
    let arcLength = sin(arcMeasure / 2 * toRadians) * radius * 2.squareRoot()
    let alpha = (90 - arcMeasure) / 2
    let p3ToP4 = radius * tan(alpha / 2 * toRadians)
    let beta = 45 * smoothing
    let c = p3ToP4 * cos(beta * toRadians)
    let d = c * tan(beta * toRadians)
    let b = (p - arcLength - c - d) / 3
    let a = 2 * b
    let h = size / 2

    // Top edge and top-right corner, y down, relative to the center.
    let start = CGPoint(x: h - p, y: -h)
    let s = CGPoint(x: start.x + a + b + c, y: -h + d)
    let e = CGPoint(x: s.x + arcLength, y: s.y + arcLength)
    let arcCenter = CGPoint(x: h - radius, y: -h + radius)
    let φs = atan2(s.y - arcCenter.y, s.x - arcCenter.x)
    let φe = atan2(e.y - arcCenter.y, e.x - arcCenter.x)
    let k = 4 / 3 * tan((φe - φs) / 4) * radius
    let corner: [[CGPoint]] = [
        [CGPoint(x: start.x + a, y: -h), CGPoint(x: start.x + a + b, y: -h), s],
        [CGPoint(x: s.x - k * sin(φs), y: s.y + k * cos(φs)), CGPoint(x: e.x + k * sin(φe), y: e.y - k * cos(φe)), e],
        [CGPoint(x: e.x + d, y: e.y + c), CGPoint(x: e.x + d, y: e.y + b + c), CGPoint(x: h, y: -h + p)],
    ]

    let path = CGMutablePath()
    for quarter in 0..<4 {
        // Rotate clockwise by 90° per corner (y down), then flip to y up around `center`.
        func place(_ point: CGPoint) -> CGPoint {
            var q = point
            for _ in 0..<quarter { q = CGPoint(x: -q.y, y: q.x) }
            return CGPoint(x: center.x + q.x, y: center.y - q.y)
        }
        let edgeStart = CGPoint(x: -h + p, y: -h)
        if quarter == 0 { path.move(to: place(edgeStart)) } else { path.addLine(to: place(edgeStart)) }
        path.addLine(to: place(start))
        for curve in corner {
            path.addCurve(to: place(curve[2]), control1: place(curve[0]), control2: place(curve[1]))
        }
    }
    path.closeSubpath()
    return path
}

/// Draws `drawing` with a shadow whose offset and blur are given in icon points. Shadows are set in
/// device space, so they are scaled to the bitmap like everything else.
func withShadow(_ context: CGContext, scale: CGFloat, x: CGFloat = 0, y: CGFloat, blur: CGFloat, _ shadowColor: CGColor, drawing: () -> Void) {
    context.saveGState()
    context.setShadow(offset: CGSize(width: x * scale, height: y * scale), blur: blur * scale, color: shadowColor)
    drawing()
    context.restoreGState()
}

/// A shadow cast inward from the edge of `shape`, like Figma's inner shadow (offsets y up).
func innerShadow(_ context: CGContext, _ shape: CGPath, scale: CGFloat, y: CGFloat, blur: CGFloat, _ shadowColor: CGColor) {
    context.saveGState()
    context.addPath(shape)
    context.clip()
    // The surround that casts the shadow is drawn far to the side and its shadow moved back, so its own
    // antialiased edge never lands inside the clip as a dark hairline.
    let away: CGFloat = 4096
    let aside = CGAffineTransform(translationX: away, y: 0)
    let surround = CGMutablePath()
    surround.addRect(shape.boundingBox.insetBy(dx: -200, dy: -200), transform: aside)
    surround.addPath(shape, transform: aside)
    withShadow(context, scale: scale, x: -away, y: y, blur: blur, shadowColor) {
        context.addPath(surround)
        context.setFillColor(color(0x000000))
        context.fillPath(using: .evenOdd)
    }
    context.restoreGState()
}

func drawIcon(in context: CGContext, scale: CGFloat) {
    // macOS icon grid: an 824 pt body centered in 1024, leaving room for the shadow.
    let center = CGPoint(x: 512, y: 512)
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = squircle(center: center, size: 824, radius: 185)

    withShadow(context, scale: scale, y: -12, blur: 28, color(0x000000, 0.28)) {
        context.addPath(shape)
        context.setFillColor(color(0xD6F43C))
        context.fillPath()
    }

    // Lime, lit from the top: a vertical gradient and a soft white glow along the top edge.
    context.saveGState()
    context.addPath(shape)
    context.clip()
    context.drawLinearGradient(
        gradient([(0xF1FF8A, 0, 1), (0xD6F43C, 0.55, 1), (0xBCDB22, 1, 1)]),
        start: CGPoint(x: 0, y: body.maxY), end: CGPoint(x: 0, y: body.minY), options: [])
    let glow = CGSize(width: 0.55 * body.width, height: 0.35 * body.height)
    context.translateBy(x: body.midX, y: body.maxY - 0.08 * body.height)
    context.scaleBy(x: glow.width / glow.height, y: 1)
    context.drawRadialGradient(
        gradient([(0xFFFFFF, 0, 0.45), (0xFFFFFF, 1, 0)]),
        startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: glow.height, options: [])
    context.restoreGState()

    // A bright rim along the top edge and a darker lime one along the bottom.
    innerShadow(context, shape, scale: scale, y: -5, blur: 6, color(0xFFFFFF, 0.55))
    innerShadow(context, shape, scale: scale, y: 10, blur: 28, color(0x6F8A00, 0.35))

    // ±: rounded bars, the plus above the minus, centered as a group.
    let thickness: CGFloat = 71.4
    let arm: CGFloat = 265.2
    let gap: CGFloat = 59.5
    let top = center.y + (arm + gap + thickness) / 2
    let plusCenter = top - arm / 2
    let minusCenter = top - arm - gap - thickness / 2
    func bar(_ rect: CGRect) -> CGPath {
        CGPath(roundedRect: rect, cornerWidth: min(rect.width, rect.height) / 2, cornerHeight: min(rect.width, rect.height) / 2, transform: nil)
    }
    let glyph = CGMutablePath()
    glyph.addPath(bar(CGRect(x: center.x - arm / 2, y: plusCenter - thickness / 2, width: arm, height: thickness)))
    glyph.addPath(bar(CGRect(x: center.x - thickness / 2, y: plusCenter - arm / 2, width: thickness, height: arm)))
    glyph.addPath(bar(CGRect(x: center.x - arm / 2, y: minusCenter - thickness / 2, width: arm, height: thickness)))
    withShadow(context, scale: scale, y: -5, blur: 8.5, color(0x5E7700, 0.35)) {
        context.addPath(glyph)
        context.setFillColor(color(0x16171B))
        // Nonzero winding, so the plus's crossing bars fill as one shape.
        context.fillPath(using: .winding)
    }
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
    let factor = CGFloat(pixels) / 1024
    context.scaleBy(x: factor, y: factor)
    drawIcon(in: context, scale: factor)
    NSGraphicsContext.restoreGraphicsState()
    let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
    try! rep.representation(using: .png, properties: [:])!.write(to: output.appending(path: name))
}
print("wrote \(sizes.count) icons to \(output.path)")
