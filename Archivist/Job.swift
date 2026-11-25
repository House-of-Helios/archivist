import ArchivistCore
import Foundation
import Observation

/// One source: a folder or a whole drive, with its own rules.
struct Source: Codable, Identifiable, Hashable {
    var id = UUID()
    var path: String
    var skip = false                 // "skip next time": kept in the list, not copied
    var leftOut: [String] = []       // subfolders, relative to this source
    var patterns: [String] = []      // names left out anywhere inside (`*.tmp`); older saves only
    var skipJunk = true              // "Skip junk files" (the default for a new source): Source.junk, anywhere inside
    var addedAt: Date?               // when it was dropped in: its row splashes if that was moments ago

    /// Throwaway files any app rebuilds on its own.
    static let junk = ["Caches", ".cache", "*.tmp", "*.temp", "node_modules", "DerivedData", ".Trash", "*.swp",
                       // build output that rebuilds from the code beside it
                       ".build", "__pycache__", ".venv", ".next", ".turbo", ".vite", ".gradle", ".pytest_cache", ".mypy_cache",
                       "target@Cargo.toml", "build@CMakeLists.txt", "build@package.json", "build@build.gradle", "build@build.gradle.kts",
                       "dist@package.json", "dist@pyproject.toml", "dist@setup.py"]
    /// What the engine leaves out by name.
    var namesLeftOut: [String] { patterns + (skipJunk ? Source.junk : []) }
    var icon = Source.icons.randomElement()!   // plants and food: sources; animals: backups
    var color = Nippon.colors[0].hex           // also its chunk in the progress bar: the row is the legend

    static let icons = ["tulip", "sunflower", "herb", "four_leaf_clover", "maple_leaf", "cherry_blossom", "hibiscus",
                        "potted_plant", "cactus", "mushroom", "seedling", "leafy_green", "avocado", "lemon", "peach",
                        "watermelon", "carrot", "croissant", "strawberry", "grapes", "pineapple", "ear_of_corn", "mango",
                        "kiwi_fruit", "doughnut", "taco", "cherries", "hot_beverage"]

    init(path: String, leftOut: [String] = []) { self.path = path; self.leftOut = leftOut }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        path = try c.decode(String.self, forKey: .path)
        skip = false   // Pause is gone from the app: a source saved paused copies again
        leftOut = try c.decodeIfPresent([String].self, forKey: .leftOut) ?? []
        patterns = try c.decodeIfPresent([String].self, forKey: .patterns) ?? []
        skipJunk = try c.decodeIfPresent(Bool.self, forKey: .skipJunk) ?? false
        addedAt = try c.decodeIfPresent(Date.self, forKey: .addedAt)
        let seed = Int(id.uuid.1)   // saved before pictures: a steady pick, never changing between launches
        icon = try c.decodeIfPresent(String.self, forKey: .icon) ?? Source.icons[seed % Source.icons.count]
        color = try c.decodeIfPresent(String.self, forKey: .color) ?? Nippon.colors[seed % Nippon.colors.count].hex
    }

    /// The folder or drive carries its own Finder icon (a hidden `Icon\r` file, or a drive's
    /// `.VolumeIcon.icns`): show that, not one of ours.
    var hasCustomIcon: Bool {
        FileManager.default.fileExists(atPath: path + (isDrive ? "/.VolumeIcon.icns" : "/Icon\r"))
    }

    var isDrive: Bool { (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isVolumeKey]).isVolume) == true }
    var name: String { isDrive ? Volumes.name(of: path) : (path as NSString).lastPathComponent }
    /// The Mac's own drive is sealed at `/`; its files live on the Data volume.
    var readPath: String { Volumes.copyablePath(path) }
}

/// One saved backup: a title, its sources, one destination.
struct Job: Codable, Identifiable, Hashable {
    var id = UUID()
    var title: String
    var sources: [Source] = []
    var destination: String?
    var lastResult: String?
    var lastState: String?           // a few words: where this backup stands
    var lastPast: String?
    var lastBytes: Int64?                            // size of the last backup's source, for "Last backup: date, size"
    var icon: String = Job.icons.randomElement()!   // a picture per backup, so a glance tells them apart
    var color: String = Nippon.colors.randomElement()!.hex
    var lookChosen = false                           // picked by hand in Settings: then it never follows the destination
    var schedule: Schedule = .byHand
    var destinationKind: DriveKind?                  // nil = let Archivist decide (Settings)
    var keepDeleted = true                           // earlier versions (Settings)
    var keepChanged = true
    var keepDays: Int? = 365                         // nil = keep by age forever
    var makeRoom = true                              // drive running low: oldest earlier versions go first
    /// One place for this backup's earlier versions.
    var pastRoot: String? { destination.map { $0 + "/" + Names.past } }
    var lastRun: Date?                               // when it last finished, by hand or by schedule
    var destinationSince: Date?                      // the helper's note: destination present since

