import ArchivistCore
import Foundation
import Observation
import os

/// One source: a folder or a whole drive, with its own rules.
struct Source: Codable, Identifiable, Hashable {
    var id = UUID()
    var path: String
    var skip = false                 // "Exclude": this row is not copied, and is left out of any Include row that holds it
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
        skip = try c.decodeIfPresent(Bool.self, forKey: .skip) ?? false
        leftOut = try c.decodeIfPresent([String].self, forKey: .leftOut) ?? []
        patterns = try c.decodeIfPresent([String].self, forKey: .patterns) ?? []
        skipJunk = try c.decodeIfPresent(Bool.self, forKey: .skipJunk) ?? false
        addedAt = try c.decodeIfPresent(Date.self, forKey: .addedAt)
        let seed = Int(id.uuid.1)   // saved before pictures: a steady pick, never changing between launches
        icon = try c.decodeIfPresent(String.self, forKey: .icon) ?? Source.icons[seed % Source.icons.count]
        color = Nippon.current(try c.decodeIfPresent(String.self, forKey: .color) ?? Nippon.colors[seed % Nippon.colors.count].hex)
    }

    /// The folder or drive carries its own Finder icon (a hidden `Icon\r` file, or a drive's
    /// `.VolumeIcon.icns`): show that, not one of ours.
    var hasCustomIcon: Bool { facts.icon }
    var isDrive: Bool { facts.drive }

    /// Looked up once per path: the window asks on every redraw, and on a network drive each
    /// look is a trip to the server, on the main thread (it froze the window while counting).
    private static let known = OSAllocatedUnfairLock(initialState: [String: (drive: Bool, icon: Bool)]())
    private var facts: (drive: Bool, icon: Bool) {
        if let f = Source.known.withLock({ $0[path] }) { return f }
        let drive = (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isVolumeKey]).isVolume) == true
        let f = (drive: drive, icon: FileManager.default.fileExists(atPath: path + (drive ? "/.VolumeIcon.icns" : "/Icon\r")))
        // Not remembered while the path is away (a share or disk not mounted yet): what it is
        // can only be seen once it is there.
        if FileManager.default.fileExists(atPath: path) { Source.known.withLock { $0[path] = f } }
        return f
    }
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
    var lastStart: Date?                             // when the last finished backup started: files changed after it are live, not missed
    var lastSkipped: [String: [String]] = [:]        // source id → files the last backup could not read (bounded at 200 each)
    var icon: String = Job.icons.randomElement()!   // a picture per backup, so a glance tells them apart
    var color: String = Nippon.colors.randomElement()!.hex
    var lookChosen = false                           // picked by hand in Settings: then it never follows the destination
    var schedule: Schedule = .byHand { didSet { if schedule != oldValue { scheduleSet = Date() } } }
    var scheduleSet: Date?                           // when the schedule was last changed: a time before it is not "missed"
    var destinationKind: DriveKind?                  // nil = let Archivist decide (Settings)
    var keepDeleted = true                           // earlier versions (Settings)
    var keepChanged = true
    var keepDays: Int? = 365                         // nil = keep by age forever
    var threads: Int?                                // copies at once; nil = Automatic (by the drives)
    var makeRoom = true                              // drive running low: oldest earlier versions go first
    /// One place for this backup's earlier versions.
    var pastRoot: String? { destination.map { $0 + "/" + Names.past } }
    var lastRun: Date?                               // when it last finished, by hand or by schedule
    var destinationSince: Date?                      // the helper's note: destination present since

    /// Fluent emoji a backup can wear (picked at random, changeable in the Destination panel).
    /// Animals for backups (sources wear plants and food).
    // 24: a 4 × 6 grid in Settings, like the 24 colours. (The snail is the drive-speed "Very slow".)
    static let icons = ["fox", "owl", "dragon", "octopus", "turtle", "spouting_whale", "butterfly", "honeybee", "hedgehog",
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
            lastBytes = other.lastBytes; lastStart = other.lastStart; lastSkipped = other.lastSkipped
        }
        destinationSince = other.destinationSince
    }

    var ready: Bool { sources.contains { !$0.skip } && destination != nil }

    /// Each source lands in its own folder at the destination, named after it.
    func target(for s: Source) -> String? { destination.map { $0 + "/" + s.name } }

    /// What a source leaves out: every Exclude row that lies inside it, as a path relative to it.
    func excluded(in s: Source) -> Set<String> {
        let root = (s.path as NSString).standardizingPath
        return Set(s.leftOut + sources.filter { $0.skip && $0.id != s.id }.compactMap { x in
            let p = (x.path as NSString).standardizingPath
            return p.hasPrefix(root + "/") ? String(p.dropFirst(root.count + 1)) : nil
        })
    }

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
        lastStart = try c.decodeIfPresent(Date.self, forKey: .lastStart)
        lastSkipped = try c.decodeIfPresent([String: [String]].self, forKey: .lastSkipped) ?? [:]
        schedule = (try? c.decodeIfPresent(Schedule.self, forKey: .schedule)) ?? .byHand   // older shapes fall back
        destinationKind = try c.decodeIfPresent(DriveKind.self, forKey: .destinationKind)
        keepDeleted = try c.decodeIfPresent(Bool.self, forKey: .keepDeleted) ?? true
        keepChanged = try c.decodeIfPresent(Bool.self, forKey: .keepChanged) ?? true
        keepDays = c.contains(.keepDays) ? try c.decodeIfPresent(Int.self, forKey: .keepDays) : 365
        makeRoom = try c.decodeIfPresent(Bool.self, forKey: .makeRoom) ?? true
        threads = try c.decodeIfPresent(Int.self, forKey: .threads)
        lastRun = try c.decodeIfPresent(Date.self, forKey: .lastRun)
        destinationSince = try c.decodeIfPresent(Date.self, forKey: .destinationSince)
        scheduleSet = try c.decodeIfPresent(Date.self, forKey: .scheduleSet)
        // Backups saved before icons: a steady pick from the id, so it never changes between launches.
        let saved = try c.decodeIfPresent(String.self, forKey: .icon)
        icon = saved.flatMap { Job.icons.contains($0) || $0 == "snail" ? $0 : nil } ?? Job.icons[Int(id.uuid.0) % Job.icons.count]  // backups are animals now
        color = Nippon.current(try c.decodeIfPresent(String.self, forKey: .color) ?? Nippon.colors[Int(id.uuid.2) % Nippon.colors.count].hex)
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
    /// Each path's drive and each destination's room, kept across tab switches.
    var drives: [String: Drive] = [:]
    var spaces: [String: (free: Int64, total: Int64)] = [:]

    /// Starts a backup: the button and the dev remote both come here.
    func start(_ id: Job.ID, planned: (files: Int, bytes: Int64) = (0, 0)) {
        guard let job = jobs.first(where: { $0.id == id }) else { return }
        var planned = planned
        if planned.files == 0 {   // started from outside the window: take the shared counts
            let live = job.sources.filter { !$0.skip }.compactMap { surveys[$0.id] }.filter(\.compared)
            planned = (live.reduce(0) { $0 + $1.toCopy }, live.reduce(0) { $0 + $1.bytesToCopy })
        }
        // Smallest folder first, so the bar (smallest at the left) fills left to right.
        var ordered = job
        ordered.sources = job.sources.enumerated().sorted { (a: (offset: Int, element: Source), b: (offset: Int, element: Source)) in
            let x = surveys[a.element.id]?.bytes ?? -1, y = surveys[b.element.id]?.bytes ?? -1
            return x != y ? x < y : a.offset < b.offset
        }.map { $0.element }
        let live = job.sources.filter { !$0.skip }.compactMap { surveys[$0.id] }.filter(\.compared)
        runner(for: id).plannedSmall = live.reduce(0) { $0 + $1.smallToCopy }
        runner(for: id).plannedBig = live.reduce(0) { $0 + $1.bigBytesToCopy }
        runner(for: id).start(ordered, planned: planned) { [weak self] summary, state, past, total in
            guard let self, let i = self.jobs.firstIndex(where: { $0.id == id }) else { return }
            var j = self.jobs[i]
            j.lastResult = summary; j.lastState = state; j.lastPast = past ?? j.lastPast; j.lastRun = Date(); j.lastBytes = total
            if let done = self.runner(for: id).finished { j.lastStart = done.start; j.lastSkipped = done.skipped }   // only a backup that ran to its end
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
    /// Which source is copying and which are done, for the bar: each source's chunk fills with
    /// its own progress, not with the time estimate (Helios, 2026-11-28).
    var currentSourceID: Source.ID?
    var doneSources: Set<Source.ID> = []
    var plannedFiles = 0
    var plannedSmall = 0
    var doneSmall = 0
    var plannedBig: Int64 = 0
    var doneBig: Int64 = 0
    var doneFiles = 0
    var plannedBytes: Int64 = 0
    var doneBytes: Int64 = 0
    /// Across every source: (files, bytes) done and in total.
    var overall: (files: Int, filesTotal: Int, bytes: Int64, bytesTotal: Int64) {
        let f = doneFiles + progress.filesDone, b = doneBytes + progress.bytesDone + progress.inFlight
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
    private var lastSample = (Date(), Int64(0), 0)
    var filesPerSecond: Double = 0
    /// How fast the destination drive is working now against the best it has done (0…1), remembered
    /// per drive across runs: an SMR drive busy cleaning shows Slow before anyone wonders.
    var pace: Double?
    @ObservationIgnored private var paceKey = ""
    @ObservationIgnored private var paceStart = Date()

    func start(_ job: Job, planned: (files: Int, bytes: Int64) = (0, 0), done: @escaping (_ summary: String, _ state: String, _ past: String?, _ total: Int64) -> Void) {
        guard !running else { return }
        running = true
        finished = nil
        let awake = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled, .userInitiated], reason: "Backup")
        stopping = false
        stopRequested = false
        progress = .init()
        lastStep = nil
        eta = nil
        etaAnchor = nil
        started = Date()
        shownFraction = 0
        problems = []
        bytesPerSecond = 0
        filesPerSecond = 0
        pace = nil
        paceStart = Date()
        paceKey = "pace:" + (job.destination.map { p in let c = (p as NSString).pathComponents; return c.count > 2 && c[1] == "Volumes" ? c[2] : "/" } ?? "")
        // This drive's past runs (by its volume UUID), or a tired spinning disk's speeds until it has some.
        driveKey = job.destination.map { DriveMemories.key(for: $0) } ?? ""
        memory = DriveMemories.load()[driveKey] ?? DriveMemory(name: job.destination.map { DriveMemories.name(for: $0) } ?? "")
        secPerSmall = memory.secondsPerSmallFile ?? 1.0 / 40
        secPerMB = memory.secondsPerMB ?? 1.0 / 20   // 20 MB/s: a tired spinning disk, not a fresh one
        measuredSmall = false; measuredBig = false; smallSeconds = 0; bigSeconds = 0
        phase = (0, 0, 0, 0); phaseTick = nil
        // A drive with a past gives a time at once: no "Calculating" wait.
        if !memory.runs.isEmpty && (plannedSmall > 0 || plannedBig > 0) {
            etaAnchor = (Date(), memory.estimate(smallFiles: plannedSmall, bigMB: Double(plannedBig) / 1e6, defaults: (1.0 / 40, 1.0 / 20)))
        }
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
        doneSources = []
        currentSourceID = nil
        doneBytes = 0
        doneSmall = 0
        doneBig = 0
        Thread.detachNewThread { [self] in
            var copied = 0, unchanged = 0, retired = 0
            var bytes: Int64 = 0, total: Int64 = 0
            var past: String?
            var problems: [String] = []
            var skipped: [String: [String]] = [:]
            var stopped = false, failed = false, sourceGone = false
            // The destination drive gone (unplugged, asleep): stop, and say that once, not per file.
            func unplugged() -> Bool { job.destination.map { !FileManager.default.fileExists(atPath: $0) } ?? false }
            for (i, (source, dst)) in runs.enumerated() where !stopped && !self.stopRequested && !unplugged() {
                let src = source.readPath
                var opts = Options()
                opts.excluded = job.excluded(in: source)
                opts.patterns = source.namesLeftOut
                opts.destinationKind = job.destinationKind
                opts.threads = job.threads
                opts.finalFlush = i == runs.count - 1   // one full flush per backup, at its end
                opts.keepDeleted = job.keepDeleted
                opts.keepChanged = job.keepChanged
                opts.pastRoot = job.pastRoot
                opts.pastSubfolder = source.name
                opts.stamp = stamp
                DispatchQueue.main.async { self.currentSource = source.name; self.currentSourceID = source.id }
                let engine = Engine(source: src, destination: dst, options: opts)
                DispatchQueue.main.async {
                    self.engine = engine
                    self.source = try? Drive.of(path: src)
                    self.destination = try? Drive.of(path: FileManager.default.fileExists(atPath: dst) ? dst : (dst as NSString).deletingLastPathComponent)
                    if let s = self.source, let d = self.destination { self.lanes = Lanes.choose(source: s.kind, destination: d.kind) }
                    self.lastSample = (Date(), self.overall.bytes, self.overall.files)
                }
                engine.onProgress = { p in DispatchQueue.main.async { self.tick(p); if p.stage == .copying { Access.shared.answered([src, dst]) } } }
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
                        self.doneSources.insert(source.id)
                        self.doneFiles += self.progress.filesTotal
                        self.doneBytes += self.progress.bytesTotal
                        self.doneSmall += self.progress.smallTotal
                        self.doneBig += self.progress.bigBytesTotal
                        self.progress = .init()   // the next source starts from nothing (a stale count gave negative rates)
                        self.lastSample = (Date(), self.overall.bytes, self.overall.files)
                    }
                    copied += r.copied; unchanged += r.unchanged; retired += r.retired; bytes += r.bytes
                    total += r.sourceBytes   // counted by the run itself (a second scan per source cost ~0.5 s)
                    past = job.pastRoot ?? past
                    problems += r.problems
                    if r.sourceGone { sourceGone = true; DevLog.write("source disconnected: \(source.name)") }
                    if !r.failed.isEmpty { skipped[source.id.uuidString] = Array(r.failed.prefix(200)) }
                    stopped = r.stopped
                } catch {
                    failed = true
                    problems.append("Folder \(source.name) not copied: \(error)")
                    DevLog.write("source failed: \(source.name): \(error)")
                }
            }
            let gone = unplugged()
            if gone {
                DevLog.write("destination disconnected: \(problems.count) problems after it went are left out")
                problems = ["The destination was disconnected partway. Start again when it is back."]
            }
            let size = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
            var parts: [String] = []
            if gone { parts.append("Destination disconnected") }
            else if sourceGone { parts.append("Source disconnected") }
            else if stopped || self.stopRequested { parts.append("Stopped") }
            if copied > 0 || retired > 0 { parts.append("\(copied) copied (\(size)), \(unchanged) already there") }
            else if problems.isEmpty { parts.append("Nothing had changed") }
            else { parts.append("Nothing copied") }
            if retired > 0 { parts.append("\(retired) earlier versions kept") }
            if !problems.isEmpty && !gone && !sourceGone { parts.append("\(problems.count) not copied") }
            let summary = parts.joined(separator: ", ")
            DevLog.write(String(format: "backup end: %@ — %@ in %.1f s", job.title, summary, Date().timeIntervalSince(backupStart)))
            if let root = job.pastRoot, !stopped, !self.stopRequested, !gone {
                let removed = Past.prune(root, keepDays: job.keepDays, minFree: job.makeRoom ? Past.guardSpace(root) : 0)
                if !removed.isEmpty { DevLog.write("earlier versions removed: \(removed.joined(separator: ", "))") }
            }
            DispatchQueue.main.async {
                // What this drive did, for the next estimate: only a backup that ran to its end.
                if !(stopped || self.stopRequested || gone || failed), !self.driveKey.isEmpty {
                    self.memory.add(.init(smallFiles: self.doneSmall, bigMB: Double(self.doneBig) / 1e6,
                                          looking: self.phase.looking, small: self.phase.small, big: self.phase.big, finishing: self.phase.finishing))
                    DriveMemories.save(self.memory, for: self.driveKey)
                    DevLog.write(String(format: "drive memory %@: looking %.0f s, small %.0f s (%d files), big %.0f s (%.0f MB), finishing %.0f s",
                                        self.memory.name, self.phase.looking, self.phase.small, self.doneSmall, self.phase.big,
                                        Double(self.doneBig) / 1e6, self.phase.finishing))
                }
                ProcessInfo.processInfo.endActivity(awake)
                self.problems = problems
                self.finished = stopped || self.stopRequested || gone || failed ? nil : (self.started, skipped)
                self.running = false
                self.stopping = false
                self.engine = nil
                let state = gone ? "Destination disconnected"
                    : sourceGone ? "Source disconnected"
                    : stopped || self.stopRequested ? "Stopped partway"
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

    // Time left. Every file costs a fixed overhead (create, rename, a head move on a spinning
    // disk) plus its bytes: seconds ≈ a·files + b·bytes. a and b are fitted over the whole run,
    // each step weighted by how recent it is (half-life 5 min), so a patch of tiny or huge files
    // only nudges the estimate. The old "last 30 s, slower rate wins" read 10 GB of mostly tiny
    // files on a spinning disk as 40 hours.
    var eta: TimeInterval?
    /// Seconds per small file and per big megabyte on this drive: learned in the run, remembered
    /// per drive across runs, and a careful default for the drive's kind before either.
    @ObservationIgnored private var secPerSmall = 0.03
    @ObservationIgnored private var secPerMB = 0.03
    @ObservationIgnored private var measuredSmall = false
    @ObservationIgnored private var driveKey = ""
    @ObservationIgnored private var memory = DriveMemory(name: "")
    /// Seconds spent in each stretch of this run, for the drive's memory.
    @ObservationIgnored private var phase = (looking: 0.0, small: 0.0, big: 0.0, finishing: 0.0)
    @ObservationIgnored private var phaseTick: (date: Date, small: Int, big: Int64)?
    @ObservationIgnored private var measuredBig = false
    @ObservationIgnored private var smallSeconds = 0.0   // how long each rate has been measured this run
    @ObservationIgnored private var bigSeconds = 0.0
    @ObservationIgnored private var lastStep: (date: Date, files: Int, bytes: Int64)?
    @ObservationIgnored private var lastLog = Date.distantPast

    /// The clock shown: counts down one second per second from the last estimate; a new
    /// estimate is eased in, never jumped to.
    private var etaAnchor: (date: Date, seconds: TimeInterval)?
    private var started = Date()
    /// The last backup that ran to its end: when it started and what it could not read, for the source rows.
    var finished: (start: Date, skipped: [String: [String]])?

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

    /// "6:15", "1 h 05 min", "40 s".
    static func clock(_ t: TimeInterval) -> String {
        let s = Int(t.rounded())
        if s < 60 { return "\(max(s, 1)) s" }
        if s < 3600 { return String(format: "%d:%02d", s / 60, s % 60) }
        return String(format: "%d h %02d min", s / 3600, (s % 3600) / 60)
    }
    var elapsed: TimeInterval { Date().timeIntervalSince(started) }

    func etaWords(at now: Date) -> String {
        guard progress.stage == .copying else { return "Looking for changes…" }
        guard let left = remaining(at: now) else { return "Working out the time left…" }
        let s = Int(left.rounded())
        if s < 60 { return "\(max(s, 1)) s left" }
        if s < 3600 { return String(format: "%d:%02d left", s / 60, s % 60) }
        return String(format: "%d h %02d min left", s / 3600, (s % 3600) / 60)
    }

    private func updateETA(_ p0: ArchivistCore.Progress) {
        // Two kinds of work, priced apart: seconds per small file and seconds per big megabyte, each
        // measured only while that kind is moving (a small-file stretch said nothing about big files
        // and priced 4 GB of them as nearly free). Until measured, the drive's own past speeds.
        let now = Date()
        let small = doneSmall + progress.smallDone
        let big = Double(doneBig + progress.bigBytesDone + progress.inFlight) / 1e6
        guard let last = lastStep else { lastStep = (now, small, Int64(big * 1e6)); return }
        let dt = now.timeIntervalSince(last.date)
        guard dt >= 2 else { return }
        let dSmall = Double(small - last.files), dBig = big - Double(last.bytes) / 1e6
        // The last five minutes count most. Early on, what this run measured outweighs the guess it
        // started from (the drive's past, or a tired disk's default counts as 30 s of measuring):
        // a fast NVMe once showed 27 minutes left for a 23-second copy.
        func weight(_ measured: Double) -> Double { max(1 - pow(0.5, dt / 300), dt / (measured + dt + (memory.runs.isEmpty ? 0 : 30))) }
        let both = lanes?.together ?? false
        if dSmall > 0 && (both || dBig < 1) { let w = weight(smallSeconds); secPerSmall = secPerSmall * (1 - w) + (dt / dSmall) * w; smallSeconds += dt; measuredSmall = true }
        if dBig >= 1 && (both || dSmall < 1) { let w = weight(bigSeconds); secPerMB = secPerMB * (1 - w) + (dt / dBig) * w; bigSeconds += dt; measuredBig = true }
        lastStep = (now, small, Int64(big * 1e6))
        guard now.timeIntervalSince(started) >= 8 else { return }
        let smallLeft = Double(max(0, max(plannedSmall, doneSmall + progress.smallTotal) - small))
        let bigLeft = max(0, Double(max(plannedBig, doneBig + progress.bigBytesTotal)) / 1e6 - big)
        let a = smallLeft * secPerSmall, bTime = bigLeft * secPerMB
        let copyTime = both ? max(a, bTime) : a + bTime   // a spinning disk does one after the other
        // Folder dates and the final flush, as this drive took them before.
        let files = Double(max(plannedSmall, doneSmall + progress.smallTotal)) + max(1, Double(max(plannedBig, doneBig + progress.bigBytesTotal)) / 50e6)
        let raw = copyTime + (finishing ? 0 : files * (memory.finishingPerFile ?? 0))
        eta = eta.map { raw < $0 * 0.5 ? raw : $0 * 0.8 + raw * 0.2 } ?? raw     // calm: no jumping minute to minute
        // The shown clock never ticks up: a shorter estimate eases in; a slightly longer one holds
        // the clock still; one over 25% longer jumps once (crawling up second by second felt broken).
        let shown = remaining(at: now) ?? eta!
        if eta! < shown * 0.5 { etaAnchor = (now, eta!) }   // far too long before: drop to it at once
        else if eta! < shown { etaAnchor = (now, shown + (eta! - shown) * 0.25) }
        else if eta! > shown * 1.25 { etaAnchor = (now, eta!) }
        else { etaAnchor = (now, shown) }
    }

    private func tick(_ p: ArchivistCore.Progress) {
        progress = p
        // Which stretch this moment belongs to: looking, small files, big files, or finishing.
        let now = Date(), small = doneSmall + p.smallDone, big = doneBig + p.bigBytesDone + p.inFlight
        if let t = phaseTick {
            let dt = now.timeIntervalSince(t.date)
            if p.stage == .looking { phase.looking += dt }
            else if finishing { phase.finishing += dt }
            else if small > t.small && big == t.big { phase.small += dt }
            else if big > t.big && small == t.small { phase.big += dt }
            else { phase.small += dt / 2; phase.big += dt / 2 }
        }
        phaseTick = (now, small, big)
        if p.stage == .copying { updateETA(p) }
        if Date().timeIntervalSince(lastLog) >= 5 {
            lastLog = Date()
            let o = overall
            DevLog.write(String(format: "progress: %@ %d/%d files, %@ of %@, %.1f MB/s, left %@", currentSource ?? "?", o.files, o.filesTotal,
                                DevLog.mb(o.bytes), DevLog.mb(o.bytesTotal), bytesPerSecond / 1e6, remaining(at: Date()).map { String(format: "%.0f s", $0) } ?? "?"))
        }
        let b = overall.bytes
        let dt = Date().timeIntervalSince(lastSample.0)
        let f = overall.files
        if dt >= 0.5 {
            let bNow = Double(b - lastSample.1) / dt, fNow = Double(f - lastSample.2) / dt
            bytesPerSecond = bytesPerSecond == 0 ? bNow : bytesPerSecond * 0.85 + bNow * 0.15
            filesPerSecond = filesPerSecond == 0 ? fNow : filesPerSecond * 0.85 + fNow * 0.15
            lastSample = (Date(), b, f)
            // Best this drive has done, by files/s (small files) and by bytes/s (big ones); the pace is
            // whichever kind of work it is doing best at right now, against that best.
            let d = UserDefaults.standard
            let bestF = max(d.double(forKey: paceKey + ".f"), filesPerSecond), bestB = max(d.double(forKey: paceKey + ".b"), bytesPerSecond)
            if Date().timeIntervalSince(paceStart) > 15 {   // the first seconds are cache, not the drive
                d.set(bestF, forKey: paceKey + ".f"); d.set(bestB, forKey: paceKey + ".b")
                pace = min(1, max(bestF > 0 ? filesPerSecond / bestF : 0, bestB > 0 ? bytesPerSecond / bestB : 0))
            }
        }
    }
}

extension Double { var nonZero: Double? { self > 0 ? self : nil } }

/// Every destination drive's memory, in one small file beside the jobs (keyed by volume UUID).
enum DriveMemories {
    static var file: URL { JobStore.dataDirectory.appendingPathComponent("drives.json") }

    static func key(for path: String) -> String {
        var url = URL(fileURLWithPath: path)
        while !FileManager.default.fileExists(atPath: url.path) && url.path != "/" { url.deleteLastPathComponent() }
        let v = try? url.resourceValues(forKeys: [.volumeUUIDStringKey, .volumeNameKey])
        return v?.volumeUUIDString ?? v?.volumeName ?? ""
    }

    static func name(for path: String) -> String {
        var url = URL(fileURLWithPath: path)
        while !FileManager.default.fileExists(atPath: url.path) && url.path != "/" { url.deleteLastPathComponent() }
        return (try? url.resourceValues(forKeys: [.volumeNameKey]))?.volumeName ?? url.lastPathComponent
    }

    static func load() -> [String: DriveMemory] {
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        return (try? Data(contentsOf: file)).flatMap { try? dec.decode([String: DriveMemory].self, from: $0) } ?? [:]
    }

    /// Forget a drive's past runs and its best pace: estimates start fresh from the next run
    /// (runs timed by a slower Archivist kept pricing a faster one at the old speed).
    static func forget(_ path: String) {
        var all = load()
        all[key(for: path)] = nil
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let d = try? enc.encode(all) { try? d.write(to: file, options: .atomic) }
        let c = (path as NSString).pathComponents
        let pace = "pace:" + (c.count > 2 && c[1] == "Volumes" ? c[2] : "/")
        UserDefaults.standard.removeObject(forKey: pace + ".f"); UserDefaults.standard.removeObject(forKey: pace + ".b")
    }

    static func save(_ m: DriveMemory, for key: String) {
        var all = load()
        all[key] = m
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let d = try? enc.encode(all) { try? d.write(to: file, options: .atomic) }
    }
}
