import AppKit
import ArchivistCore
import os
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
    // The walk and its running count live in the store, not the tab: a walk keeps going while
    // another tab is open, and coming back shows its count where it got to (Helios, 2026-11-28).
    var measuring: Bool { store.measuringJobs.contains(job.id) }
    var counted: [Source.ID: Int] { store.counted }
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
    @State private var showingProblems = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 0) {   // top: a tall column never pushes its title up
                SourcesPane(view: self).frame(minHeight: 0)
                DestinationPane(view: self)
                    .frame(width: 280)
                    .frame(minHeight: 0, maxHeight: .infinity, alignment: .top).clipped()   // never taller than Sources, and no say in the window's smallest size (Start ↔ Stop changed it)
                    
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
                            .frame(width: SettingsSheet.width)   // fixed: choosing something never resizes it
                            .frame(height: min(700, g.size.height - 32))   // never hangs past the window
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .shadow(color: .black.opacity(0.25), radius: 20, y: 6)
                    }
                    .frame(width: g.size.width, height: g.size.height)
                }
                .transition(.opacity)
            }
        }
        .overlay {
            if showingProblems {
                GeometryReader { g in
                    ZStack {
                        Color.black.opacity(0.35).ignoresSafeArea().contentShape(Rectangle())
                            .onTapGesture { showingProblems = false }
                        VStack(alignment: .leading, spacing: 14) {
                            HStack {
                                Emoji(name: "warning", size: 22)
                                Text("Not copied").font(Typeface.title(20)).foregroundStyle(Palette.ink)
                                Spacer()
                                Button { showingProblems = false } label: { Image(systemName: "xmark").font(.system(size: 13, weight: .semibold)) }
                                    .buttonStyle(.plain).foregroundStyle(Palette.soft)
                            }
                            ScrollView { Problems(list: runner.problems).frame(maxWidth: .infinity, alignment: .leading) }
                            Text("Files in use were tried again at the end; the next backup copies the rest.").font(Typeface.text(12)).foregroundStyle(Palette.soft)
                        }
                        .padding(24)
                        .frame(width: SettingsSheet.width).frame(maxHeight: min(420, g.size.height - 32))
                        .fixedSize(horizontal: false, vertical: true)
                        .background(Palette.ground)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .shadow(color: .black.opacity(0.25), radius: 20, y: 6)
                    }
                    .frame(width: g.size.width, height: g.size.height)
                }
                .transition(.opacity)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .showProblems)) { _ in showingProblems = true }
        .animation(.easeOut(duration: 0.15), value: showingSettings)
        .animation(.easeOut(duration: 0.15), value: showingProblems)
        .onReceive(NotificationCenter.default.publisher(for: .showSettings)) { _ in showingSettings = true }
        .onExitCommand { showingSettings = false }
        .onChange(of: refreshKey, initial: true) { kick(resume: true) }
        .task(id: job.destination) {
            // The destination's presence is checked every 3 s on its own: one look, no walk, so a
            // renamed folder or an unplugged drive shows within seconds (not at the next measuring).
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard !preset, let d = job.destination, !runner.running else { continue }
                let now = await JobView.where_(d)
                if now != destinationState {
                    destinationState = now
                    if now == .present { kick() }   // back again: measure what is there
                }
            }
        }
        .task(id: watchKey) {
            // Recheck when anything changes on either side (macOS file events; a network share
            // may not send them, so coming back to the app rechecks too).
            // Each recheck walks every source (a million files is a minute of full CPU), and a busy
            // folder changes all the time: so at most one recheck per 2 minutes, and none while
            // Archivist is in the background (coming back to it rechecks).
            for await _ in FolderWatch.changes(of: watchPaths) where !runner.running {
                guard NSApp.isActive, Date().timeIntervalSince(JobView.lastCheck) > 120, !measuring else { continue }
                kick()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            guard !runner.running, Date().timeIntervalSince(JobView.lastCheck) > 120, !measuring else { return }
            kick()
        }
    }

    // MARK: looking things up

    private var refreshKey: String {
        job.sources.map { "\($0.path)|\($0.skip)|\($0.namesLeftOut)" }.joined() + (job.destination ?? "") + (job.lastResult ?? "") + "\(runner.running)"
    }

    /// Sources only: the destination changes only through Archivist (and its presence is
    /// checked every 3 s), and watching it re-walked every source every 2 minutes all night.
    private var watchPaths: [String] { job.sources.map(\.readPath) }
    private var watchKey: String { watchPaths.joined(separator: "|") }

    /// Is the destination there, or is its folder or its whole drive gone? One look, no walk.
    nonisolated static func where_(_ d: String) async -> DestinationState {
        await Task.detached { () -> DestinationState in
            if FileManager.default.fileExists(atPath: d) { return .present }
            let comps = (d as NSString).pathComponents
            if comps.count > 2, comps[1] == "Volumes", !FileManager.default.fileExists(atPath: "/Volumes/" + comps[2]) { return .driveMissing }
            return .folderMissing
        }.value
    }

    /// Biggest first (measured size), Exclude rows last; ones not measured yet keep their place.
    var sortedSources: [Source] {
        let j = job
        return j.sources.enumerated().sorted { a, b in
            if a.element.skip != b.element.skip { return !a.element.skip }   // Exclude rows at the bottom
            let x = surveys[a.element.id]?.bytes ?? -1, y = surveys[b.element.id]?.bytes ?? -1
            return x != y ? x > y : a.offset < b.offset
        }.map(\.element)
    }

    /// When the sources were last walked: rechecks from file events and returning to the app wait 2 minutes.
    @MainActor static var lastCheck = Date.distantPast

    func refresh() async {
        store.measuringJobs.remove(job.id)   // a cancelled walk left it set
        guard !preset else { return }
        let j = job
        // What the store already knows shows at once: a tab switch never blanks the destination
        // while it is looked up again (each tab's view starts empty).
        for (p, d) in store.drives where drives[p] == nil { drives[p] = d }
        if let d = j.destination, space == nil { space = store.spaces[d] }
        // The destination first, even while a backup runs: its drive, room and presence.
        if let d = j.destination {
            if drives[d] == nil, let dr = await Task.detached(operation: { try? Drive.of(path: d) }).value { drives[d] = dr; store.drives[d] = dr }
            if let room = await Task.detached(operation: { () -> (Int64, Int64)? in
                let v = try? URL(fileURLWithPath: d).resourceValues(forKeys: [.volumeAvailableCapacityKey, .volumeTotalCapacityKey])
                guard let free = v?.volumeAvailableCapacity, let total = v?.volumeTotalCapacity else { return nil }
                return (Int64(free), Int64(total))
            }).value {
                space = (free: room.0, total: room.1); store.spaces[d] = space
            }
            // Is the destination still there? A deleted folder or an unplugged drive must say so.
            destinationState = await JobView.where_(d)
        }
        guard !runner.running else { return }   // a backup under way walks the trees itself
        JobView.lastCheck = Date()
        Access.shared.touch(j.sources.map(\.readPath) + [j.destination].compactMap { $0 })   // any permission popup shows now, not after Start
        for p in j.sources.map(\.readPath) where drives[p] == nil {
            if let d = await Task.detached(operation: { try? Drive.of(path: p) }).value { drives[p] = d; store.drives[p] = d }
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
        // One walk per source: its size shows as soon as the source is walked, then the
        // comparison with the destination. An edit or Start cancels the walk (kick), so walks
        // never stack, and a backup started now walks the tree once, itself.
        let store = store, id = job.id
        store.measuringJobs.insert(id)
        defer { if !Task.isCancelled { store.measuringJobs.remove(id) } }
        for s in j.sources {
            let t = Date()
            if s.skip {   // an Exclude row is never compared: it isn't copied
                guard store.surveys[s.id] == nil else { continue }
                if let size = await JobView.walk({ stop in try Survey.size(of: s.readPath, excluded: j.excluded(in: s), patterns: s.namesLeftOut, stop: stop) }) {
                    store.surveys[s.id] = size
                }
            } else {
                let target = j.target(for: s) ?? "/nonexistent-archivist-destination"
                let full = await JobView.walk({ stop in
                    try Survey.of(source: s.readPath, destination: target, excluded: j.excluded(in: s), patterns: s.namesLeftOut, stop: stop,
                                  onSize: { size in DispatchQueue.main.async { if store.surveys[s.id]?.compared != true { store.surveys[s.id] = size } } },
                                  onCount: { n in DispatchQueue.main.async { store.counted[s.id] = n } })
                })
                store.counted[s.id] = nil
                if let full {
                    store.surveys[s.id] = full
                    DevLog.write(String(format: "counted: %@, %d files, %d to copy, %.1f s", s.name, full.files, full.toCopy, Date().timeIntervalSince(t)))
                }
            }
            if Task.isCancelled { return }
        }
        if !Task.isCancelled { store.walkedKey[id] = refreshKey }
    }

    /// The one way to start a walk: the walk under way for this backup, if any, is cancelled first.
    /// `resume` (the tab opened again, nothing changed): a walk still going carries on, and one
    /// that finished with the same setup is not repeated.
    func kick(resume: Bool = false) {
        let key = refreshKey, id = job.id, store = store
        if resume, store.walks[id]?.key == key || store.walkedKey[id] == key { return }
        store.walks[id]?.task.cancel()
        let token = UUID()
        let task = Task { await refresh(); if store.walks[id]?.token == token { store.walks[id] = nil } }
        store.walks[id] = (key, token, task)
    }

    /// Every source compared, or the walking is over. Start never waits for it: the backup
    /// walks the trees itself, and Start cancels this walk, so nothing is walked twice.
    var measured: Bool {
        !measuring || job.sources.filter { !$0.skip }.allSatisfy { surveys[$0.id]?.compared == true }
    }

    /// A walk off the main thread, quiet, that stops when the task awaiting it is cancelled.
    nonisolated static func walk<T: Sendable>(_ body: @escaping @Sendable (@escaping () -> Bool) throws -> T) async -> T? {
        let stop = OSAllocatedUnfairLock(initialState: false)
        return await withTaskCancellationHandler {
            await Task.detached(priority: .utility) { quiet(); return try? body { stop.withLock { $0 } } }.value
        } onCancel: { stop.withLock { $0 = true } }
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
        Access.shared.touch(job.sources.filter { !$0.skip }.map(\.readPath) + [job.destination].compactMap { $0 })
        let live = job.sources.filter { !$0.skip }.compactMap { surveys[$0.id] }.filter(\.compared)
        store.start(job.id, planned: (live.reduce(0) { $0 + $1.toCopy }, live.reduce(0) { $0 + $1.bytesToCopy }))
    }

    func add(_ urls: [URL]) {
        edit { _ = $0.addSources(urls.map(\.path)) }
        Access.shared.touch(urls.map(\.path))
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
        Access.shared.touch([path])   // a removable or network drive asks now, while the person is here
        edit { j in
            j.destination = path
            j.lastStart = nil; j.lastSkipped = [:]   // what the last backup found belongs to the old destination
            if !j.lookChosen { let l = Contrast.look(for: path, pool: Job.icons); j.icon = l.icon; j.color = l.color }
        }
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
            HStack(alignment: .center) {   // centred in a fixed row, like Destination's: the titles' tops line up
                Text("Sources").font(Typeface.title(24)).foregroundStyle(Palette.ink)
                AddButton(view: view).offset(y: 3)   // the serif title sits low in its line: everything in the row centres on its letters
                Spacer()
                // What this backup will copy, between the title and the count: it lived under the space
                // bar, and appearing there made the Destination box grow and push the page.
                let needed = job.sources.filter { !$0.skip }.compactMap { view.surveys[$0.id] }.filter(\.compared).reduce(Int64(0)) { $0 + $1.bytesToCopy }
                if needed > 0 {
                    let free = view.space?.free ?? .max
                    Text(needed <= free ? "This backup needs \(bytes(needed))" : "Needs \(bytes(needed)), \(bytes(needed - free)) more than is free")
                        .font(Typeface.text(13, needed <= free ? .regular : .semibold))
                        .foregroundStyle(needed <= free ? Palette.soft : Palette.warn)
                        .lineLimit(1)
                        .offset(y: 1.5)
                }
                // Something wasn't copied: a click opens the list. Files that only could not be read are
                // named by the source row's info dot instead; a warning for them read as a failure.
                let unreadable = view.runner.finished?.skipped.values.reduce(0) { $0 + $1.count } ?? 0
                if !view.runner.running && view.runner.problems.count > unreadable {
                    Button { NotificationCenter.default.post(name: .showProblems, object: nil) } label: { Emoji(name: "warning", size: 16) }
                        .buttonStyle(.plain).help("Some files weren't copied").offset(y: 1.5)
                }
                if needed > 0 { Spacer() }
                if !job.sources.isEmpty {
                    (Text("\(job.sources.count) \(job.sources.count == 1 ? "item" : "items"), ")
                     + Text(bytes(total)).fontWeight(.semibold).foregroundColor(Palette.ink))
                        .font(Typeface.text(13)).foregroundStyle(Palette.soft)
                        .offset(y: 1.5)
                }
            }
            .frame(height: 30)
            .padding(.horizontal, 28)
            .frame(height: Header.height, alignment: .bottom).padding(.bottom, Header.below)   // same box as Destination's

            if job.sources.isEmpty {
                DropHint(text: "Drop folders or a drive here", action: view.chooseFolders)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ThinScroll {
                    VStack(spacing: 0) {
                        ForEach(view.sortedSources) { s in
                            SourceRow(view: view, source: s).frame(height: SourceRow.height - 1)
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
    /// One row with its line: the smallest window is sized to hold exactly four.
    static let height: CGFloat = 64
    let view: JobView
    let source: Source
    @State private var finderIcon: NSImage?

    var body: some View {
        let s = source
        HStack(spacing: 14) {
            Group {
                if s.hasCustomIcon, let finderIcon {   // the person's own Finder icon, as Finder shows it
                    Image(nsImage: finderIcon).resizable().interpolation(.high).frame(width: 40, height: 40)
                } else {
                    Badge(icon: s.isDrive ? driveSymbol(view.drive(s.readPath)) : s.icon, hex: s.color, size: 38)
                }
            }
                .overlay(alignment: .bottomTrailing) {   // a folder on a network share wears the globe, smaller than the destination's
                    if !s.isDrive, view.drive(s.readPath)?.kind == .network {
                        Emoji(name: "globe_with_meridians", size: 14).padding(2).background(Circle().fill(Palette.raised))
                            .offset(x: 5, y: 3)
                    }
                }
                .opacity(s.skip ? 0.4 : 1)
                .background(Splash(hex: s.color, addedAt: s.addedAt))
                // Read once, off the main thread: on a network drive each look is a trip to the
                // server, and the row redraws often (the count while walking); on the main
                // thread it froze the window.
                .task(id: s.path) {
                    guard s.hasCustomIcon else { return }
                    let path = s.path
                    finderIcon = await Task.detached { NSWorkspace.shared.icon(forFile: path) }.value
                }
            VStack(alignment: .leading, spacing: 3) {
                Text(s.name).font(Typeface.text(15, .semibold)).foregroundStyle(Palette.ink.opacity(s.skip ? 0.5 : 1))
                HStack(spacing: 5) {
                    Text(status).font(Typeface.text(12.5)).foregroundStyle(statusColor).lineLimit(1)
                    if let q = settled { InfoDot(live: q.live, unreadable: q.unreadable) }
                }
            }
            Spacer(minLength: 8)
            // Three choices for the row itself. Exclude: this folder is not copied, and an Include
            // row that holds it leaves it out.
            let mode = s.skip ? 1 : s.skipJunk ? 0 : 2
            Menu {
                Button { view.update(s) { $0.skip = false; $0.skipJunk = false; $0.leftOut = [] } } label: {
                    Text("Include") + Text(mode == 2 ? "  ✓" : "")
                }
                Button { view.update(s) { $0.skip = true; $0.leftOut = [] } } label: {
                    Text("Exclude") + Text(mode == 1 ? "  ✓" : "")
                }
                Button { view.update(s) { $0.skip = false; $0.skipJunk = true; $0.leftOut = [] } } label: {
                    Text("Skip junk") + Text(mode == 0 ? "  ✓" : "")
                }
            } label: {
                Text(mode == 1 ? "Exclude" : mode == 0 ? "Skip junk" : "Include").font(Typeface.text(12.5))
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

    /// Everything still to copy is either live (changed after the last finished backup started:
    /// files an app keeps open, like logs and databases) or could not be read last time. Then the
    /// folder is backed up, and saying "not backed up yet" in red read as a failure (Helios, 2026-11-28).
    private var settled: (live: Int, unreadable: [String])? { SourceRow.settled(job: view.job, source: source, survey: survey) }

    static func settled(job: Job, source: Source, survey: Survey?) -> (live: Int, unreadable: [String])? {
        guard let v = survey, v.compared, v.destinationExists, v.toCopy > 0, v.pending.count == v.toCopy,
              let start = job.lastStart?.timeIntervalSince1970, let end = job.lastRun?.timeIntervalSince1970 else { return nil }
        let skipped = Set(job.lastSkipped[source.id.uuidString] ?? [])
        var live = 0, unreadable: [String] = []
        for (path, mtime) in v.pending {
            if mtime > end + 2 { return nil }   // changed after the backup ended: a real change, the plain red count
            if skipped.contains(path) { unreadable.append(path) }
            else if mtime >= start - 2 { live += 1 }   // changed while the backup ran (2 s: dates are rounded)
            else { return nil }   // older than the backup yet not copied: not a live file
        }
        return (live, unreadable.sorted())
    }


    private var status: String {
        if Access.shared.isWaiting(source.readPath) { return "Waiting for your OK" }   // the bottom line says where
        if source.skip { return survey.map { "\(bytes($0.bytes)), excluded" } ?? "Excluded" }
        guard let v = survey else { return view.counted[source.id].map { "Calculating… \($0.formatted()) files" } ?? "Calculating…" }
        let size = bytes(v.bytes)
        if !v.compared { return "\(size), calculating…" }
        if settled != nil { return "\(size), up to date" }
        if !v.destinationExists { return "\(size), not backed up yet" }
        if v.toCopy == 0 { return "\(size), up to date" }
        if v.bytesToCopy >= v.bytes { return "\(size), not backed up yet" }   // everything is new: the same size twice says nothing
        return v.bytesToCopy > 0 ? "\(size), \(bytes(v.bytesToCopy)) not backed up yet" : "\(size), small changes not backed up yet"
    }

    private var statusColor: Color {
        if Access.shared.isWaiting(source.readPath) { return Palette.warn }
        guard let v = survey, v.compared, !source.skip else { return Palette.soft }
        if settled != nil { return Palette.good }
        return !v.destinationExists || v.toCopy > 0 ? Palette.due : Palette.good   // red: still to copy; green: up to date
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
    @State private var height: CGFloat = 600
    private var compact: Bool { height < 380 }   // a short window: smaller picture, no drive-kind line, tighter gaps

    var body: some View {
        let job = view.job
        let d = view.drive(job.destination)
        let needed = job.sources.filter { !$0.skip }.compactMap { view.surveys[$0.id] }.filter(\.compared).reduce(Int64(0)) { $0 + $1.bytesToCopy }
        VStack(alignment: .leading, spacing: 0) {
            ZStack {   // the title centred over the picture below; the gear keeps the right edge
                Text("Destination").font(Typeface.title(24)).foregroundStyle(Palette.ink)
                HStack {
                    Spacer()
                    Button { NotificationCenter.default.post(name: .showSettings, object: nil) } label: { Emoji(name: "gear", size: 20) }
                        .buttonStyle(.plain).help("Settings: name, picture, schedule, drive type, delete")
                        .offset(y: 3)   // centred on the title's letters, like Sources' plus
                }
            }
            .frame(height: 30)
            .frame(height: Header.height, alignment: .bottom).padding(.bottom, Header.below)   // same box as Sources'

            if let path = job.destination, view.destinationState != .present {
                Missing(view: view, path: path)
            } else if let path = job.destination {
                VStack(spacing: 8) {
                    Badge(icon: job.icon, hex: job.color, size: compact ? 44 : 66)
                        .overlay(alignment: .bottomTrailing) {
                            if let d {
                                Emoji(name: driveSymbol(d), size: 14).padding(2).background(Circle().fill(Palette.raised))   // same size as a source's globe
                                    .overlay(alignment: .trailing) {   // the drive's kind, hung off the badge's right
                                        Text(kindName(d)).font(Typeface.text(12.5)).foregroundStyle(Palette.soft)
                                            .fixedSize().alignmentGuide(.trailing) { t in t[.leading] - 4 }
                                    }
                                    .offset(x: 8, y: 4)
                            }
                        }
                    Text(location(path, d)).font(Typeface.text(15, .semibold)).foregroundStyle(Palette.ink)
                        .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                    if let d, !compact { Text(fileSystemName(d) + (job.destinationKind == nil ? "" : ", set by hand")).font(Typeface.text(12)).foregroundStyle(Palette.soft) }
                }
                .frame(maxWidth: .infinity)

                if let space = view.space { SpaceBar(free: space.free, total: space.total, needed: needed, hex: job.color).padding(.top, compact ? 8 : 14) }

                Button("Change location", action: view.chooseDestination).buttonStyle(QuietButton())
                    .overlay(alignment: .trailing) {   // centred on its own; the magnifier hangs off its right
                        Button { NSWorkspace.shared.open(URL(fileURLWithPath: path)) } label: { Image(systemName: "magnifyingglass") }
                            .buttonStyle(QuietButton()).help("Open in Finder")
                            .fixedSize().alignmentGuide(.trailing) { d in d[.leading] - 8 }
                    }
                    .frame(maxWidth: .infinity).padding(.top, compact ? 8 : 12)
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
                Button { NotificationCenter.default.post(name: .showSettings, object: nil) } label: {
                    HStack(spacing: 5) {
                        Emoji(name: "spiral_calendar", size: 13)
                        Text("Schedule: " + job.schedule.short)
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
        .background(GeometryReader { g in Color.clear.onAppear { height = g.size.height }.onChange(of: g.size.height) { _, h in height = h } })
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
                    view.kick()
                }.buttonStyle(PrimaryButton())
            }
            Button("Change location", action: view.chooseDestination).buttonStyle(QuietButton())
        }
        .frame(maxWidth: .infinity).padding(.top, 10)
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
        VStack(alignment: .center, spacing: 6) {
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
        let chunks = known ? view.sortedSources.filter { !$0.skip }.reversed().map { (s: $0, b: max(view.surveys[$0.id]?.bytes ?? 1, 1)) } : []
        let total = max(chunks.reduce(Int64(0)) { $0 + $1.b }, 1)
        TimelineView(.periodic(from: .now, by: view.runner.running && view.runner.remaining(at: .now) == nil ? 0.25 : 1)) { tl in
            let r = view.runner
            let estimating = r.running && !r.finishing && r.remaining(at: tl.date) == nil
            GeometryReader { g in
                let w = g.size.width - Double(3 * max(chunks.count - 1, 0))
                // Each chunk at least 4 pt, the rest shared by size: the chunks add up to the bar exactly
                // (a 4 pt floor on top of the shares overflowed the bar and clipped its right end).
                let floorW = 4.0, spare = max(0, w - floorW * Double(chunks.count))
                let widths = Dictionary(uniqueKeysWithValues: chunks.map { ($0.s.id, floorW + spare * Double($0.b) / Double(total)) })
                VStack(alignment: .leading, spacing: 0) {
                    ZStack(alignment: .leading) {
                        if chunks.isEmpty { Rectangle().fill(Palette.rule) }
                        HStack(spacing: 3) {
                            ForEach(chunks, id: \.s.id) { c in
                                Rectangle().fill(scheme == .dark ? Nippon.color(c.s.color).opacity(0.18) : Nippon.soft(c.s.color, white: 0.25).opacity(0.5))
                                    .frame(width: widths[c.s.id] ?? 4)
                            }
                        }
                        if r.running && !estimating {
                            // Each source's chunk fills with that source's own work: done ones full, the
                            // one copying by its bytes (files when it has no bytes), the rest empty. The
                            // time estimate lives in the words under the bar, not here.
                            HStack(spacing: 3) {
                                ForEach(chunks, id: \.s.id) { c in
                                    let p = r.progress
                                    let f: Double = r.doneSources.contains(c.s.id) ? 1
                                        : r.currentSourceID != c.s.id ? 0
                                        : p.bytesTotal > 0 ? Double(p.bytesDone) / Double(p.bytesTotal)
                                        : p.filesTotal > 0 ? Double(p.filesDone) / Double(p.filesTotal) : 0
                                    // Dark: the soft colours of the circles; full strength glared on a dark track.
                                    Rectangle().fill(scheme == .dark ? Nippon.soft(c.s.color, white: 0.3) : Nippon.color(c.s.color))
                                        .frame(width: (widths[c.s.id] ?? 4) * min(max(f, 0), 1))
                                        .frame(width: widths[c.s.id] ?? 4, alignment: .leading)
                                        .animation(.linear(duration: 1), value: f)
                                }
                            }
                        }
                        if estimating {
                            // Working out the time: each chunk breathes in its own soft colour.
                            let breath = 0.5 + 0.5 * sin(tl.date.timeIntervalSinceReferenceDate * 2.2)
                            HStack(spacing: 3) {
                                ForEach(chunks, id: \.s.id) { c in
                                    Rectangle().fill(scheme == .light ? Nippon.color(c.s.color).opacity(0.35 + 0.45 * breath)
                                                                      : Nippon.soft(c.s.color, white: 0.3).opacity(0.25 + 0.3 * breath))
                                        .frame(width: widths[c.s.id] ?? 4)
                                }
                            }
                            .animation(.easeInOut(duration: 0.5), value: breath)
                        }
                    }
                    .frame(height: 28)
                    .clipped()
                    ZStack {
                    if r.running, !r.finishing, let pace = r.pace {
                        let (icon, word) = pace >= 0.7 ? ("rocket", "Fast") : pace >= 0.4 ? ("horse", "Good")
                                         : pace >= 0.15 ? ("turtle", "Slow") : ("snail", "Very slow")
                        HStack(spacing: 8) {
                            ZStack(alignment: .leading) {   // now, against the best this drive has done
                                Capsule().fill(Palette.rule)
                                Capsule().fill(Palette.accent).frame(width: 70 * pace)
                            }
                            .frame(width: 70, height: 5)
                            .animation(.easeInOut(duration: 1), value: pace)
                            Text("Drive speed").font(Typeface.text(12)).foregroundStyle(Palette.soft)
                            Spacer()
                            Text(word).font(Typeface.text(12)).foregroundStyle(pace >= 0.4 ? Palette.soft : Palette.warn)
                            Emoji(name: icon, size: 14)   // at the edge: the word can change length, the icon stays put
                        }
                    }
                    if r.running && !r.stopping {
                        // "~6:15 left  //  67% done  //  11:00 elapsed": the middle sits on the app's middle.
                        // Left is the estimate; elapsed is a plain clock from Start, never estimated.
                        let left = r.remaining(at: tl.date)
                        let pct = Int(r.steadyFraction(at: tl.date) * 100)
                        let done = r.finishing || pct >= 100
                        HStack(spacing: 0) {
                            Text(done || estimating ? "" : "~\(Runner.clock(left ?? 0)) left  //  ").frame(maxWidth: .infinity, alignment: .trailing)
                            Text(Access.shared.anyWaiting ? "Waiting for your OK" : done ? "Finishing…" : estimating ? "Calculating…" : "\(pct)% done").fontWeight(.semibold).fixedSize()
                            Text("  //  \(Runner.clock(r.elapsed)) elapsed").frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .font(Typeface.number(12.5)).foregroundStyle(Palette.ink)
                        .padding(.horizontal, 150)   // clear of the speed meter and word at the ends
                    } else {
                        Text(r.stopping ? "Stopping…"
                             : !(job.ready && view.destinationState == .present) ? " "
                             : Access.shared.anyWaiting ? Access.message
                             : view.measured ? "Ready to start" : "Calculating…")
                            .font(Typeface.text(12))
                            .foregroundStyle(r.running ? Palette.ink : Palette.soft)
                            .frame(maxWidth: .infinity)
                    }
                    }
                    .frame(height: 27)   // centred between the bar and the window's bottom edge
                }
            }
        }
        .frame(height: 28 + 27)
        .padding(.horizontal, 16).padding(.top, 10)
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
                            HStack(spacing: 8) { Emoji(name: v.path == "/" ? "laptop" : "gem_stone", size: 18); Text(v.name) }
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
    case .ssd?: return d?.mountPoint == "/" || d?.mountPoint == "/System/Volumes/Data" ? "laptop" : "gem_stone"
    case .spinning?, .unknown?: return "optical_disk"
    case .network?: return "globe_with_meridians"
    case nil: return "gem_stone"
    }
}

func kindName(_ d: Drive) -> String {
    switch d.kind {
    case .ssd: return "Solid state"
    case .spinning: return "Spinning disk"
    case .unknown: return "Unknown"
    case .network: return "Network drive"
    }
}

func fileSystemName(_ d: Drive) -> String {
    ["apfs": "APFS", "hfs": "Mac OS Extended", "exfat": "exFAT", "msdos": "FAT", "smbfs": "SMB"][d.fileSystem] ?? d.fileSystem
}

/// Measuring sources is work someone waits on (Start waits for the sizes): utility, one tier
/// above background. Background + IOPOL_THROTTLE (Time Machine's tier) held the reads back
/// whenever anything else touched the disk, and a big folder took many minutes to size.
func quiet() {
    setiopolicy_np(IOPOL_TYPE_DISK, IOPOL_SCOPE_THREAD, IOPOL_UTILITY)
}

func bytes(_ n: Int64) -> String { ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }

struct Problems: View {
    let list: [String]
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
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
    static let left: CGFloat = 168, right: CGFloat = 146   // as wide as what they hold: Keep earlier versions; the colour grid
    static let width: CGFloat = 26 + left + 32 + right + 26   // equal margins both sides
    let view: JobView
    var close: () -> Void = {}
    @Environment(JobStore.self) private var store
    @AppStorage("appearance") private var appearance = "system"
    @Environment(\.colorScheme) private var scheme
    @State private var name = ""
    @State private var confirmDelete = false

    var body: some View {
        let job = view.job
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(spacing: 14) {
                    Badge(icon: job.icon, hex: job.color, size: 56)
                    TextField("Name this backup", text: $name)
                        .textFieldStyle(.plain).font(Typeface.title(24)).foregroundStyle(Palette.ink)
                        .onSubmit(saveName)
                    Button { saveName(); close() } label: { Image(systemName: "xmark").font(.system(size: 13, weight: .semibold)) }
                        .buttonStyle(.plain).foregroundStyle(Palette.soft).help("Close")
                }

                // Two fixed columns: nothing chosen inside can change the panel's width.
                Grid(alignment: .topLeading, horizontalSpacing: 32, verticalSpacing: 24) {
                    GridRow {
                    centred("Icon") {
                        LazyVGrid(columns: Array(repeating: GridItem(.fixed(32), spacing: 6, alignment: .leading), count: 4),
                                  alignment: .leading, spacing: 6) {
                            ForEach(Job.icons, id: \.self) { n in
                                Button { view.edit { $0.icon = n; $0.lookChosen = true } } label: {
                                    Emoji(name: n, size: 21).frame(width: 32, height: 32)
                                        .background(Circle().strokeBorder(n == job.icon ? Palette.ink : .clear, lineWidth: 2))
                                }.buttonStyle(.plain)
                            }
                        }
                        .fixedSize()
                    }
                    .frame(width: Self.left, alignment: .leading)
                    centred("Background") {
                        LazyVGrid(columns: Array(repeating: GridItem(.fixed(32), spacing: 6, alignment: .leading), count: 4),
                                  alignment: .leading, spacing: 6) {
                            ForEach(Nippon.colors, id: \.hex) { c in
                                Button { view.edit { $0.color = c.hex; $0.lookChosen = true } } label: {
                                    Circle().fill(Nippon.color(c.hex)).frame(width: 26, height: 26).frame(width: 32, height: 32)   // same cell as an icon: the rows line up
                                        .overlay(Circle().strokeBorder(c.hex == job.color ? Palette.ink : .clear, lineWidth: 2))
                                }.buttonStyle(.plain).help(c.name)
                            }
                        }
                        .fixedSize()
                    }
                    .frame(width: Self.right, alignment: .leading)
                    }
                    GridRow {
                    VStack(alignment: .leading, spacing: 22) {
                        section("Earlier versions") {
                            Toggle("Keep deleted files", isOn: Binding(get: { job.keepDeleted }, set: { v in view.edit { $0.keepDeleted = v } }))
                            Toggle("Keep earlier versions", isOn: Binding(get: { job.keepChanged }, set: { v in view.edit { $0.keepChanged = v } }))
                            VStack(alignment: .leading, spacing: 4) {   // lined up with the toggles' words
                                Text("Remove after").foregroundStyle(Palette.soft)
                                Menu {
                                    ForEach([(30, "30 days"), (90, "90 days"), (365, "1 year"), (0, "Never")], id: \.0) { days, words in
                                        Button(words) { view.edit { $0.keepDays = days == 0 ? nil : days } }
                                    }
                                } label: {
                                    HStack(spacing: 4) {
                                        Text([30: "30 days", 90: "90 days", 365: "1 year"][job.keepDays ?? 0] ?? "Never")
                                            .foregroundStyle(Palette.ink)
                                        Spacer(minLength: 0)
                                        Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(Palette.soft)
                                    }
                                    .padding(.horizontal, 8).frame(width: 84, height: 22)   // as wide as "90 days": the panel never changes width
                                    .background(RoundedRectangle(cornerRadius: 6).fill(Palette.rule.opacity(0.6)))
                                }
                                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()   // plain: the label is drawn as written
                            }
                            .padding(.leading, 20).padding(.top, -2)
                            Toggle(isOn: Binding(get: { job.makeRoom }, set: { v in view.edit { $0.makeRoom = v } })) {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text("Make room when full")
                                    Text("Oldest first").font(Typeface.text(11.5)).foregroundStyle(Palette.soft)
                                }
                            }
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
                    }
                    .frame(width: Self.left, alignment: .leading)
                    VStack(alignment: .leading, spacing: 22) {
                        section("Schedule") { ScheduleChooser(view: view) }
                        section("Threads") {
                            Picker("", selection: Binding(get: { job.threads ?? 0 }, set: { v in view.edit { $0.threads = v == 0 ? nil : v } })) {
                                Text("Automatic").tag(0)
                                ForEach([1, 2, 4, 8, 16], id: \.self) { Text("\($0)").tag($0) }
                            }
                            .labelsHidden().fixedSize()
                        }
                    }
                    .frame(width: Self.right, alignment: .leading)
                    }
                }
                .frame(maxWidth: .infinity)

                VStack(spacing: 8) {
                    Text("Appearance").font(Typeface.text(13, .semibold)).foregroundStyle(Palette.soft)
                    // Drawn here, not the system's segmented control: the chosen one in the app's lavender,
                    // its words dark in light mode and light in dark mode.
                    HStack(spacing: 2) {
                        ForEach([("system", "Follow the Mac"), ("light", "Light"), ("dark", "Dark")], id: \.0) { tag, words in
                            Button { appearance = tag } label: {
                                Text(words).font(Typeface.text(13, appearance == tag ? .semibold : .regular))
                                    .foregroundStyle(appearance == tag ? (scheme == .dark ? Color.white : Color.black) : Palette.ink)
                                    .padding(.horizontal, 14).padding(.vertical, 5)
                                    .background(Capsule().fill(appearance == tag ? Palette.accent : .clear))
                                    .contentShape(Capsule())
                            }.buttonStyle(.plain)
                        }
                    }
                    .padding(2)
                    .background(Capsule().fill(Palette.rule.opacity(0.6)))
                }
                .frame(maxWidth: .infinity)

                Permissions()

                if let dest = job.destination {
                    DriveMemoryReset(path: dest, running: view.runner.running)
                }

                Divider()
                HStack {
                    Button("Delete this backup…", role: .destructive) { confirmDelete = true }
                        .foregroundStyle(Palette.warn)
                    Spacer()
                    Button("Save") { saveName(); close() }.buttonStyle(PrimaryButton()).keyboardShortcut(.defaultAction)
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

    /// A title centred over its grid.
    @ViewBuilder private func centred<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .center, spacing: 8) {
            Text(title).font(Typeface.text(13, .semibold)).foregroundStyle(Palette.ink)
            content()
        }
        .fixedSize()
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
    static let showProblems = Notification.Name("ArchivistShowProblems")
}

/// A small ⓘ beside a status: what was left out, in plain words, and the files on request.
struct InfoDot: View {
    let live: Int
    let unreadable: [String]
    @State private var open = false

    var body: some View {
        Button { open.toggle() } label: { Image(systemName: "info.circle").font(.system(size: 12)) }
            .buttonStyle(.plain).foregroundStyle(Palette.soft)
            .help(InfoCard.lines(live: live, unreadable: unreadable).joined(separator: " "))
            // A sheet, not a popover: a popover hung below the row and the open file list ran out of the window.
            .sheet(isPresented: $open) { InfoCard(live: live, unreadable: unreadable, onDone: { open = false }) }
    }
}

struct InfoCard: View {
    let live: Int
    let unreadable: [String]
    var onDone: (() -> Void)? = nil
    @State var showFiles = false

    static func lines(live: Int, unreadable: [String]) -> [String] {
        var l: [String] = []
        if live > 0 {
            l.append(live == 1 ? "1 file was in use and changed during the backup. It will be copied next time."
                               : "\(live) files were in use and changed during the backup. They will be copied next time.")
        }
        if !unreadable.isEmpty {
            l.append((unreadable.count == 1 ? "1 file couldn't be read, so it was skipped." : "\(unreadable.count) files couldn't be read, so they were skipped.")
                     + " Usually a file another app keeps locked, or a shortcut that points nowhere.")
        }
        return l
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Everything else is backed up.").font(Typeface.text(13.5, .semibold))
            ForEach(InfoCard.lines(live: live, unreadable: unreadable), id: \.self) { Text($0) }
            if !unreadable.isEmpty {
                Button(showFiles ? "Hide files" : "Show files") { withAnimation(.easeInOut(duration: 0.2)) { showFiles.toggle() } }
                    .buttonStyle(.plain).foregroundStyle(Palette.accent).font(Typeface.text(12.5, .semibold))
                if showFiles {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(unreadable, id: \.self) { path in
                                let folder = (path as NSString).deletingLastPathComponent
                                VStack(alignment: .leading, spacing: 1) {
                                    Text((path as NSString).lastPathComponent).font(Typeface.text(12.5, .semibold))
                                    Text(folder.isEmpty ? "in the top folder" : "in " + folder)
                                        .font(Typeface.text(11)).foregroundStyle(Palette.soft)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 140)
                }
            }
            if let onDone {
                HStack { Spacer(); Button("Done", action: onDone).buttonStyle(QuietButton()).keyboardShortcut(.defaultAction) }
            }
        }
        .font(Typeface.text(12.5)).foregroundStyle(Palette.ink)
        .fixedSize(horizontal: false, vertical: true)
        .frame(width: 320, alignment: .leading).padding(16)
        .background(Palette.raised)
    }
}

/// The Mac permissions Archivist uses, each opening its own page in System Settings. macOS
/// lets an app ask (on first use) but never switch a permission itself, so these are doors,
/// not switches; Full Disk Access shows whether it is on, the one macOS lets an app see.
struct Permissions: View {
    @State private var fullDisk = Permissions.hasFullDiskAccess()

    /// Opening the TCC database is refused without Full Disk Access, and asks nothing.
    static func hasFullDiskAccess() -> Bool {
        let fd = open("/Library/Application Support/com.apple.TCC/TCC.db", O_RDONLY)
        if fd >= 0 { close(fd); return true }
        return false
    }

    private func row(_ title: String, _ detail: String, state: Bool?, pane: String) -> some View {
        HStack(spacing: 10) {
            if let state {
                Circle().fill(state ? Palette.good : Palette.soft.opacity(0.5)).frame(width: 8, height: 8)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(Typeface.text(13, .semibold)).foregroundStyle(Palette.ink)
                Text(detail).font(Typeface.text(11.5)).foregroundStyle(Palette.soft).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button("Open") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?" + pane)!) }
                .buttonStyle(QuietButton())
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Permissions").font(Typeface.text(13, .semibold)).foregroundStyle(Palette.soft).frame(maxWidth: .infinity)
            row("Files & Folders", "Shared folders, external drives, Desktop and Documents", state: nil, pane: "Privacy_FilesAndFolders")
            row("Full Disk Access", fullDisk ? "On: whole drives and your home folder" : "Off: needed for whole drives and your home folder",
                state: fullDisk, pane: "Privacy_AllFiles")
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            fullDisk = Permissions.hasFullDiskAccess()   // back from System Settings: the answer may have changed
        }
    }
}

/// Forget what the destination drive has done so far: time estimates and the speed meter start
/// fresh from the next backup.
struct DriveMemoryReset: View {
    let path: String
    let running: Bool
    @State private var runs = 0
    @State private var confirm = false

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Time estimates").font(Typeface.text(13, .semibold)).foregroundStyle(Palette.ink)
                Text(runs == 0 ? "Learned from this drive's backups. None yet."
                     : "Learned from this drive's last \(runs) \(runs == 1 ? "backup" : "backups").")
                    .font(Typeface.text(11.5)).foregroundStyle(Palette.soft)
            }
            Spacer()
            Button("Start fresh") { confirm = true }.buttonStyle(QuietButton()).disabled(running || runs == 0)
        }
        .onAppear { runs = DriveMemories.load()[DriveMemories.key(for: path)]?.runs.count ?? 0 }
        .alert("Forget this drive's past backups?", isPresented: $confirm) {
            Button("Start fresh", role: .destructive) { DriveMemories.forget(path); runs = 0 }
            Button("Keep", role: .cancel) {}
        } message: {
            Text("Time estimates are learned again from the next backup. Nothing on the drive changes.")
        }
    }
}