    /// Fluent emoji a backup can wear (picked at random, changeable in the Destination panel).
    /// Animals for backups (sources wear plants and food).
    static let icons = ["fox", "owl", "dragon", "octopus", "turtle", "spouting_whale", "butterfly", "honeybee", "hedgehog", "snail",
                        "cat", "dog", "rabbit", "elephant", "koala", "penguin", "frog", "tiger", "lion", "unicorn", "dolphin",
                        "sloth", "otter", "flamingo", "parrot"]

    /// Adds folders or drives as sources, each with its path's look (the window and the dev remote
    /// both come here, so they behave the same).
    mutating func addSources(_ paths: [String]) -> [Source.ID] {
        var added: [Source.ID] = []
        for path in paths where !sources.contains(where: { $0.path == path }) {
            var src = Source(path: path)
            src.addedAt = Date()
            let l = Contrast.look(for: path, pool: Source.icons, notColor: sources.last?.color, notIcons: Set(sources.map(\.icon)))
            src.icon = l.icon; src.color = l.color
            sources.append(src)
            added.append(src.id)
        }
        return added
    }

    /// Results written elsewhere (the helper) win when they're newer.
    mutating func takeResults(from other: Job) {
        if (other.lastRun ?? .distantPast) > (lastRun ?? .distantPast) {
            lastRun = other.lastRun; lastResult = other.lastResult; lastState = other.lastState; lastPast = other.lastPast
            lastBytes = other.lastBytes
        }
        destinationSince = other.destinationSince
    }

    var ready: Bool { sources.contains { !$0.skip } && destination != nil }

    /// Each source lands in its own folder at the destination, named after it.
    func target(for s: Source) -> String? { destination.map { $0 + "/" + s.name } }

    init(title: String) { self.title = title }

    // Reads jobs saved before sources had their own rules (folders / wholeDrive / leftOut).
    private enum Old: String, CodingKey { case folders, wholeDrive, leftOut }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        destination = try c.decodeIfPresent(String.self, forKey: .destination)
        lastResult = try c.decodeIfPresent(String.self, forKey: .lastResult)
        lastState = try c.decodeIfPresent(String.self, forKey: .lastState)
        lastPast = try c.decodeIfPresent(String.self, forKey: .lastPast)
        lastBytes = try c.decodeIfPresent(Int64.self, forKey: .lastBytes)
        schedule = (try? c.decodeIfPresent(Schedule.self, forKey: .schedule)) ?? .byHand   // older shapes fall back
        destinationKind = try c.decodeIfPresent(DriveKind.self, forKey: .destinationKind)
        keepDeleted = try c.decodeIfPresent(Bool.self, forKey: .keepDeleted) ?? true
        keepChanged = try c.decodeIfPresent(Bool.self, forKey: .keepChanged) ?? true
        keepDays = c.contains(.keepDays) ? try c.decodeIfPresent(Int.self, forKey: .keepDays) : 365
        makeRoom = try c.decodeIfPresent(Bool.self, forKey: .makeRoom) ?? true
        lastRun = try c.decodeIfPresent(Date.self, forKey: .lastRun)
        destinationSince = try c.decodeIfPresent(Date.self, forKey: .destinationSince)
        // Backups saved before icons: a steady pick from the id, so it never changes between launches.
        let saved = try c.decodeIfPresent(String.self, forKey: .icon)
        icon = saved.flatMap { Job.icons.contains($0) ? $0 : nil } ?? Job.icons[Int(id.uuid.0) % Job.icons.count]  // backups are animals now
        color = try c.decodeIfPresent(String.self, forKey: .color) ?? Nippon.colors[Int(id.uuid.2) % Nippon.colors.count].hex
        lookChosen = try c.decodeIfPresent(Bool.self, forKey: .lookChosen) ?? false
        if let new = try c.decodeIfPresent([Source].self, forKey: .sources) {
            sources = new
        } else {
            let o = try decoder.container(keyedBy: Old.self)
            if let drive = try o.decodeIfPresent(String.self, forKey: .wholeDrive) {
                sources = [Source(path: drive, leftOut: try o.decodeIfPresent([String].self, forKey: .leftOut) ?? [])]
            } else {
                sources = (try o.decodeIfPresent([String].self, forKey: .folders) ?? []).map { Source(path: $0) }
            }
        }
    }
}

