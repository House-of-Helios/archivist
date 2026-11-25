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
        ("#90B44B", "Hiwamoegi"), ("#E83015", "Syojyohi"), ("#D19826", "Yamabukicha"), ("#7B90D2", "Benimidori"),
        ("#5DAC81", "Wakatake"), ("#986DB2", "Hashita"), ("#2EA9DF", "Tsuyukusa"), ("#C1693C", "Kaba"),
        ("#E03C8A", "Tsutsuji"), ("#3A8FB7", "Chigusa"), ("#E98B2A", "Beniukon"), ("#D0104C", "Karakurenai"),
        ("#DC9FB4", "Nadeshiko"), ("#F596AA", "Momo"), ("#B481BB", "Benifuji"), ("#A5DEE4", "Kamenozoki"),
        ("#81C7D4", "Mizu"), ("#7DB9DE", "Wasurenagusa"), ("#A8D8B9", "Byakuroku"), ("#86C166", "Nae"),
        ("#F7D94C", "Nanohana"), ("#FFB11B", "Yamabuki"), ("#FB966E", "Araisyu"), ("#E87A90", "Usubeni"),
    ]
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
