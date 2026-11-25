import AppKit
import ArchivistCore
import ServiceManagement
import SwiftUI

/// One backup: Sources on the left (a list that grows and scrolls), the Destination fixed on
/// the right, the copy flowing across the seam between them, one button in the bottom bar.
struct JobView: View {
    @Environment(JobStore.self) private var envStore
    var storeOverride: JobStore? = nil                 // snapshots: a sheet drawn on its own
    var store: JobStore { storeOverride ?? envStore }
    let jobID: Job.ID
    var runnerOverride: Runner? = nil                  // snapshots
    var runner: Runner { runnerOverride ?? store.runner(for: jobID) }
    @State var interrupted = false
    @State var destinationState: DestinationState = .present
    enum DestinationState { case present, folderMissing, driveMissing }
    @State var drives: [String: Drive] = [:]          // path → drive, looked up off the main thread
    var presetSurveys: [Source.ID: Survey]? = nil      // snapshots
    var surveys: [Source.ID: Survey] { presetSurveys ?? store.surveys }
    @State var space: (free: Int64, total: Int64)?
    var preset = false                                 // snapshots pass everything in

    var job: Job { store.jobs.first { $0.id == jobID } ?? Job(title: "") }
    func edit(_ change: (inout Job) -> Void) {
        var j = job
        change(&j)
        store.update(j)
    }

    @State private var showingSettings = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                SourcesPane(view: self)
                DestinationPane(view: self)
                    .frame(width: 280)
            }
            BottomBar(view: self)
        }
        .background(Palette.ground)
        .overlay {
            if showingSettings {
                GeometryReader { g in
                    ZStack {
                        Color.black.opacity(0.35).ignoresSafeArea()
                            .contentShape(Rectangle())
                            .onTapGesture { showingSettings = false }   // a click outside closes it
                        SettingsSheet(view: self, close: { showingSettings = false })
                            .frame(width: 480, height: min(640, g.size.height - 32))   // never hangs past the window
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .shadow(color: .black.opacity(0.25), radius: 20, y: 6)
                    }
                    .frame(width: g.size.width, height: g.size.height)
                }
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: showingSettings)
        .onReceive(NotificationCenter.default.publisher(for: .showSettings)) { _ in showingSettings = true }
        .onExitCommand { showingSettings = false }
        .task(id: refreshKey) { await refresh() }
        .task(id: watchKey) {
            // Recheck when anything changes on either side (macOS file events; a network share
            // may not send them, so coming back to the app rechecks too).
            for await _ in FolderWatch.changes(of: watchPaths) where !runner.running { await refresh() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            store.reload()   // the background helper may have run something
            guard !runner.running else { return }
            Task { await refresh() }
        }
    }

    // MARK: looking things up

    private var refreshKey: String {
        job.sources.map { "\($0.path)|\($0.leftOut)|\($0.namesLeftOut)" }.joined() + (job.destination ?? "") + (job.lastResult ?? "") + "\(runner.running)"
    }

    private var watchPaths: [String] {
        job.sources.map(\.readPath) + (job.destination.map { [$0, ($0 as NSString).deletingLastPathComponent] } ?? [])
    }
    private var watchKey: String { watchPaths.joined(separator: "|") }

    func refresh() async {
        guard !preset else { return }
        let j = job
        var paths = j.sources.map(\.readPath)
        if let d = j.destination { paths.append(d) }
        for p in paths where drives[p] == nil {
            if let d = await Task.detached(operation: { try? Drive.of(path: p) }).value { drives[p] = d }
        }
        if let d = j.destination {
            space = await Task.detached { () -> (Int64, Int64)? in
                let v = try? URL(fileURLWithPath: d).resourceValues(forKeys: [.volumeAvailableCapacityKey, .volumeTotalCapacityKey])
                guard let free = v?.volumeAvailableCapacity, let total = v?.volumeTotalCapacity else { return nil }
                return (Int64(free), Int64(total))
            }.value.map { (free: $0.0, total: $0.1) }
        }
        // Is the destination still there? A deleted folder or an unplugged drive must say so.
        if let d = j.destination {
            destinationState = await Task.detached { () -> DestinationState in
                if FileManager.default.fileExists(atPath: d) { return .present }
                let comps = (d as NSString).pathComponents
                if comps.count > 2, comps[1] == "Volumes", !FileManager.default.fileExists(atPath: "/Volumes/" + comps[2]) { return .driveMissing }
                return .folderMissing
            }.value
        }
        // A run lock whose process is gone (or is this app, not copying now) = a backup that was cut off.
        let me = getpid()
        let busy = runner.running
        interrupted = await Task.detached { () -> Bool in
            j.sources.contains { s in
                guard let t = j.target(for: s),
                      let text = try? String(contentsOfFile: t + "/.archivist/run.lock", encoding: .utf8),
                      let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
                return pid == me ? !busy : kill(pid, 0) != 0 && errno != EPERM
            }
        }.value
        // Sizes first (local, quick): the bar and rows are right at once; then the comparison
        // with the destination, which can be slow on a busy or spinning drive.
        for s in j.sources where store.surveys[s.id] == nil {
            if let size = await Task.detached(operation: { try? Survey.size(of: s.readPath, excluded: Set(s.leftOut), patterns: s.namesLeftOut) }).value {
                store.surveys[s.id] = size
            }
        }
        for s in j.sources {
            let target = j.target(for: s) ?? "/nonexistent-archivist-destination"
            if let full = await Task.detached(operation: { try? Survey.of(source: s.readPath, destination: target, excluded: Set(s.leftOut), patterns: s.namesLeftOut) }).value {
                store.surveys[s.id] = full
            }
        }
    }

    /// The drive under a path; the destination wears the kind set in Settings, if any.
    func drive(_ path: String?) -> Drive? {
        guard let d = path.flatMap({ drives[$0] }) else { return nil }
        guard path == job.destination, let k = job.destinationKind else { return d }
        return Drive(mountPoint: d.mountPoint, fileSystem: d.fileSystem, device: d.device, kind: k, name: d.name)
    }
    func detectedKind(_ path: String?) -> DriveKind? { path.flatMap { drives[$0] }?.kind }

    // MARK: actions

    func backUp() {
        let live = job.sources.filter { !$0.skip }.compactMap { surveys[$0.id] }.filter(\.compared)
        store.start(job.id, planned: (live.reduce(0) { $0 + $1.toCopy }, live.reduce(0) { $0 + $1.bytesToCopy }))
    }

    func add(_ urls: [URL]) {
        edit { _ = $0.addSources(urls.map(\.path)) }
    }

    func chooseFolders() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        guard panel.runModal() == .OK else { return }
        add(panel.urls)
    }

    func chooseDestination() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Back up here"
        if let current = job.destination { panel.directoryURL = URL(fileURLWithPath: current) }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        setDestination(url.path)
    }

    /// Same destination, same animal: the backup's look follows it until picked by hand.
    func setDestination(_ path: String) {
        edit { j in
            j.destination = path
            if !j.lookChosen { let l = Contrast.look(for: path, pool: Job.icons); j.icon = l.icon; j.color = l.color }
        }
    }


    /// Pick folders inside a source to leave out of the copy (a Dropbox folder, a cloud drive's cache).
    func exclude(in s: Source) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: s.readPath)
        panel.prompt = "Exclude"
        guard panel.runModal() == .OK else { return }
        let root = URL(fileURLWithPath: s.readPath).resolvingSymlinksInPath().path
        // Stored relative to the source; a folder outside it can't be excluded from it.
        let rel = panel.urls.compactMap { u -> String? in
            let p = u.resolvingSymlinksInPath().path
            return p.hasPrefix(root + "/") ? String(p.dropFirst(root.count + 1)) : nil
        }
        update(s) { $0.leftOut = Array(Set($0.leftOut + rel)).sorted() }
    }

    func update(_ s: Source, _ change: (inout Source) -> Void) {
        edit { j in if let i = j.sources.firstIndex(where: { $0.id == s.id }) { change(&j.sources[i]) } }
    }

}

