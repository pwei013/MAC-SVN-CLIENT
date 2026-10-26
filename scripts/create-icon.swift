import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
let image = NSImage(size: NSSize(width: 1024, height: 1024))
image.lockFocus()
let background = NSBezierPath(roundedRect: NSRect(x: 52, y: 52, width: 920, height: 920), xRadius: 210, yRadius: 210)
NSGradient(starting: NSColor(red: 0.40, green: 0.36, blue: 0.87, alpha: 1),
           ending: NSColor(red: 0.18, green: 0.20, blue: 0.53, alpha: 1))!.draw(in: background, angle: -90)
NSColor.white.withAlphaComponent(0.94).setStroke()
let branch = NSBezierPath()
branch.lineWidth = 42
branch.lineCapStyle = .round
branch.move(to: NSPoint(x: 368, y: 400))
branch.line(to: NSPoint(x: 368, y: 760))
branch.move(to: NSPoint(x: 368, y: 480))
branch.curve(to: NSPoint(x: 656, y: 710), controlPoint1: NSPoint(x: 368, y: 640), controlPoint2: NSPoint(x: 656, y: 550))
branch.stroke()
for point in [NSPoint(x: 368, y: 760), NSPoint(x: 368, y: 400), NSPoint(x: 656, y: 710)] {
    NSColor.white.setFill()
    NSBezierPath(ovalIn: NSRect(x: point.x - 64, y: point.y - 64, width: 128, height: 128)).fill()
    NSColor(red: 0.36, green: 0.34, blue: 0.77, alpha: 1).setFill()
    NSBezierPath(ovalIn: NSRect(x: point.x - 30, y: point.y - 30, width: 60, height: 60)).fill()
}
let text = "SVN" as NSString
let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 143, weight: .bold), .foregroundColor: NSColor.white]
let textSize = text.size(withAttributes: attributes)
text.draw(at: NSPoint(x: (1024 - textSize.width) / 2, y: 165), withAttributes: attributes)
image.unlockFocus()
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
        NSGraphicsContext.restoreGraphicsState()
        let suffix = scale == 2 ? "@2x" : ""
        let data = bitmap.representation(using: .png, properties: [:])!
        try data.write(to: output.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}
