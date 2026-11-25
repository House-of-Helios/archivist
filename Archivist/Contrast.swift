import AppKit
import SwiftUI

/// Keeps a picture off a circle of its own colour (a lemon on yellow vanishes): each emoji's main
/// hue is measured once from the picture itself, drawn small, and remembered.
enum Contrast {
    private static var cache: [String: Double?] = [:]

    /// Main hue in degrees of the picture's coloured pixels, or nil when it is mostly grey.
    static func hue(ofEmoji name: String) -> Double? {
        if let known = cache[name] { return known }
        var result: Double?
        if let image = NSImage(named: name) {
            let side = 32
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
                                       samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                       bytesPerRow: 0, bitsPerPixel: 0)!
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            image.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
            NSGraphicsContext.restoreGraphicsState()
            var x = 0.0, y = 0.0, coloured = 0.0, opaque = 0.0
            for i in 0..<side { for j in 0..<side {
                guard let c = rep.colorAt(x: i, y: j), c.alphaComponent > 0.5 else { continue }
                opaque += 1
                var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
                c.usingColorSpace(.deviceRGB)?.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
                guard s > 0.3, b > 0.25 else { continue }
                x += cos(Double(h) * 2 * .pi) * Double(s); y += sin(Double(h) * 2 * .pi) * Double(s); coloured += 1
            }}
            if opaque > 0, coloured / opaque > 0.3 { result = (atan2(y, x) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360) }
        }
        cache[name] = result
        return result
    }

    static func hue(ofHex hex: String) -> Double {
        let v = UInt32(hex.dropFirst(), radix: 16) ?? 0
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        NSColor(srgbRed: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255, blue: CGFloat(v & 0xff) / 255, alpha: 1)
            .getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return Double(h) * 360
    }

    /// True when the picture would stand out on that colour: hues at least 60° apart, or a grey picture.
    static func works(_ emoji: String, on hex: String) -> Bool {
        guard let e = hue(ofEmoji: emoji) else { return true }
        let d = abs(e - hue(ofHex: hex)).truncatingRemainder(dividingBy: 360)
        return min(d, 360 - d) >= 60
    }

    /// A number that is the same for the same text on every launch (Swift's hashValue isn't).
    static func stable(_ text: String) -> Int {
        var h: UInt64 = 0xcbf29ce484222325
        for b in text.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return Int(h % 1_000_003)
    }

    /// The same look for the same path, every time: a colour from the path, then the first picture
    /// (in an order also from the path) that stands out on it. `notColor`: a neighbour's colour to step past.
    static func look(for path: String, pool: [String], notColor: String? = nil, notIcons: Set<String> = []) -> (icon: String, color: String) {
        let n = stable(path)
        var c = Nippon.colors[n % Nippon.colors.count].hex
        // A neighbour must look different, not just be a different entry: step on until the hues
        // sit 50 degrees apart (three greens in a row read as one colour).
        if let near = notColor {
            for k in 0..<Nippon.colors.count {
                let cand = Nippon.colors[(n + k) % Nippon.colors.count].hex
                let d = abs(hue(ofHex: cand) - hue(ofHex: near)).truncatingRemainder(dividingBy: 360)
                if min(d, 360 - d) >= 50 { c = cand; break }
            }
        }
        let start = (n / Nippon.colors.count) % pool.count
        let order = Array(pool[start...] + pool[..<start])
        return (order.first { works($0, on: c) && !notIcons.contains($0) } ?? order.first { works($0, on: c) } ?? order[0], c)
    }

    /// A random picture from `pool` that stands out on `hex`, preferring ones not in `avoid`.
    static func pick(from pool: [String], on hex: String, avoid: Set<String> = []) -> String {
        let fits = pool.filter { works($0, on: hex) }
        return fits.filter { !avoid.contains($0) }.randomElement() ?? fits.randomElement() ?? pool.randomElement()!
    }
}