// MARK: - Sources

/// Both panes' titles sit in boxes of one height, so "Sources" and "Destination" share a line.
enum Header { static let height: CGFloat = 40; static let below: CGFloat = 8 }

struct SourcesPane: View {
    let view: JobView
    @State private var over = false

    var body: some View {
        let job = view.job
        let total = job.sources.filter { !$0.skip }.compactMap { view.surveys[$0.id]?.bytes }.reduce(0, +)
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Sources").font(Typeface.title(24)).foregroundStyle(Palette.ink)
                AddButton(view: view)
                Spacer()
                if !job.sources.isEmpty {
                    Text("\(job.sources.count) \(job.sources.count == 1 ? "item" : "items"), \(bytes(total))")
                        .font(Typeface.text(13)).foregroundStyle(Palette.soft)
                }
            }
            .padding(.horizontal, 28)
            .frame(height: Header.height, alignment: .bottom).padding(.bottom, Header.below)   // same box as Destination's

            if job.sources.isEmpty {
                DropHint(text: "Drop folders or a drive here", action: view.chooseFolders)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ThinScroll {
                    VStack(spacing: 0) {
                        ForEach(job.sources) { s in
                            SourceRow(view: view, source: s)
                            Rectangle().fill(Palette.rule).frame(height: 1).padding(.leading, 76)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Palette.accent.opacity(over ? 0.8 : 0), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])).padding(8))
        .dropDestination(for: URL.self) { urls, _ in
            let dirs = urls.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            guard !dirs.isEmpty else { return false }   // allowed mid-backup: the running copy took its list at Start
            view.add(dirs)
            return true
        } isTargeted: { over = $0 }
    }
}

struct SourceRow: View {
    let view: JobView
    let source: Source