/// The saved jobs. Dev builds keep them inside the room (`_devdata/app/`); a release in
/// Application Support, like any Mac app.
@Observable
final class JobStore {
    var jobs: [Job] = []
    /// One runner per backup, kept here so a backup keeps running (and stays visible)
    /// while another title is shown.
    var runners: [Job.ID: Runner] = [:]
    var anyRunning: Bool { runners.values.contains { $0.running } }
    /// What each source holds and how it compares, kept across tab switches.
    var surveys: [Source.ID: Survey] = [:]

    /// Starts a backup: the button and the dev remote both come here.
    func start(_ id: Job.ID, planned: (files: Int, bytes: Int64) = (0, 0)) {
        guard let job = jobs.first(where: { $0.id == id }) else { return }
        var planned = planned
        if planned.files == 0 {   // started from outside the window: take the shared counts
            let live = job.sources.filter { !$0.skip }.compactMap { surveys[$0.id] }.filter(\.compared)
            planned = (live.reduce(0) { $0 + $1.toCopy }, live.reduce(0) { $0 + $1.bytesToCopy })
        }
        runner(for: id).start(job, planned: planned) { [weak self] summary, state, past, total in
            guard let self, let i = self.jobs.firstIndex(where: { $0.id == id }) else { return }
            var j = self.jobs[i]
            j.lastResult = summary; j.lastState = state; j.lastPast = past ?? j.lastPast; j.lastRun = Date(); j.lastBytes = total
            self.update(j)
        }
    }

    func runner(for id: Job.ID) -> Runner {
        if let r = runners[id] { return r }
        let r = Runner()
        runners[id] = r
        return r
    }
    let file: URL

    /// Snapshots: made-up jobs, nothing read or written.
    init(preview: [Job]) {
        jobs = preview
        file = URL(fileURLWithPath: "/dev/null")
    }

    /// Where the app keeps its own files (jobs, updates): the room's _devdata in a dev build.
    static var dataDirectory: URL {
        #if DEBUG
        return URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("_devdata/app")
        #else
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Archivist")
        #endif
    }

    init() {
        #if DEBUG
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("_devdata/app")
        #else
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Archivist")
        #endif
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        file = dir.appendingPathComponent("jobs.json")
        jobs = Self.read(file) ?? []
        // Same folder, same look; same destination, same animal (unless picked by hand). Set once
        // and saved, so nothing changes from one launch to the next.
        var fixed = false
        for i in jobs.indices {
            if !jobs[i].lookChosen, let d = jobs[i].destination {
                let l = Contrast.look(for: d, pool: Job.icons)
                if (jobs[i].icon, jobs[i].color) != (l.icon, l.color) { jobs[i].icon = l.icon; jobs[i].color = l.color; fixed = true }
            }
            var previous: String?
            var taken = Set<String>()
            for k in jobs[i].sources.indices {
                let l = Contrast.look(for: jobs[i].sources[k].path, pool: Source.icons, notColor: previous, notIcons: taken)
                taken.insert(l.icon)
                if (jobs[i].sources[k].icon, jobs[i].sources[k].color) != (l.icon, l.color) {
                    jobs[i].sources[k].icon = l.icon; jobs[i].sources[k].color = l.color; fixed = true
                }
                previous = l.color
            }
        }
        if fixed { save() }
    }

    /// The background helper writes results into the same file: take its newer ones, keep ours.
    func reload() {
        guard file.path != "/dev/null", let disk = Self.read(file) else { return }
        for d in disk { if let i = jobs.firstIndex(where: { $0.id == d.id }) { jobs[i].takeResults(from: d) } }
    }

    static func read(_ file: URL) -> [Job]? {
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        return (try? Data(contentsOf: file)).flatMap { try? dec.decode([Job].self, from: $0) }
    }

    func save() {
        guard file.path != "/dev/null" else { return }
        reload()
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        if let data = try? enc.encode(jobs) { try? data.write(to: file, options: .atomic) }
        Scheduler.sync(jobs)
    }

    @discardableResult
    func add() -> Job {
        var job = Job(title: "New backup")
        job.icon = Contrast.pick(from: Job.icons, on: job.color, avoid: Set(jobs.map(\.icon)))   // until it has a destination
        jobs.append(job)
        save()
        return job
    }

