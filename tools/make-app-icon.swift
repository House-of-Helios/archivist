import AppKit
// Usage: swift tools/make-app-icon.swift tools/app-icon-source.png Archivist/Assets.xcassets/AppIcon.appiconset
// macOS icon grid: an 824-pt rounded square centred on a 1024 canvas. The square
// artwork (Thoth on red) fills the tile edge to edge and is clipped by it, so the figure still
// runs off the bottom edge the way it was drawn.
let src = NSImage(contentsOfFile: CommandLine.arguments[1])!
let outDir = CommandLine.arguments[2]
func render(_ px: Int) -> Data {
  let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                             hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
  rep.size = NSSize(width: px, height: px)
  NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
  NSGraphicsContext.current!.imageInterpolation = .high
  let k = CGFloat(px) / 1024
  let tile = NSRect(x: 100*k, y: 100*k, width: 824*k, height: 824*k)
  NSBezierPath(roundedRect: tile, xRadius: 185*k, yRadius: 185*k).addClip()
  src.draw(in: tile)
  NSGraphicsContext.restoreGraphicsState()
  return rep.representation(using: .png, properties: [:])!
}
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
var images: [[String: String]] = []
for (pt, scales) in [(16, [1, 2]), (32, [1, 2]), (128, [1, 2]), (256, [1, 2]), (512, [1, 2])] {
  for s in scales {
    let px = pt * s
    let name = "icon_\(pt)x\(pt)\(s == 2 ? "@2x" : "").png"
    try! render(px).write(to: URL(fileURLWithPath: outDir + "/" + name))
    images.append(["filename": name, "idiom": "mac", "scale": "\(s)x", "size": "\(pt)x\(pt)"])
  }
}
let json = try! JSONSerialization.data(withJSONObject: ["images": images, "info": ["author": "xcode", "version": 1]], options: [.prettyPrinted, .sortedKeys])
try! json.write(to: URL(fileURLWithPath: outDir + "/Contents.json"))
print("wrote \(images.count) icons to \(outDir)")