    var body: some View {
        let s = source
        HStack(spacing: 14) {
            Group {
                if s.hasCustomIcon {   // the person's own Finder icon, as Finder shows it
                    Image(nsImage: NSWorkspace.shared.icon(forFile: s.path)).resizable().interpolation(.high).frame(width: 40, height: 40)
                } else {
                    Badge(icon: s.isDrive ? driveSymbol(view.drive(s.readPath)) : s.icon, hex: s.color, size: 38)
                }
            }
                .opacity(s.skip ? 0.4 : 1)
                .background(Splash(hex: s.color, addedAt: s.addedAt))
            VStack(alignment: .leading, spacing: 3) {
                Text(s.name).font(Typeface.text(15, .semibold)).foregroundStyle(Palette.ink.opacity(s.skip ? 0.5 : 1))
                Text(status).font(Typeface.text(12.5)).foregroundStyle(statusColor).lineLimit(1)
            }
            Spacer(minLength: 8)
            Menu {
                Button { view.update(s) { $0.skipJunk = true } } label: {
                    Text("Skip junk files") + Text(s.skipJunk ? "  ✓" : "")
                }
                Button { view.update(s) { $0.skipJunk = false } } label: {
                    Text("Copy everything") + Text(s.skipJunk ? "" : "  ✓")
                }
                Divider()
                Button("Exclude a folder…") { view.exclude(in: s) }
                ForEach(s.leftOut, id: \.self) { rel in
                    Button("Include \((rel as NSString).lastPathComponent) again") { view.update(s) { $0.leftOut.removeAll { $0 == rel } } }
                }
            } label: {
                Text((s.skipJunk ? "Skip junk files" : "Copy everything")
                     + (s.leftOut.isEmpty ? "" : ", \(s.leftOut.count) excluded")).font(Typeface.text(12.5))
            }
            .menuStyle(.borderlessButton).fixedSize()
            .tint(Palette.soft)
            .help("Junk files: caches, temp files, and build folders that rebuild from the code beside them")
            Button { view.edit { $0.sources.removeAll { $0.id == s.id } } } label: {
                Image(systemName: "xmark.circle.fill").font(.system(size: 17))
            }
            .buttonStyle(.plain).foregroundStyle(Palette.soft)
            .help("Remove \(s.name) from Sources")
        }
        .padding(.horizontal, 28).padding(.vertical, 12)
        .allowsHitTesting(!view.runner.running)
        .help(s.path)
    }

    private var survey: Survey? { view.surveys[source.id] }

    private var status: String {
        if source.skip { return "Paused" }
        guard let v = survey else { return "Calculating…" }
        let size = bytes(v.bytes)
        if !v.compared { return "\(size), calculating…" }
        if !v.destinationExists { return "\(size), not backed up yet" }
        if v.toCopy == 0 { return "\(size), up to date" }
        if v.bytesToCopy >= v.bytes { return "\(size), not backed up yet" }   // everything is new: the same size twice says nothing
        return v.bytesToCopy > 0 ? "\(size), \(bytes(v.bytesToCopy)) to back up" : "\(size), small changes to back up"
    }

    private var statusColor: Color {
        guard let v = survey, v.compared, !source.skip else { return Palette.soft }
        return !v.destinationExists || v.toCopy > 0 ? Palette.ink : Palette.soft   // not the red: it would read as an error
    }

}