    func update(_ job: Job) {
        if let i = jobs.firstIndex(where: { $0.id == job.id }) { jobs[i] = job; save() }
    }

    func remove(_ id: Job.ID) {
        jobs.removeAll { $0.id == id }
        save()
    }
}

/// The drives a person can pick.
enum Volumes {
    struct Volume: Identifiable, Hashable {
        var id: String { path }
        let path: String
        let name: String
    }

    static func mounted() -> [Volume] {
        let keys: [URLResourceKey] = [.volumeLocalizedNameKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        return urls.compactMap { url in
            let name = (try? url.resourceValues(forKeys: Set(keys)).volumeLocalizedName) ?? url.lastPathComponent
            if url.path.hasPrefix("/System/Volumes") && url.path != "/System/Volumes/Data" { return nil }
            return Volume(path: url.path, name: name)
        }
    }

    /// The Mac's own drive is sealed and read-only at `/`; its files live on the Data volume.
    static func copyablePath(_ path: String) -> String { path == "/" ? "/System/Volumes/Data" : path }

    static func name(of path: String) -> String {
        mounted().first { $0.path == path }?.name ?? (path as NSString).lastPathComponent
    }
}

/// Runs a job on the engine, off the main thread, and publishes its progress.
@Observable
final class Runner {
    var running = false
    var stopping = false                 // Stop pressed: say so at once, even while the drive finishes
    var currentSource: String?
    var plannedFiles = 0
    var doneFiles = 0
    var plannedBytes: Int64 = 0
    var doneBytes: Int64 = 0
    /// Across every source: (files, bytes) done and in total.
    var overall: (files: Int, filesTotal: Int, bytes: Int64, bytesTotal: Int64) {
        let f = doneFiles + progress.filesDone, b = doneBytes + progress.bytesDone
        return (f, max(plannedFiles, doneFiles + progress.filesTotal, f), b, max(plannedBytes, doneBytes + progress.bytesTotal, b))
    }
    /// Every file copied, the run still flushing and setting folder dates.
    var finishing: Bool {
        let o = overall
        return running && progress.stage == .copying && o.filesTotal > 0 && o.files >= o.filesTotal
    }
    var progress = ArchivistCore.Progress()
    var bytesPerSecond: Double = 0
    var lanes: Lanes?
    var source: Drive?
    var destination: Drive?
    var problems: [String] = []
    private var engine: Engine?
    private var lastSample = (Date(), Int64(0))

