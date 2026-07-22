import AppKit

// Renders the Crisp app icon: macOS-26-style gradient squircle with a white
// display glyph and a sparkle. Writes a 1024 master plus all iconset sizes.

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."

func renderMaster(size: CGFloat) -> NSImage {
    let img = NSImage(size: NSSize(width: size, height: size))
    img.lockFocus()
    guard let ctx = NSGraphicsContext.current?.cgContext else { fatalError("no ctx") }
    let s = size / 1024.0

    // Background squircle: dark navy gradient
    let inset = 100.0 * s
    let rect = CGRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
    let squircle = NSBezierPath(roundedRect: rect, xRadius: 185 * s, yRadius: 185 * s)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12 * s), blur: 24 * s,
                  color: NSColor.black.withAlphaComponent(0.35).cgColor)
    NSColor(calibratedRed: 0.06, green: 0.08, blue: 0.20, alpha: 1).setFill()
    squircle.fill()
    ctx.restoreGState()
    NSGradient(colors: [
        NSColor(calibratedRed: 0.16, green: 0.20, blue: 0.38, alpha: 1),
        NSColor(calibratedRed: 0.06, green: 0.08, blue: 0.20, alpha: 1),
    ])!.draw(in: squircle, angle: -90)

    // Screen glyph: blurry mosaic left resolving into crisp right
    let g = CGRect(x: (size - 520 * s) / 2, y: (size - 400 * s) / 2, width: 520 * s, height: 400 * s)
    let glyph = NSBezierPath(roundedRect: g, xRadius: 48 * s, yRadius: 48 * s)

    // Left: chunky mosaic tiles (reads down to 16px)
    ctx.saveGState()
    glyph.addClip()
    let diag = NSBezierPath()
    diag.move(to: CGPoint(x: g.minX, y: g.minY))
    diag.line(to: CGPoint(x: g.midX + 70 * s, y: g.minY))
    diag.line(to: CGPoint(x: g.midX - 70 * s, y: g.maxY))
    diag.line(to: CGPoint(x: g.minX, y: g.maxY))
    diag.close()
    diag.addClip()
    let tile = 134.0 * s
    let alphas: [CGFloat] = [0.30, 0.52, 0.40, 0.58, 0.34, 0.47,
                             0.55, 0.36, 0.50, 0.42, 0.60, 0.32]
    var i = 0
    var ty = g.minY
    while ty < g.maxY {
        var tx = g.minX
        while tx < g.maxX {
            NSColor.white.withAlphaComponent(alphas[i % alphas.count]).setFill()
            NSBezierPath(rect: CGRect(x: tx, y: ty, width: tile, height: tile)).fill()
            i += 1
            tx += tile
        }
        ty += tile
    }
    ctx.restoreGState()

    // Right: crisp half with a subtle cool gradient (not a flat white hole)
    ctx.saveGState()
    glyph.addClip()
    let right = NSBezierPath()
    right.move(to: CGPoint(x: g.midX + 70 * s, y: g.minY))
    right.line(to: CGPoint(x: g.maxX, y: g.minY))
    right.line(to: CGPoint(x: g.maxX, y: g.maxY))
    right.line(to: CGPoint(x: g.midX - 70 * s, y: g.maxY))
    right.close()
    NSGradient(colors: [
        NSColor.white,
        NSColor(calibratedRed: 0.82, green: 0.89, blue: 1.0, alpha: 1),
    ])!.draw(in: right, angle: -90)
    ctx.restoreGState()

    img.unlockFocus()
    return img
}

func writePNG(_ image: NSImage, pixels: Int, to path: String) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels),
               from: .zero, operation: .copy, fraction: 1.0)
    NSGraphicsContext.restoreGraphicsState()
    let data = rep.representation(using: .png, properties: [:])!
    try! data.write(to: URL(fileURLWithPath: path))
}

// Render each size fresh from vector code (crisp at every size, fittingly)
for px in [16, 32, 64, 128, 256, 512, 1024] {
    writePNG(renderMaster(size: 1024), pixels: px, to: "\(outDir)/icon_\(px).png")
}
print("done")