struct DropHint: View {
    var icon = "outbox_tray"
    let text: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(spacing: 10) {
                Emoji(name: icon, size: 40)
                Text(text).font(Typeface.text(14, .medium)).foregroundStyle(Palette.soft)
                Text("or click to choose").font(Typeface.text(12)).foregroundStyle(Palette.soft.opacity(0.8))
            }
            .padding(28)
            .background(RoundedRectangle(cornerRadius: 16).strokeBorder(Palette.rule, style: StrokeStyle(lineWidth: 2, dash: [7, 6])))
            .contentShape(RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Destination

struct DestinationPane: View {
    let view: JobView
    @State private var over = false

    var body: some View {
        let job = view.job
        let d = view.drive(job.destination)
        let needed = job.sources.filter { !$0.skip }.compactMap { view.surveys[$0.id] }.filter(\.compared).reduce(Int64(0)) { $0 + $1.bytesToCopy }
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Destination").font(Typeface.title(24)).foregroundStyle(Palette.ink)
                Spacer()
                Button { NotificationCenter.default.post(name: .showSettings, object: nil) } label: { Emoji(name: "gear", size: 20) }
                    .buttonStyle(.plain).help("Settings: name, picture, schedule, drive type, delete")
            }
            .frame(height: Header.height, alignment: .bottom).padding(.bottom, Header.below)   // same box as Sources'

            if let path = job.destination, view.destinationState != .present {
                Missing(view: view, path: path)
            } else if let path = job.destination {
                VStack(spacing: 8) {
                    Badge(icon: job.icon, hex: job.color, size: 66)
                        .overlay(alignment: .bottomTrailing) {
                            if let d { Emoji(name: driveSymbol(d), size: 22).padding(3).background(Circle().fill(Palette.raised)).offset(x: 8, y: 4) }
                        }
                    Text(location(path, d)).font(Typeface.text(15, .semibold)).foregroundStyle(Palette.ink)
                        .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                    if let d { Text(kindWords(d) + (job.destinationKind == nil ? "" : ", set by hand")).font(Typeface.text(12)).foregroundStyle(Palette.soft) }
                }
                .frame(maxWidth: .infinity)

                if let space = view.space { SpaceBar(free: space.free, total: space.total, needed: needed, hex: job.color).padding(.top, 14) }

                HStack(spacing: 8) {
                    Button("Change location", action: view.chooseDestination).buttonStyle(QuietButton())
                    Button { NSWorkspace.shared.open(URL(fileURLWithPath: path)) } label: { Image(systemName: "magnifyingglass") }
                        .buttonStyle(QuietButton()).help("Open in Finder")
                }
                .frame(maxWidth: .infinity).padding(.top, 12)
                .allowsHitTesting(!view.runner.running)

                Spacer(minLength: 8)

                Group {
                    if view.runner.running {
                        Button(view.runner.stopping ? "Stopping…" : "Stop") { view.runner.stop() }.buttonStyle(QuietButton())
                            .disabled(view.runner.stopping)
                    } else {
                        Button("Start backup", action: view.backUp).buttonStyle(PrimaryButton()).disabled(!job.ready || view.destinationState != .present)
                            .keyboardShortcut(.return, modifiers: .command)
                    }
                }
                .frame(maxWidth: .infinity)

                Spacer(minLength: 8)   // Start sits centred between Change location and the last backup
                if view.interrupted && !view.runner.running {
                    Text("The last backup was cut off. Start it again to finish; nothing half-copied is kept.")
                        .font(Typeface.text(11.5, .semibold)).foregroundStyle(Palette.warn)
                        .fixedSize(horizontal: false, vertical: true).padding(.top, 8)
                }
                if !view.runner.running && !view.runner.problems.isEmpty {
                    ProblemsLink(list: view.runner.problems).frame(maxWidth: .infinity).padding(.top, 6)
                }
                Button { NotificationCenter.default.post(name: .showSettings, object: nil) } label: {
                    HStack(spacing: 5) {
                        Emoji(name: "spiral_calendar", size: 13)
                        Text(job.schedule == .byHand ? "Schedule: —" : job.schedule.words)
                            .font(Typeface.text(12)).foregroundStyle(Palette.soft).lineLimit(1)
                    }
                }
                .buttonStyle(.plain).frame(maxWidth: .infinity).padding(.top, 8)
                Text("Last backup: " + (job.lastRun.map { lastWords($0, job.lastBytes) } ?? "—"))
                    .font(Typeface.text(12)).foregroundStyle(Palette.soft).frame(maxWidth: .infinity).padding(.top, 3)
            } else {
                DropHint(icon: job.icon, text: "Drop the destination folder here", action: view.chooseDestination)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(.horizontal, 24).padding(.bottom, 18)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Palette.raised)
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Palette.accent.opacity(over ? 0.8 : 0), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])).padding(8))
        .dropDestination(for: URL.self) { urls, _ in
            guard let dir = urls.first(where: { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }),
                  !view.runner.running else { return false }
            view.setDestination(dir.path)
            return true
        } isTargeted: { over = $0 }
    }

    private func lastWords(_ when: Date, _ size: Int64?) -> String {
        let f = DateFormatter()
        f.doesRelativeDateFormatting = true
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: when) + (size.map { ", " + bytes($0) } ?? "")
    }

    /// "My Drive / Backups": the drive, then the folder inside it (just the drive at its top).
    private func location(_ path: String, _ d: Drive?) -> String {
        guard let d else { return (path as NSString).lastPathComponent }
        guard path != d.mountPoint else { return d.name }
        // On the Mac's own drive, /Users/... is the same place as /System/Volumes/Data/Users/...
        let root = d.mountPoint == "/System/Volumes/Data" && !path.hasPrefix(d.mountPoint + "/") ? "" : d.mountPoint
        let inside = path.hasPrefix(root + "/") ? String(path.dropFirst(root.count + 1)) : (path as NSString).lastPathComponent
        let parts = inside.split(separator: "/").map(String.init)
        // Drive, then the folder; a long way down shows as "…" in the middle.
        return ([d.name] + (parts.count > 2 ? [parts[0], "…", parts.last!] : parts)).joined(separator: " / ")
    }
}

/// The destination folder or its drive is gone: say which, and offer the way back.
struct Missing: View {
    let view: JobView
    let path: String
    var body: some View {
        let comps = (path as NSString).pathComponents
        let drive = comps.count > 2 && comps[1] == "Volumes" ? comps[2] : "This Mac"
        let folder = (path as NSString).lastPathComponent
        VStack(spacing: 12) {
            Badge(icon: view.job.icon, hex: view.job.color, size: 66).opacity(0.5)
            Text(view.destinationState == .driveMissing ? "\(drive) isn't connected" : "\(folder) not found on \(drive)")
                .font(Typeface.text(15, .semibold)).foregroundStyle(Palette.warn).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if view.destinationState == .folderMissing {
                Button("Create it again") {
                    try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false)
                    Task { await view.refresh() }
                }.buttonStyle(PrimaryButton())
            }
            Button("Change location", action: view.chooseDestination).buttonStyle(QuietButton())
        }
        .frame(maxWidth: .infinity).padding(.top, 10)
    }
}

struct ProblemsLink: View {
    let list: [String]
    @State private var open = false
    var body: some View {
        Button(list.count == 1 ? "1 file not copied" : "\(list.count) files not copied") { open = true }
            .buttonStyle(.plain).font(Typeface.text(12, .semibold)).foregroundStyle(Palette.warn)
            .popover(isPresented: $open) { Problems(list: list).padding(16).frame(width: 380) }
    }
}