    func start(_ job: Job, planned: (files: Int, bytes: Int64) = (0, 0), done: @escaping (_ summary: String, _ state: String, _ past: String?, _ total: Int64) -> Void) {
        guard !running else { return }
        running = true
        let awake = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled, .userInitiated], reason: "Backup")
        stopping = false
        stopRequested = false
        progress = .init()
        samples = []
        eta = nil
        etaAnchor = nil
        started = Date()
        shownFraction = 0
        problems = []
        bytesPerSecond = 0
        let runs = job.sources.filter { !$0.skip }.compactMap { s in job.target(for: s).map { (s, $0) } }
        if let d = job.destination, let root = job.pastRoot {   // earlier names (_Past, _Archive) -> _📚archive, once
            for old in Names.legacyPasts where !FileManager.default.fileExists(atPath: root) {
                let legacy = d + "/" + old
                if FileManager.default.fileExists(atPath: legacy) { try? FileManager.default.moveItem(atPath: legacy, toPath: root) }
            }
        }
        DevLog.write("backup start: \(job.title) -> \(job.destination ?? "?"), \(runs.count) sources, planned \(planned.files) files \(DevLog.mb(planned.bytes))")
        let backupStart = Date()
        let stamp: String = { let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd HHmmss"; return f.string(from: Date()) }()
        // One bar for the whole backup: totals planned from every source up front (the window's
        // surveys); each source's run adds to what is done before it.
        plannedFiles = planned.files
        plannedBytes = planned.bytes
        doneFiles = 0
        doneBytes = 0
        Thread.detachNewThread { [self] in
            var copied = 0, unchanged = 0, retired = 0
            var bytes: Int64 = 0, total: Int64 = 0
            var past: String?
            var problems: [String] = []
            var stopped = false
            for (i, (source, dst)) in runs.enumerated() where !stopped && !self.stopRequested {
                let src = source.readPath
                var opts = Options()
                opts.excluded = Set(source.leftOut)
                opts.patterns = source.namesLeftOut
                opts.destinationKind = job.destinationKind
                opts.finalFlush = i == runs.count - 1   // one full flush per backup, at its end
                opts.keepDeleted = job.keepDeleted
                opts.keepChanged = job.keepChanged
                opts.pastRoot = job.pastRoot
                opts.pastSubfolder = source.name
                opts.stamp = stamp
                DispatchQueue.main.async { self.currentSource = source.name }
                let engine = Engine(source: src, destination: dst, options: opts)
                DispatchQueue.main.async {
                    self.engine = engine
                    self.source = try? Drive.of(path: src)
                    self.destination = try? Drive.of(path: FileManager.default.fileExists(atPath: dst) ? dst : (dst as NSString).deletingLastPathComponent)
                    if let s = self.source, let d = self.destination { self.lanes = Lanes.choose(source: s.kind, destination: d.kind) }
                    self.lastSample = (Date(), self.overall.bytes)
                }
                engine.onProgress = { p in DispatchQueue.main.async { self.tick(p) } }
                do {
                    DevLog.write("source start: \(source.name) (\(src)) -> \(dst)")
                    let r = try engine.run()
                    let mbs = r.seconds > 0 ? Double(r.bytes) / r.seconds / 1e6 : 0
                    DevLog.write(String(format: "source done: %@ [%@ %@ -> %@ %@, lanes %d/%d%@] copied %d (%@), unchanged %d, retired %d, %.1f s, %.1f MB/s, %.0f files/s, problems %d%@",
                        source.name, r.source.kind.rawValue, r.source.fileSystem, r.destination.kind.rawValue, r.destination.fileSystem,
                        r.lanes.small, r.lanes.big, r.lanes.diskOrder ? " disk-order" : "", r.copied, DevLog.mb(r.bytes), r.unchanged, r.retired,
                        r.seconds, mbs, r.seconds > 0 ? Double(r.copied) / r.seconds : 0, r.problems.count, r.stopped ? " STOPPED" : ""))
                    for p in r.problems.prefix(20) { DevLog.write("  problem: \(p)") }
                    DispatchQueue.main.async {
                        self.doneFiles += self.progress.filesTotal
                        self.doneBytes += self.progress.bytesTotal
                    }
                    copied += r.copied; unchanged += r.unchanged; retired += r.retired; bytes += r.bytes
                    total += r.sourceBytes   // counted by the run itself (a second scan per source cost ~0.5 s)
                    past = job.pastRoot ?? past
                    problems += r.problems
                    stopped = r.stopped
                } catch {
                    problems.append("\(error)")
                    DevLog.write("source failed: \(source.name): \(error)")
                }
            }
            let size = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
            var parts: [String] = []
            if stopped || self.stopRequested { parts.append("Stopped") }
            if copied > 0 || retired > 0 { parts.append("\(copied) copied (\(size)), \(unchanged) already there") }
            else if problems.isEmpty { parts.append("Nothing had changed") }
            else { parts.append("Nothing copied") }
            if retired > 0 { parts.append("\(retired) earlier versions kept") }
            if !problems.isEmpty { parts.append("\(problems.count) not copied") }
            let summary = parts.joined(separator: ", ")
            DevLog.write(String(format: "backup end: %@ — %@ in %.1f s", job.title, summary, Date().timeIntervalSince(backupStart)))
            if let root = job.pastRoot, !stopped, !self.stopRequested {
                let removed = Past.prune(root, keepDays: job.keepDays, minFree: job.makeRoom ? Past.guardSpace(root) : 0)
                if !removed.isEmpty { DevLog.write("earlier versions removed: \(removed.joined(separator: ", "))") }
            }
            DispatchQueue.main.async {
                ProcessInfo.processInfo.endActivity(awake)
                self.problems = problems
                self.running = false
                self.stopping = false
                self.engine = nil
                let state = stopped || self.stopRequested ? "Stopped partway"
                    : problems.isEmpty ? "Backed up"
                    : problems.count == 1 ? "Backed up, 1 file skipped" : "Backed up, \(problems.count) files skipped"
                done(summary, state, past, total)
            }
        }
    }

    func stop() {
        guard running, !stopping else { return }
        stopping = true
        stopRequested = true
        engine?.stop()
        DevLog.write("stop pressed")
    }
    @ObservationIgnored private var stopRequested = false

