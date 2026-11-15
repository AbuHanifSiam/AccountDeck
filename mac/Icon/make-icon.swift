// Turns Icon/artwork.jpg into a macOS icon (squircle on the 1024 grid, soft drop shadow) and AppIcon.icns.
import AppKit
let art = NSImage(contentsOfFile: CommandLine.arguments[1])!
let out = CommandLine.arguments[2]
func render(_ size: Int) -> Data {
    let s = CGFloat(size), k = s / 1024
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let rect = NSRect(x: 100*k, y: 100*k, width: 824*k, height: 824*k)
    let shape = NSBezierPath(roundedRect: rect, xRadius: 185*k, yRadius: 185*k)
    // shadow
    let sh = NSShadow(); sh.shadowBlurRadius = 28*k; sh.shadowOffset = NSSize(width: 0, height: -12*k)
    sh.shadowColor = NSColor.black.withAlphaComponent(0.30)
    NSGraphicsContext.saveGraphicsState(); sh.set(); NSColor.white.setFill(); shape.fill(); NSGraphicsContext.restoreGraphicsState()
    // artwork, slightly zoomed so the characters fill the tile
    NSGraphicsContext.saveGraphicsState(); shape.addClip()
    let z: CGFloat = 1.06
    let w = rect.width * z
    art.draw(in: NSRect(x: rect.midX - w/2, y: rect.midY - w/2 + 6*k, width: w, height: w))
    NSGraphicsContext.restoreGraphicsState()
    // faint inner edge highlight
    NSColor.white.withAlphaComponent(0.35).setStroke(); shape.lineWidth = 2*k; shape.stroke()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}
let set = out + "/AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: set, withIntermediateDirectories: true)
for b in [16, 32, 128, 256, 512] {
    try! render(b).write(to: URL(fileURLWithPath: "\(set)/icon_\(b)x\(b).png"))
    try! render(b*2).write(to: URL(fileURLWithPath: "\(set)/icon_\(b)x\(b)@2x.png"))
}
try! render(1024).write(to: URL(fileURLWithPath: out + "/icon-1024.png"))