/// Free space on the destination, and whether this backup fits.
struct SpaceBar: View {
    let free: Int64
    let total: Int64
    let needed: Int64
    var hex = Nippon.colors[4].hex   // the backup's own colour

    var body: some View {
        let used = Double(total - free) / Double(max(total, 1))
        let after = min(1, used + Double(needed) / Double(max(total, 1)))
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    // In the backup's colours: what is already on the drive soft, what this backup adds full.
                    Capsule().fill(Palette.rule)
                    Capsule().fill(Nippon.color(hex)).frame(width: g.size.width * after)
                    Capsule().fill(Nippon.soft(hex)).frame(width: g.size.width * used)
                }
            }
            .frame(height: 8)
            Text("\(bytes(free)) free of \(bytes(total))").font(Typeface.text(12)).foregroundStyle(Palette.soft)
            if needed > 0 {
                Text(needed <= free ? "This backup needs \(bytes(needed))" : "Needs \(bytes(needed)): \(bytes(needed - free)) more than is free")
                    .font(Typeface.text(12, needed <= free ? .regular : .semibold))
                    .foregroundStyle(needed <= free ? Palette.ink : Palette.warn)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Bottom bar: one fat bar, a chunk per source in that source's colour

/// Each source is a chunk as wide as its share of the bytes, its picture above it (the source
/// being copied is lit). Nothing written inside the bar. It fills left to right and never moves
/// back; a light grey scan crosses it while the time left is worked out. Time sits below.
struct BottomBar: View {
    let view: JobView
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let job = view.job
        // Real sizes only: until every source's size is known, a plain track instead of made-up chunks.
        let known = job.sources.filter { !$0.skip }.allSatisfy { view.surveys[$0.id] != nil }
        let chunks = known ? job.sources.filter { !$0.skip }.map { (s: $0, b: max(view.surveys[$0.id]?.bytes ?? 1, 1)) } : []
        let total = max(chunks.reduce(Int64(0)) { $0 + $1.b }, 1)
        TimelineView(.periodic(from: .now, by: view.runner.running && view.runner.remaining(at: .now) == nil ? 0.25 : 1)) { tl in
            let r = view.runner
            let estimating = r.running && !r.finishing && r.remaining(at: tl.date) == nil
            GeometryReader { g in
                let w = g.size.width - Double(3 * max(chunks.count - 1, 0))
                VStack(alignment: .leading, spacing: 5) {
                    ZStack(alignment: .leading) {
                        if chunks.isEmpty { Rectangle().fill(Palette.rule) }
                        HStack(spacing: 3) {
                            ForEach(chunks, id: \.s.id) { c in
                                Rectangle().fill(scheme == .dark ? Nippon.color(c.s.color).opacity(0.18) : Nippon.soft(c.s.color, white: 0.25).opacity(0.5))
                                    .frame(width: max(4, w * Double(c.b) / Double(total)))
                            }
                        }
                        if r.running && !estimating {
                            HStack(spacing: 3) {
                                ForEach(chunks, id: \.s.id) { c in
                                    // Dark: the soft colours of the circles; full strength glared on a dark track.
                                    Rectangle().fill(scheme == .dark ? Nippon.soft(c.s.color, white: 0.3) : Nippon.color(c.s.color))
                                        .frame(width: max(4, w * Double(c.b) / Double(total)))
                                }
                            }
                            .mask(alignment: .leading) {
                                Rectangle().frame(width: g.size.width * r.steadyFraction(at: tl.date))
                                    .animation(.linear(duration: 1), value: r.steadyFraction(at: tl.date))
                            }
                        }
                        if estimating {
                            // Working out the time: each chunk breathes in its own soft colour.
                            let breath = 0.5 + 0.5 * sin(tl.date.timeIntervalSinceReferenceDate * 2.2)
                            HStack(spacing: 3) {
                                ForEach(chunks, id: \.s.id) { c in
                                    Rectangle().fill(scheme == .light ? Nippon.color(c.s.color).opacity(0.35 + 0.45 * breath)
                                                                      : Nippon.soft(c.s.color, white: 0.3).opacity(0.25 + 0.3 * breath))
                                        .frame(width: max(4, w * Double(c.b) / Double(total)))
                                }
                            }
                            .animation(.easeInOut(duration: 0.5), value: breath)
                        }
                    }
                    .frame(height: 28)
                    .clipped()
                    Text(r.stopping ? "Stopping…" : r.finishing ? "Finishing…"
                         : r.running ? (estimating ? "Calculating time left…" : "\(Int(r.steadyFraction(at: tl.date) * 100))% done, \(r.etaWords(at: tl.date))")
                         : (job.ready && view.destinationState == .present ? "Ready to start" : " "))
                        .font(r.running && !estimating ? Typeface.number(12.5) : Typeface.text(12))
                        .foregroundStyle(r.running ? Palette.ink : Palette.soft)
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .frame(height: 28 + 5 + 16)
        .padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 6)
        .background(Palette.ground)
        .overlay(alignment: .top) { Rectangle().fill(Palette.rule).frame(height: 1) }
    }
}

/// The + beside "Sources": a whole drive, or folders.
struct AddButton: View {
    let view: JobView
    @State private var open = false
    var body: some View {
        Button { open = true } label: { Image(systemName: "plus.circle.fill").font(.system(size: 18)).foregroundStyle(Palette.accent) }
            .buttonStyle(.plain).help("Add a drive or folders")
            .allowsHitTesting(!view.runner.running)
            .popover(isPresented: $open, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("A whole drive").font(Typeface.text(12, .medium)).foregroundStyle(Palette.soft).padding(.bottom, 2)
                    ForEach(Volumes.mounted()) { v in
                        Button { open = false; view.add([URL(fileURLWithPath: v.path)]) } label: {
                            HStack(spacing: 8) { Emoji(name: v.path == "/" ? "laptop" : "floppy_disk", size: 18); Text(v.name) }
                                .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        }.buttonStyle(.plain).padding(.vertical, 4)
                    }
                    Divider().padding(.vertical, 6)
                    Button { open = false; view.chooseFolders() } label: {
                        HStack(spacing: 8) { Emoji(name: "file_folder", size: 18); Text("Choose folders…") }
                            .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
                .font(Typeface.text(13)).foregroundStyle(Palette.ink)
                .padding(16).frame(width: 240)
            }
    }
}

// MARK: - pieces

/// Fluent emoji for a drive: the Mac's own, an SSD, a disk that spins, a network share.
func driveSymbol(_ d: Drive?) -> String {
    switch d?.kind {
    case .ssd?: return d?.mountPoint == "/" || d?.mountPoint == "/System/Volumes/Data" ? "laptop" : "floppy_disk"
    case .spinning?, .unknown?: return "optical_disk"
    case .network?: return "globe_with_meridians"
    case nil: return "floppy_disk"
    }
}

func kindWords(_ d: Drive) -> String {
    let fs = ["apfs": "APFS", "hfs": "Mac OS Extended", "exfat": "exFAT", "msdos": "FAT", "smbfs": "SMB"][d.fileSystem] ?? d.fileSystem
    switch d.kind {
    case .ssd: return "Solid state, \(fs)"
    case .spinning: return "Spinning disk, \(fs)"
    case .unknown: return "Probably spinning, \(fs)"
    case .network: return "Network drive, \(fs)"
    }
}

func bytes(_ n: Int64) -> String { ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }

struct Problems: View {
    let list: [String]
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(list.count == 1 ? "One thing could not be copied" : "\(list.count) things could not be copied")
                .font(Typeface.text(13, .semibold)).foregroundStyle(Palette.warn)
            ForEach(list.prefix(8), id: \.self) { Text($0).font(Typeface.text(12)).foregroundStyle(Palette.soft).fixedSize(horizontal: false, vertical: true) }
            if list.count > 8 { Text("and \(list.count - 8) more").font(Typeface.text(12)).foregroundStyle(Palette.soft) }
            if list.contains(where: { $0.contains("Operation not permitted") }) {
                Text("Some folders need Full Disk Access: System Settings → Privacy & Security → Full Disk Access → turn on Archivist.")
                    .font(Typeface.text(12)).foregroundStyle(Palette.ink).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// File-change events for some folders, as an async stream (FSEvents, 1.5 s latency).
enum FolderWatch {
    final class Box { let c: AsyncStream<Void>.Continuation; init(_ c: AsyncStream<Void>.Continuation) { self.c = c } }

    static func changes(of paths: [String]) -> AsyncStream<Void> {
        AsyncStream { continuation in
            guard !paths.isEmpty else { continuation.finish(); return }
            let box = Unmanaged.passRetained(Box(continuation))
            var ctx = FSEventStreamContext(version: 0, info: box.toOpaque(), retain: nil, release: nil, copyDescription: nil)
            let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
                Unmanaged<Box>.fromOpaque(info!).takeUnretainedValue().c.yield()
            }
            guard let stream = FSEventStreamCreate(nil, callback, &ctx, paths as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                                                   1.5, FSEventStreamCreateFlags(kFSEventStreamCreateFlagNone)) else {
                box.release(); continuation.finish(); return
            }
            FSEventStreamSetDispatchQueue(stream, .main)
            FSEventStreamStart(stream)
            continuation.onTermination = { _ in
                FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream); box.release()
            }
        }
    }
}

/// The one place to change a backup: name, picture and colour, schedule, drive type,
/// appearance, and deleting it.
struct SettingsSheet: View {
    let view: JobView
    var close: () -> Void = {}
    @Environment(JobStore.self) private var store
    @AppStorage("appearance") private var appearance = "system"
    @State private var name = ""
    @State private var confirmDelete = false

    var body: some View {
        let job = view.job
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 14) {
                    Badge(icon: job.icon, hex: job.color, size: 56)
                    TextField("Name this backup", text: $name)
                        .textFieldStyle(.plain).font(Typeface.title(24)).foregroundStyle(Palette.ink)
                        .onSubmit(saveName)
                }

                section("Picture") {
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(34), spacing: 6), count: 9), spacing: 6) {
                        ForEach(Job.icons, id: \.self) { n in
                            Button { view.edit { $0.icon = n; $0.lookChosen = true } } label: {
                                Emoji(name: n, size: 22).frame(width: 34, height: 34)
                                    .background(Circle().strokeBorder(n == job.icon ? Palette.ink : .clear, lineWidth: 2))
                            }.buttonStyle(.plain)
                        }
                    }
                }
                section("Colour") {
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(26), spacing: 8), count: 12), spacing: 8) {
                        ForEach(Nippon.colors, id: \.hex) { c in
                            Button { view.edit { $0.color = c.hex; $0.lookChosen = true } } label: {
                                Circle().fill(Nippon.color(c.hex)).frame(width: 26, height: 26)
                                    .overlay(Circle().strokeBorder(c.hex == job.color ? Palette.ink : .clear, lineWidth: 2.5).padding(-3))
                            }.buttonStyle(.plain).help(c.name)
                        }
                    }
                }

                section("Schedule") { ScheduleChooser(view: view) }

                section("Earlier versions") {
                    Toggle("Keep deleted files", isOn: Binding(get: { job.keepDeleted }, set: { v in view.edit { $0.keepDeleted = v } }))
                    Toggle("Keep earlier versions of changed files", isOn: Binding(get: { job.keepChanged }, set: { v in view.edit { $0.keepChanged = v } }))
                    HStack(spacing: 8) {
                        Text("Remove after").foregroundStyle(Palette.soft)
                        Picker("", selection: Binding(get: { job.keepDays ?? 0 }, set: { v in view.edit { $0.keepDays = v == 0 ? nil : v } })) {
                            Text("30 days").tag(30); Text("90 days").tag(90); Text("1 year").tag(365); Text("Never").tag(0)
                        }.labelsHidden().fixedSize()
                    }
                    Toggle("Make room when the drive is nearly full (oldest first)", isOn: Binding(get: { job.makeRoom }, set: { v in view.edit { $0.makeRoom = v } }))
                }

                section("Destination drive type") {
                    Picker("", selection: Binding(get: { job.destinationKind?.rawValue ?? "auto" },
                                                  set: { v in view.edit { $0.destinationKind = DriveKind(rawValue: v) } })) {
                        Text("Automatic" + (view.detectedKind(job.destination).map { ": \(words($0))" } ?? "")).tag("auto")
                        Text("Solid state (SSD)").tag(DriveKind.ssd.rawValue)
                        Text("Spinning disk").tag(DriveKind.spinning.rawValue)
                    }
                    .pickerStyle(.radioGroup).labelsHidden()
                }

                section("Appearance") {
                    Picker("", selection: $appearance) {
                        Text("Follow the Mac").tag("system")
                        Text("Light").tag("light")
                        Text("Dark").tag("dark")
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()   // fixed: a hidden label's room shifted it per selection
                }

                Divider()
                HStack {
                    Button("Delete this backup…", role: .destructive) { confirmDelete = true }
                        .foregroundStyle(Palette.warn)
                    Spacer()
                    Button("Done") { saveName(); close() }.keyboardShortcut(.defaultAction)
                }
            }
            .padding(26)
        }
        .background(Palette.ground)
        .onAppear { name = job.title }
        .alert("Delete “\(job.title)”?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) { close(); store.remove(job.id) }
            Button("Keep", role: .cancel) {}
        } message: {
            Text("Only this backup's setup is removed. The copies it already made stay on the destination drive.")
        }
    }

    private func saveName() {
        let t = name.trimmingCharacters(in: .whitespaces)
        if !t.isEmpty { view.edit { $0.title = t } }
    }

    @ViewBuilder private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(Typeface.text(13, .semibold)).foregroundStyle(Palette.ink)
            content()
        }
    }

    private func words(_ k: DriveKind) -> String {
        switch k { case .ssd: return "solid state"; case .spinning: return "spinning"; case .unknown: return "probably spinning"; case .network: return "network" }
    }
}

