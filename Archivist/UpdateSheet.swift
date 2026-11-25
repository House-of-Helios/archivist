import ArchivistCore
import SwiftUI

/// What the update pill opens: every version newer than this one, newest
/// first, with its notes, then Later or Install & restart.
struct UpdateSheet: View {
    let update: UpdateInfo
    let current: String
    var onLater: () -> Void
    var onInstall: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                Badge(icon: "inbox_tray", hex: Nippon.colors[4].hex, size: 48)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Archivist \(update.version)").font(Typeface.title(24)).foregroundStyle(Palette.ink)
                    Text("You have \(current)").font(Typeface.text(13)).foregroundStyle(Palette.soft)
                }
            }
            .padding(.bottom, 20)
            Text("What's new").font(Typeface.text(13, .semibold)).foregroundStyle(Palette.soft).padding(.bottom, 8)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(update.changes(since: current)) { n in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(n.version).font(Typeface.text(12.5, .semibold)).foregroundStyle(Palette.soft)
                            Text(n.notes.isEmpty ? "Small fixes." : n.notes).font(Typeface.text(14)).foregroundStyle(Palette.ink)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 12)
                        .overlay(alignment: .bottom) { Rectangle().fill(Palette.rule).frame(height: 1) }
                    }
                }
            }
            .frame(maxHeight: 320)
            .overlay(alignment: .top) { Rectangle().fill(Palette.rule).frame(height: 1) }
            HStack(spacing: 12) {
                Spacer()
                Button("Later", action: onLater).buttonStyle(QuietButton()).keyboardShortcut(.cancelAction)
                Button("Install & restart", action: onInstall).buttonStyle(PrimaryButton()).keyboardShortcut(.defaultAction)
            }
            .padding(.top, 20)
        }
        .padding(28)
        .frame(width: 480)
        .background(Palette.ground)
    }
}
