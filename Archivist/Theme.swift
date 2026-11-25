import AppKit
import SwiftUI

/// Warm paper, one lavender accent, one serif for titles.
enum Palette {
    /// Picks the dark or light value from the window's own appearance.
    private static func pair(_ dark: UInt32, _ light: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { a in
            let v = a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255,
                           blue: CGFloat(v & 0xff) / 255, alpha: 1)
        })
    }

    static let ground = pair(0x1f1b15, 0xf2ebdd)     // the page (lifted a step: pictures read muddy on near-black)
    static let raised = pair(0x2a251d, 0xe9e0cf)     // panels
    static let ink = pair(0xece3d1, 0x221d16)        // reading text
    static let soft = pair(0x9d9484, 0x6b6253)       // second voice: kinds, notes
    static let rule = pair(0x3a3328, 0xd8ccb6)       // the only lines
    static let accent = pair(0x9b90c2, 0x9b90c2)     // the app's lavender (Helios, 2026-11-25): Start, selection, focus
    static let onAccent = pair(0x1f1b2e, 0x1f1b2e)   // dark text on the lavender (white read at 2.9:1, dark at 7:1)
    static let good = pair(0x8cc084, 0x3f7f3a)       // "up to date"
    static let due = pair(0xe06a6c, 0xb8393c)        // "to back up", "not backed up yet"
    static let warn = pair(0xd6a467, 0x93601d)       // a problem worth reading
}

enum Typeface {
    /// Bonum: job titles only.
    static func title(_ size: CGFloat) -> Font { .custom("TeXGyreBonum-Bold", size: size) }
    /// Roboto Mono: only the big live numbers, tabular so they don't jitter.
    static func number(_ size: CGFloat) -> Font { .custom("RobotoMono-Regular", size: size).monospacedDigit() }
    /// Everything read: the system face, drawn for interface sizes.
    static func text(_ size: CGFloat = 14, _ weight: Font.Weight = .regular) -> Font { .system(size: size, weight: weight) }
}

/// One of the bundled Fluent Emoji Flat icons (MIT; `Resources/Licenses`), the House's
/// icon set. Vector assets: crisp at any size and in snapshots.
struct Emoji: View {
    let name: String
    var size: CGFloat = 20
    var body: some View {
        Image(name).resizable().interpolation(.high).scaledToFit().frame(width: size, height: size)
    }
}

/// 24 traditional Japanese (Nippon) colours, in an order where consecutive entries sit far apart, so counting through them never gives neighbours alike.
enum Nippon {
    static let colors: [(hex: String, name: String)] = [
        // Deep and clear: three each of red, orange, yellow, green, teal, blue, purple, and pink/brown
        // (Helios, 2026-11-25), ordered so neighbours differ.
        ("#90B44B", "Hiwamoegi"), ("#CB4042", "Akabeni"), ("#2EA9DF", "Tsuyukusa"), ("#FFB11B", "Yamabuki"),
        ("#77428D", "Edomurasaki"), ("#00896C", "Aotake"), ("#F05E1C", "Ohni"), ("#DB4D6D", "Nakabeni"),
        ("#005CAF", "Ruri"), ("#D19826", "Yamabukicha"), ("#268785", "Seiheki"), ("#9F353A", "Enji"),
        ("#1B813E", "Tokiwa"), ("#C1328E", "Botan"), ("#E98B2A", "Beniukon"), ("#33A6B8", "Asagi"),
        ("#947A6D", "Kurumi"), ("#006284", "Hanada"), ("#F6C555", "Kuchinashi"), ("#6A4C9C", "Kikyo"),
        ("#5DAC81", "Wakatake"), ("#C1693C", "Kaba"), ("#E83015", "Syojyohi"), ("#E16B8C", "Kohbai"),
    ]
    /// The 24 pastel-leaning colours before 2026-11-25, in their old order: a saved colour from that
    /// list becomes the new colour in the same place, so every backup and source refreshes.
    static let before = ["#90B44B", "#E83015", "#D19826", "#7B90D2", "#5DAC81", "#986DB2", "#2EA9DF", "#C1693C",
                         "#E03C8A", "#3A8FB7", "#E98B2A", "#D0104C", "#DC9FB4", "#F596AA", "#B481BB", "#A5DEE4",
                         "#81C7D4", "#7DB9DE", "#A8D8B9", "#86C166", "#F7D94C", "#FFB11B", "#FB966E", "#E87A90"]
    /// The 0.0.16 list, for the same refresh.
    static let v16 = ["#90B44B", "#CB4042", "#2EA9DF", "#FFB11B", "#77428D", "#00896C", "#F05E1C", "#005CAF",
                      "#D19826", "#C1328E", "#1B813E", "#C1693C", "#6A4C9C", "#33A6B8", "#9F353A", "#5DAC81",
                      "#DB4D6D", "#006284", "#F6C555", "#947A6D", "#8B81C3", "#E83015", "#51A8DD", "#D05A6E"]
    static func current(_ hex: String) -> String {
        if colors.contains(where: { $0.hex == hex }) { return hex }
        if let i = before.firstIndex(of: hex) ?? v16.firstIndex(of: hex) { return colors[i].hex }
        return hex
    }

    /// A solid soft version (the colour mixed with white): the same in light and dark, never
    /// a see-through tint that a dark page muddies.
    static func soft(_ hex: String, white: Double = 0.3) -> Color {   // 0.45 read as pastel; 0.3 keeps the colour
        let v = UInt32(hex.dropFirst(), radix: 16) ?? 0x5DAC81
        func mix(_ c: UInt32) -> Double { Double(c & 0xff) / 255 * (1 - white) + white }
        return Color(red: mix(v >> 16), green: mix(v >> 8), blue: mix(v))
    }

    static func color(_ hex: String) -> Color {
        let v = UInt32(hex.dropFirst(), radix: 16) ?? 0x5DAC81
        return Color(red: Double((v >> 16) & 0xff) / 255, green: Double((v >> 8) & 0xff) / 255, blue: Double(v & 0xff) / 255)
    }
}

/// A picture in its coloured circle: how a backup or a source is recognised at a glance.
struct Badge: View {
    let icon: String
    let hex: String
    var size: CGFloat = 28
    var body: some View {
        Emoji(name: icon, size: size * 0.62)
            .frame(width: size, height: size)
            // A soft tint, not the full colour: a peach on full orange disappears.
            .background(Circle().fill(Nippon.soft(hex)))
    }
}