/// Flat blobs of a source's colour bursting out from behind its picture when it is dropped in.
struct Splash: View {
    let hex: String
    let addedAt: Date?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var out = false
    @State private var shown = false
    private let blobs: [(angle: Double, size: CGFloat, reach: CGFloat)] =
        [(0, 12, 34), (55, 8, 30), (110, 14, 38), (170, 9, 28), (225, 13, 36), (290, 7, 26), (330, 10, 32)]

    var body: some View {
        ZStack {
            if shown {
                Circle().fill(Nippon.soft(hex, white: 0.2)).frame(width: out ? 70 : 30, height: out ? 70 : 30).opacity(out ? 0 : 0.8)
                ForEach(blobs.indices, id: \.self) { i in
                    let b = blobs[i]
                    Circle().fill(Nippon.soft(hex, white: 0.1))
                        .frame(width: b.size, height: b.size)
                        .offset(x: out ? cos(b.angle * .pi / 180) * b.reach : 0, y: out ? sin(b.angle * .pi / 180) * b.reach : 0)
                        .scaleEffect(out ? 0.3 : 1)
                        .opacity(out ? 0 : 1)
                }
            }
        }
        .allowsHitTesting(false)
        .onAppear {
            guard !reduceMotion, let t = addedAt, Date().timeIntervalSince(t) < 2 else { return }
            shown = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { withAnimation(.easeOut(duration: 0.75)) { out = true } }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { shown = false }
        }
    }
}

