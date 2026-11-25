#if DEBUG
import AppKit
import ArchivistCore
import SwiftUI

/// Draws the real screens to PNG offscreen, so the window can be reviewed without
/// screen recording: `Archivist.app/Contents/MacOS/Archivist --snapshot <dir>`.
/// Uses made-up backups and drives, never the person's own.
@MainActor
enum Snapshot {
    static var requestedDirectory: String? {
        let a = CommandLine.arguments
        guard let i = a.firstIndex(of: "--snapshot"), i + 1 < a.count else { return nil }
        return a[i + 1]
    }

    static func render(to dir: String) {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let mac = Drive(mountPoint: "/System/Volumes/Data", fileSystem: "apfs", device: 1, kind: .ssd, name: "Macintosh HD")
        let net = Drive(mountPoint: "/Volumes/Backup Drive", fileSystem: "smbfs", device: 2, kind: .network, name: "Backup Drive")

        var studio = Job(title: "Studio")
        studio.sources = ["Garden", "Recipes", "Letters", "Recipes/Dropbox"].map { Source(path: "/Users/someone/Documents/" + $0) }
        studio.sources[3].skip = true
        studio.sources[2].skipJunk = false
        studio.sources[1].patterns = ["*.tmp"]
        for i in studio.sources.indices { studio.sources[i].color = Nippon.colors[i].hex }   // as add() counts through them
        studio.destination = "/Volumes/Backup Drive"
        studio.schedule = .daily(hour: 14, minute: 0)
        studio.lastResult = "45 copied (701.6 MB), 0 already there"
        studio.lastRun = Date().addingTimeInterval(-3600 * 3)
        studio.lastBytes = 701_600_000
        let photos = Job(title: "Photos")
        let store = JobStore(preview: [studio, photos])

        let surveys: [Source.ID: Survey] = Dictionary(uniqueKeysWithValues: zip(studio.sources.map(\.id), [
            survey(412_000_000, 23, toCopy: 0), survey(240_000_000, 19, toCopy: 2, bytesToCopy: 12_000_000), survey(50_000_000, 3, new: true), survey(8_000_000_000, 900, new: true),
        ]))
        var drives: [String: Drive] = ["/Volumes/Backup Drive": net]
        for s in studio.sources { drives[s.readPath] = mac }

        let running = Runner()
        running.running = true
        running.progress.filesDone = 31; running.progress.filesTotal = 45
        running.progress.bytesDone = 480_000_000; running.progress.bytesTotal = 701_600_000
        running.bytesPerSecond = 34_500_000
        running.progress.stage = .copying
        running.eta = 255
        running.debugAnchor(255)
        running.currentSource = "Workouts"
        running.pace = 0.3

        let update = UpdateInfo(version: "0.0.2", notes: "Folders with their own Finder icon show it.", history: [UpdateNote(version: "0.0.2", notes: "Folders with their own Finder icon show it.")])
        func window(_ job: Job, _ r: Runner, _ s: [Source.ID: Survey], _ d: [String: Drive], space: Bool, missing: Bool = false, update: UpdateInfo? = nil) -> AnyView {
            AnyView(VStack(spacing: 0) {
                TitleStrip(selection: .constant(job.id), drawn: true, previewUpdate: update)
                JobView(jobID: job.id, runnerOverride: r, destinationState: missing ? .folderMissing : .present, drives: d, presetSurveys: s,
                        space: space ? (free: 4_940_000_000_000, total: 4_950_000_000_000) : nil, preset: true)
            }.background(Palette.ground))
        }
        let screens: [(String, AnyView)] = [
            ("backup", window(studio, Runner(), surveys, drives, space: true)),
            ("running", window(studio, running, surveys, drives, space: true)),
            ("new", window(photos, Runner(), [:], [:], space: false)),
            ("missing", window(studio, Runner(), surveys, drives, space: true, missing: true)),
            ("update", window(studio, Runner(), surveys, drives, space: true, update: update)),
        ]
        let sheets: [(String, AnyView, CGSize)] = [
            ("settings", AnyView(SettingsSheet(view: JobView(storeOverride: store, jobID: studio.id, runnerOverride: Runner(), destinationState: .present, drives: drives, presetSurveys: surveys, space: nil, preset: true))), CGSize(width: 520, height: 780)),
            ("update-sheet", AnyView(UpdateSheet(update: update, current: "0.0.1", onLater: {}, onInstall: {})), CGSize(width: 480, height: 420)),
        ]
        for (name, dark) in [("dark", true), ("light", false)] {
            for (screen, view) in screens {
                save(view, size: CGSize(width: 860, height: 580), dark: dark, to: "\(dir)/\(screen)-\(name).png", store: store)
            }
            for (screen, view, size) in sheets {
                save(view, size: size, dark: dark, to: "\(dir)/\(screen)-\(name).png", store: store)
            }
        }
    }

    static func survey(_ bytes: Int64, _ files: Int, toCopy: Int = 0, bytesToCopy: Int64 = 0, new: Bool = false) -> Survey {
        var s = Survey()
        s.bytes = bytes; s.files = files; s.toCopy = new ? files : toCopy
        s.bytesToCopy = new ? bytes : bytesToCopy; s.destinationExists = !new
        return s
    }

    static func save(_ view: AnyView, size: CGSize, dark: Bool, to path: String, store: JobStore) {
        let content = view.environment(store).frame(width: size.width, height: size.height)
            .environment(\.colorScheme, dark ? .dark : .light)
        let host = NSHostingView(rootView: content)
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        host.frame = CGRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}
#endif
