import AppKit

// Renders the app icon at 1024 pt, then writes every size the asset catalog lists. Matches
// `Brand / App icon / Yellow` (the app) or `Brand / App icon / Blueprint` (ohmydiff Dev) on the Branding page of
// the OHMYDIFF Figma file.
// Usage: swift scripts/make-icon.swift ohmydiff/Assets.xcassets/AppIcon.appiconset
//        swift scripts/make-icon.swift ohmydiff/Assets.xcassets/AppIcon-Dev.appiconset blueprint
let output = URL(fileURLWithPath: CommandLine.arguments[1])
let isBlueprint = CommandLine.arguments.dropFirst(2).first == "blueprint"

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

/// Fills `path` with a vertical gradient from `top` to `bottom`, in icon points.
func fill(_ context: CGContext, _ path: CGPath, _ stops: [(UInt32, CGFloat, CGFloat)], top: CGFloat, bottom: CGFloat) {
    context.saveGState()
    context.addPath(path)
    context.clip()
    context.drawLinearGradient(gradient(stops), start: CGPoint(x: 0, y: top), end: CGPoint(x: 0, y: bottom), options: [])
    context.restoreGState()
}

// macOS icon grid: the 1024 pt Figma artboard fills an 824 pt body centered in 1024, leaving room for the shadow.
let center = CGPoint(x: 512, y: 512)
let factor: CGFloat = 824 / 1024

/// An artboard length in icon points.
func art(_ length: CGFloat) -> CGFloat { length * factor }

/// An artboard y (down from the top) in icon points (up from the bottom).
func artY(_ y: CGFloat) -> CGFloat { center.y - (y - 512) * factor }

/// An artboard rectangle (y down) in icon points.
func art(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) -> CGRect {
    CGRect(x: center.x + (x - 512) * factor, y: artY(y + height), width: art(width), height: art(height))
}

func roundedRect(_ rect: CGRect, radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

func drawYellow(in context: CGContext, scale: CGFloat) {
    let shape = squircle(center: center, size: 824, radius: art(224))

    withShadow(context, scale: scale, y: -12, blur: 28, color(0x000000, 0.28)) {
        context.addPath(shape)
        context.setFillColor(color(0xD9F23B))
        context.fillPath()
    }

    // ±: the bars of `Brand / Mark / ink`.
    let glyph = CGMutablePath()
    for (x, y, width, height) in [(344.0, 386.0, 336.0, 84.0), (470, 260, 84, 336), (344, 680, 336, 84)] {
        glyph.addPath(roundedRect(art(x: x, y: y, width: width, height: height), radius: art(15.75)))
    }
    context.addPath(glyph)
    context.setFillColor(color(0x16171B))
    // Nonzero winding, so the plus's crossing bars fill as one shape.
    context.fillPath(using: .winding)
}

func drawBlueprint(in context: CGContext, scale: CGFloat) {
    // Figma's blur is twice CoreGraphics' standard deviation; shadows offset down in Figma are negative here.
    let shape = squircle(center: center, size: 824, radius: art(224))

    // Two drop shadows: the inner one is drawn into a layer that then casts the outer one.
    withShadow(context, scale: scale, y: -art(24), blur: art(48), color(0x086CB5, 0.25)) {
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        withShadow(context, scale: scale, y: -art(6), blur: art(12), color(0x074D96, 0.12)) {
            context.addPath(shape)
            context.setFillColor(color(0x039CEE))
            context.fillPath()
        }
        context.endTransparencyLayer()
    }
    fill(context, shape, [(0x08CBE7, 0, 1), (0x039CEE, 0.45, 1), (0x1260DD, 1, 1)], top: artY(0), bottom: artY(1024))

    // A construction grid every 57 pt inside the keyline, which is 56 pt in from the edge.
    let keyline = squircle(center: center, size: art(912), radius: art(168))
    context.saveGState()
    context.addPath(keyline)
    context.clip()
    let grid = CGMutablePath()
    for step in 1..<16 {
        let at = 56 + CGFloat(step) * 57
        grid.move(to: CGPoint(x: center.x + (at - 512) * factor, y: artY(56)))
        grid.addLine(to: CGPoint(x: center.x + (at - 512) * factor, y: artY(968)))
        grid.move(to: CGPoint(x: center.x + (56 - 512) * factor, y: artY(at)))
        grid.addLine(to: CGPoint(x: center.x + (968 - 512) * factor, y: artY(at)))
    }
    context.addPath(grid)
    context.setStrokeColor(color(0xFFFFFF, 0.14))
    context.setLineWidth(art(1.4))
    context.strokePath()
    context.restoreGState()

    // ±: frosted white bars with a soft glow, the plus brighter than the minus.
    let radius = art(20.475)
    let plus = CGMutablePath()
    plus.addPath(roundedRect(art(x: 293.6, y: 348.2, width: 436.8, height: 109.2), radius: radius))
    plus.addPath(roundedRect(art(x: 457.4, y: 184.4, width: 109.2, height: 436.8), radius: radius))
    let minus = roundedRect(art(x: 293.6, y: 730.4, width: 436.8, height: 109.2), radius: radius)
    let bars: [(CGPath, [(UInt32, CGFloat, CGFloat)], CGFloat, CGFloat)] = [
        (minus, [(0xFFFFFF, 0, 0.95), (0xC0EFFF, 1, 0.55)], 730.4, 839.6),
        (plus, [(0xFFFFFF, 0, 1), (0xFFFFFF, 0.5, 1), (0xB4EFFF, 1, 0.8)], 184.4, 621.2),
    ]
    for (bar, stops, top, bottom) in bars {
        withShadow(context, scale: scale, y: 0, blur: art(12), color(0xFFFFFF, 0.45)) {
            context.beginTransparencyLayer(auxiliaryInfo: nil)
            fill(context, bar, stops, top: artY(top), bottom: artY(bottom))
            context.endTransparencyLayer()
        }
        innerShadow(context, bar, scale: scale, y: -art(2), blur: art(5), color(0xFFFFFF, 0.65))
    }

    // A white keyline, then light along the top edge and shade along the bottom.
    context.addPath(keyline)
    context.setStrokeColor(color(0xFFFFFF, 0.96))
    context.setLineWidth(art(10))
    context.strokePath()
    innerShadow(context, shape, scale: scale, y: -art(5), blur: art(12), color(0xD3FCFF, 0.5))
    innerShadow(context, shape, scale: scale, y: art(6), blur: art(18), color(0x0848B5, 0.2))
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
    let pixelsPerPoint = CGFloat(pixels) / 1024
    context.scaleBy(x: pixelsPerPoint, y: pixelsPerPoint)
    if isBlueprint { drawBlueprint(in: context, scale: pixelsPerPoint) } else { drawYellow(in: context, scale: pixelsPerPoint) }
    NSGraphicsContext.restoreGraphicsState()
    let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
    try! rep.representation(using: .png, properties: [:])!.write(to: output.appending(path: name))
}
print("wrote \(sizes.count) icons to \(output.path)")