/// A thin bar drawn over the list (the system one, set to "always", took room and pushed the
/// row buttons left). Shows while scrolling and briefly whenever the list overflows.
struct ThinScroll<Content: View>: View {
    @ViewBuilder let content: Content
    @State private var offset: CGFloat = 0
    @State private var contentHeight: CGFloat = 1
    @State private var visible = false
    @State private var hide: DispatchWorkItem?

    var body: some View {
        GeometryReader { outer in
            ScrollView {
                content
                    .background(GeometryReader { g in
                        Color.clear.preference(key: ScrollBox.self, value: [g.frame(in: .named("thin")).minY, g.size.height])
                    })
            }
            .scrollIndicators(.never)
            .coordinateSpace(name: "thin")
            .onPreferenceChange(ScrollBox.self) { v in
                guard v.count == 2 else { return }
                let moved = abs(-v[0] - offset) > 0.5
                offset = -v[0]; contentHeight = max(v[1], 1)
                if moved || contentHeight > outer.size.height { flash() }
            }
            .overlay(alignment: .topTrailing) {
                let view = outer.size.height
                if contentHeight > view + 1 {
                    let length = max(28, view * view / contentHeight)
                    let travel = view - length
                    let y = travel * min(1, max(0, offset / (contentHeight - view)))
                    Capsule().fill(Palette.soft.opacity(0.55))
                        .frame(width: 4, height: length)
                        .offset(x: -4, y: y)
                        .opacity(visible ? 1 : 0)
                        .animation(.easeOut(duration: 0.25), value: visible)
                        .allowsHitTesting(false)
                }
            }
        }
    }