    // Time left. Small files cost time per file, big files per byte, and the two lanes mix
    // them; so both rates are measured over the last 30 s and the slower finish wins.
    var eta: TimeInterval?
    private var samples: [(Date, Int, Int64)] = []
    @ObservationIgnored private var lastLog = Date.distantPast

    /// The clock shown: counts down one second per second from the last estimate; a new
    /// estimate is eased in, never jumped to.
    private var etaAnchor: (date: Date, seconds: TimeInterval)?
    private var started = Date()

    func debugAnchor(_ seconds: TimeInterval) { etaAnchor = (Date(), seconds); started = Date().addingTimeInterval(-160) } // snapshots

    func remaining(at now: Date) -> TimeInterval? {
        guard let a = etaAnchor else { return nil }
        return max(0, a.seconds - now.timeIntervalSince(a.date))
    }

    /// The bar's fraction: never moves backwards when the estimate grows; it waits instead.
    @ObservationIgnored private var shownFraction = 0.0
    func steadyFraction(at now: Date) -> Double {
        if finishing { shownFraction = 1; return 1 }
        let f = max(shownFraction, fraction(at: now))
        shownFraction = f
        return f
    }

    func fraction(at now: Date) -> Double {
        let elapsed = now.timeIntervalSince(started)
        if let left = remaining(at: now), elapsed + left > 0 { return min(1, elapsed / (elapsed + left)) }
        let o = overall
        return o.bytesTotal > 0 ? Double(o.bytes) / Double(o.bytesTotal) : 0
    }

    func etaWords(at now: Date) -> String {
        guard progress.stage == .copying else { return "Looking for changes…" }
        guard let left = remaining(at: now) else { return "Working out the time left…" }
        let s = Int(left.rounded())
        if s < 60 { return "\(max(s, 1)) s left" }
        if s < 3600 { return String(format: "%d:%02d left", s / 60, s % 60) }
        return String(format: "%d h %02d min left", s / 3600, (s % 3600) / 60)
    }

    private func updateETA(_ p0: ArchivistCore.Progress) {
        let now = Date()
        let o = overall
        let p = (filesDone: o.files, filesTotal: o.filesTotal, bytesDone: o.bytes, bytesTotal: o.bytesTotal)
        samples.append((now, p.filesDone, p.bytesDone))
        samples.removeAll { now.timeIntervalSince($0.0) > 30 }
        guard let first = samples.first, now.timeIntervalSince(first.0) >= 5 else { return }
        let dt = now.timeIntervalSince(first.0)
        let fileRate = Double(p.filesDone - first.1) / dt
        let byteRate = Double(p.bytesDone - first.2) / dt
        let byFiles = fileRate > 0 ? Double(p.filesTotal - p.filesDone) / fileRate : .infinity
        let byBytes = byteRate > 0 ? Double(p.bytesTotal - p.bytesDone) / byteRate : .infinity
        let raw = max(byFiles.isFinite ? byFiles : 0, byBytes.isFinite ? byBytes : 0)
        guard raw > 0 || p.filesDone == p.filesTotal else { return }
        eta = eta.map { $0 * 0.8 + raw * 0.2 } ?? raw     // calm: no jumping minute to minute
        // The shown clock never ticks up: a shorter estimate eases in; a slightly longer one holds
        // the clock still; one over 25% longer jumps once (crawling up second by second felt broken).
        let shown = remaining(at: now) ?? eta!
        if eta! < shown { etaAnchor = (now, shown + (eta! - shown) * 0.25) }
        else if eta! > shown * 1.25 { etaAnchor = (now, eta!) }
        else { etaAnchor = (now, shown) }
    }

    private func tick(_ p: ArchivistCore.Progress) {
        progress = p
        if p.stage == .copying { updateETA(p) }
        if Date().timeIntervalSince(lastLog) >= 5 {
            lastLog = Date()
            let o = overall
            DevLog.write(String(format: "progress: %@ %d/%d files, %@ of %@, %.1f MB/s, left %@", currentSource ?? "?", o.files, o.filesTotal,
                                DevLog.mb(o.bytes), DevLog.mb(o.bytesTotal), bytesPerSecond / 1e6, remaining(at: Date()).map { String(format: "%.0f s", $0) } ?? "?"))
        }
        let b = overall.bytes
        let dt = Date().timeIntervalSince(lastSample.0)
        if dt >= 0.5 { bytesPerSecond = bytesPerSecond == 0 ? Double(b - lastSample.1) / dt : bytesPerSecond * 0.7 + Double(b - lastSample.1) / dt * 0.3; lastSample = (Date(), b) }
    }
}
