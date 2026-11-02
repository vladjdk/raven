// Draws Raven's app icon into App/Assets.xcassets/AppIcon.appiconset.
// Run: swift scripts/make-icon.swift
import AppKit

let out = URL(fileURLWithPath: "App/Assets.xcassets/AppIcon.appiconset", isDirectory: true)

func render(_ px: Int) -> Data {
  let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                             hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
  NSGraphicsContext.saveGraphicsState()
  NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
  let s = CGFloat(px)
  // macOS icon grid: 824/1024 body with a soft shadow.
  let inset = s * 100 / 1024
  let body = NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
  let path = NSBezierPath(roundedRect: body, xRadius: body.width * 0.225, yRadius: body.width * 0.225)
  let shadow = NSShadow()
  shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
  shadow.shadowBlurRadius = s * 0.02
  shadow.shadowOffset = NSSize(width: 0, height: -s * 0.01)
  NSGraphicsContext.saveGraphicsState()
  shadow.set()
  NSColor(red: 0.31, green: 0.31, blue: 0.79, alpha: 1).setFill()
  path.fill()
  NSGraphicsContext.restoreGraphicsState()
  let gradient = NSGradient(colors: [
    NSColor(red: 0.42, green: 0.40, blue: 0.93, alpha: 1),
    NSColor(red: 0.22, green: 0.20, blue: 0.62, alpha: 1),
  ])!
  gradient.draw(in: path, angle: -90)
  let config = NSImage.SymbolConfiguration(pointSize: s * 0.42, weight: .semibold)
    .applying(.init(paletteColors: [.white]))
  if let bird = NSImage(systemSymbolName: "bird.fill", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
    let size = bird.size
    bird.draw(in: NSRect(x: (s - size.width) / 2, y: (s - size.height) / 2 - s * 0.01, width: size.width, height: size.height))
  }
  NSGraphicsContext.restoreGraphicsState()
  return rep.representation(using: .png, properties: [:])!
}

var images: [[String: String]] = []
for points in [16, 32, 128, 256, 512] {
  for scale in [1, 2] {
    let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
    try! render(points * scale).write(to: out.appendingPathComponent(name))
    images.append(["idiom": "mac", "size": "\(points)x\(points)", "scale": "\(scale)x", "filename": name])
  }
}
let contents: [String: Any] = ["images": images, "info": ["version": 1, "author": "xcode"]]
try! JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
  .write(to: out.appendingPathComponent("Contents.json"))
print("Wrote \(images.count) icons")