    private func flash() {
        visible = true
        hide?.cancel()
        let w = DispatchWorkItem { visible = false }
        hide = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: w)
    }
}

struct ScrollBox: PreferenceKey {
    static var defaultValue: [CGFloat] = []
    static func reduce(value: inout [CGFloat], nextValue: () -> [CGFloat]) { let n = nextValue(); if !n.isEmpty { value = n } }
}

/// Manually, When connected; then the clock ones, each with its own picker right under it.
struct ScheduleChooser: View {
    let view: JobView

    var body: some View {
        let s = view.job.schedule
        VStack(alignment: .leading, spacing: 6) {
            option("Manually", on: s == .byHand) { .byHand }
            option("When connected", on: s == .whenConnected) { .whenConnected }
            Spacer().frame(height: 6)
            option("Once an hour", on: { if case .hourly = s { return true }; return false }()) { .hourly(minute: 0) }
            if case let .hourly(m) = s {
                HStack(spacing: 6) {
                    Text("at minute").foregroundStyle(Palette.soft)
                    Picker("", selection: Binding(get: { m }, set: { v in view.edit { $0.schedule = .hourly(minute: v) } })) {
                        ForEach(Array(stride(from: 0, to: 60, by: 5)), id: \.self) { Text(String(format: ":%02d", $0)).tag($0) }
                    }.labelsHidden().fixedSize()
                }.padding(.leading, 22)
            }
            option("Once a day", on: { if case .daily = s { return true }; return false }()) { .daily(hour: 14, minute: 0) }
            if case let .daily(h, m) = s {
                HStack(spacing: 6) {
                    Text("at").foregroundStyle(Palette.soft)
                    time(h, m) { nh, nm in .daily(hour: nh, minute: nm) }
                }.padding(.leading, 22)
            }
            option("Once a week", on: { if case .weekly = s { return true }; return false }()) { .weekly(weekday: 2, hour: 14, minute: 0) }
            if case let .weekly(d, h, m) = s {
                HStack(spacing: 6) {
                    Text("on").foregroundStyle(Palette.soft)
                    Picker("", selection: Binding(get: { d }, set: { v in view.edit { $0.schedule = .weekly(weekday: v, hour: h, minute: m) } })) {
                        ForEach(1...7, id: \.self) { Text(Calendar.current.weekdaySymbols[$0 - 1]).tag($0) }
                    }.labelsHidden().fixedSize()
                    Text("at").foregroundStyle(Palette.soft)
                    time(h, m) { nh, nm in .weekly(weekday: d, hour: nh, minute: nm) }
                }.padding(.leading, 22)
            }
        }
        .font(Typeface.text(13))
    }

    private func option(_ title: String, on: Bool, _ make: @escaping () -> Schedule) -> some View {
        Button { if !on { view.edit { $0.schedule = make() } } } label: {
            HStack(spacing: 8) {
                Circle().strokeBorder(on ? Palette.accent : Palette.soft, lineWidth: on ? 5 : 1.5).frame(width: 15, height: 15)
                Text(title).foregroundStyle(Palette.ink)
            }.contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    private func time(_ h: Int, _ m: Int, _ make: @escaping (Int, Int) -> Schedule) -> some View {
        DatePicker("", selection: Binding(
            get: { Calendar.current.date(bySettingHour: h, minute: m, second: 0, of: Date()) ?? Date() },
            set: { d in
                let c = Calendar.current.dateComponents([.hour, .minute], from: d)
                view.edit { $0.schedule = make(c.hour ?? h, c.minute ?? m) }
            }), displayedComponents: .hourAndMinute)
        .labelsHidden().datePickerStyle(.stepperField).fixedSize()   // the Mac's own 12/24-hour clock
    }
}

extension Notification.Name {
    static let showSettings = Notification.Name("ArchivistShowSettings")
}
