import Darwin
import Foundation

/// How wide each lane runs, from the two drives (measured: SSDs gain from parallel small-file copies, spinning disks don't).
public struct Lanes: Sendable, Equatable {
    public var small: Int
    public var big: Int
    public var together: Bool       // run both lanes at once (never when a disk seeks)
    public var diskOrder: Bool      // sort small files by physical offset on the source

    public init(small: Int, big: Int, together: Bool, diskOrder: Bool) {
        self.small = small; self.big = big; self.together = together; self.diskOrder = diskOrder
    }

    public static func choose(source: DriveKind, destination: DriveKind) -> Lanes {
        if source == .network || destination == .network {
            return Lanes(small: 16, big: 1, together: true, diskOrder: false)       // §6: 11x at 16 in flight
        }
        if source.seeks {
            return Lanes(small: 1, big: 1, together: false, diskOrder: true)        // §3b: disk order 2.7-4x
        }
        if destination.seeks {
            return Lanes(small: 1, big: 1, together: false, diskOrder: false)       // §3 + race: one stream beat two onto SMR
        }
        return Lanes(small: 8, big: 2, together: true, diskOrder: false)            // §1-2: 8 small, 1-2 big
    }
}

public struct Options: Sendable {
    public var excluded: Set<String> = []
    public var patterns: [String] = []       // names left out anywhere (`*.tmp`); destination copies of them are kept, not retired
    /// Finder's per-folder view settings: Finder rewrites them whenever a folder is opened, so
    /// copying them only fills _Archive with noise (seen on a first backup).
    public static let alwaysLeftOut = [".DS_Store"]
    public var dryRun = false
    public var sourceKind: DriveKind?
    public var destinationKind: DriveKind?
    public var lanes: Lanes?                 // override (bench, tests)
    public var bigFile: Int64 = 8 << 20      // at or above: the big-file lane
    public var allowClone = true             // tests turn it off to exercise the copy path on one volume
    /// The full drive flush at the end. A backup of several sources asks it only of the last:
    /// on a spinning or SMR drive each full flush empties the drive's whole cache. Earlier
    /// sources are still ordered by their write barriers (no half files after a crash).
    public var finalFlush = true
    public var threads: Int?                 // the person's own number of copies at once; nil = chosen by the drives
    /// A write barrier per batch of 64 files. Off: on a spinning disk each one is a journal flush
    /// and head moves (HFS+ image: 1.95 s vs 1.5 s for 3,000 files; ditto 0.8 s). Crash safety comes
    /// from the run lock instead: a run that died has everything it wrote copied again.
    public var barrier = false
    /// A file new to the destination is written at its own name: nothing good can be lost there,
    /// and a half file from a crash is copied again (run lock). Replacements still go temp → rename.
    public var directNew = true
    public var callbackFrom: Int64 = 8 << 20  // files this big get the Stop callback (bench switch)
    /// Earlier versions. keepDeleted off: a file gone from the source is removed from the backup
    /// (a mirror). keepChanged off: a changed file is replaced in place.
    public var keepDeleted = true
    public var keepChanged = true
    /// One _Archive per backup: <pastRoot>/<stamp>/<pastSubfolder>/<path>. nil: <destination>/_Archive.
    public var pastRoot: String?
    public var pastSubfolder: String?
    public var stamp: String?          // shared by every source of one backup run
    public init() {}
}

public struct Progress: Sendable {
    public enum Stage: Sendable { case looking, copying }
    public var stage: Stage = .looking
    public var filesDone = 0, filesTotal = 0
    public var bytesDone: Int64 = 0, bytesTotal: Int64 = 0
    public var current = ""
    public init() {}
}

public struct Report: Sendable {
    public var source: Drive
    public var destination: Drive
    public var lanes: Lanes
    public var copied = 0
    public var bytes: Int64 = 0
    public var retired = 0
    public var unchanged = 0
    public var problems: [String] = []
    public var seconds = 0.0
    public var pastFolder: String?
    public var stopped = false
    public var sourceBytes: Int64 = 0     // everything the source holds (after leaving out): "Last backup: date, size"
}

/// Names Archivist owns at the destination root. Never compared, never copied over.
public enum Names {
    public static let past = "_📚archive"        // earlier versions, at the destination's top
    /// Earlier names: never treated as the person's files; the app renames them to `past` before a backup.
    public static let legacyPasts = ["_Past", "_Archive"]
    public static let state = ".archivist"
    public static let tempPrefix = ".archivist-tmp-"
}

public final class Engine {
    let source: String
    let destination: String
    let options: Options
    private let lock = NSLock()
    private var progress = Progress()
    private var problems: [String] = []
    private var retired = 0
    private var copied = 0
    private var copiedBytes: Int64 = 0
    private var stamp = ""
    private var newPaths = Set<String>()
    private var deadRunStarted: Double?
    public var onProgress: ((Progress) -> Void)?
    private var stopped = false

    /// Stop after the files in flight: they finish and are renamed whole; nothing is left half-done.
    public func stop() { lock.lock(); stopped = true; lock.unlock() }
    var isStopped: Bool { lock.lock(); defer { lock.unlock() }; return stopped }

    public init(source: String, destination: String, options: Options = Options()) {
        // Absolute, always: a relative path has no "/" to stop the overlap walk at.
        self.source = URL(fileURLWithPath: source).standardizedFileURL.path
        self.destination = URL(fileURLWithPath: destination).standardizedFileURL.path
        self.options = options
    }

    // MARK: run

    public func run() throws -> Report {
        let start = Date()
        let src = try Drive.of(path: source, override: options.sourceKind)
        // A new destination folder is made, but only inside a folder that already exists.
        if !FileManager.default.fileExists(atPath: destination) && !options.dryRun {
            guard FileManager.default.fileExists(atPath: (destination as NSString).deletingLastPathComponent) else {
                throw ArchivistError.refused("The destination's parent folder doesn't exist: \((destination as NSString).deletingLastPathComponent)")
            }
            try makeDirs(destination)
        }
        let dst = try Drive.of(path: FileManager.default.fileExists(atPath: destination) ? destination
                               : (destination as NSString).deletingLastPathComponent, override: options.destinationKind)
        try refuseOverlap()
        let lanes = options.lanes ?? {
            var l = Lanes.choose(source: src.kind, destination: dst.kind)
            if let n = options.threads, n > 0 { l.small = n; l.big = max(1, min(n, 2)); l.together = n > 1 }
            return l
        }()

        let stateDir = destination + "/" + Names.state
        // A dry run reads both sides and writes nothing: no state folder, no lock, no cleanup.
        let lockFD: Int32 = options.dryRun ? -1 : try { try makeDirs(stateDir); return try takeRunLock(stateDir) }()
        defer { if lockFD >= 0 { releaseRunLock(lockFD, stateDir) } }

        // Scans. AppleDouble `._` twins on FAT-family drives belong to macOS, not the person.
        let fat: Set = ["exfat", "msdos"]
        // A source that is itself an Archivist backup keeps its own _Archive and .archivist: they
        // belong to that backup, so they are never copied (backing up a backup is normal; the
        // race found the old refusal copied nothing).
        var srcScanner = TreeScanner(excluded: options.excluded,
                                     skipRootNames: (source == src.mountPoint ? Drive.systemRootNames : []).union([Names.past, Names.state] + Names.legacyPasts))
        srcScanner.skipAppleDouble = fat.contains(src.fileSystem)
        srcScanner.patterns = options.patterns + Options.alwaysLeftOut
        // The destination skips exactly what the source skips (plus our own folders), so every
        // destination entry the source also has is compared, and a stray symlink is retired.
        var dstScanner = TreeScanner(skipRootNames: srcScanner.skipRootNames.union([Names.past, Names.state]))
        dstScanner.skipAppleDouble = fat.contains(dst.fileSystem)
        dstScanner.patterns = options.patterns + Options.alwaysLeftOut // left out = not managed: never retired to _Past either

        srcScanner.shouldStop = { [unowned self] in self.isStopped }
        dstScanner.shouldStop = srcScanner.shouldStop
        let (srcEntries, srcProblems) = try srcScanner.scan(source)
        var (dstEntries, dstProblems) = FileManager.default.fileExists(atPath: destination) ? try dstScanner.scan(destination) : ([], [])
        problems += srcProblems
        problems += dstProblems
        // Stopped while scanning: a half scan must never decide what is gone. Nothing was written.
        if isStopped {
            var r = Report(source: src, destination: dst, lanes: lanes)
            r.problems = problems; r.stopped = true; r.seconds = Date().timeIntervalSince(start)
            return r
        }
        problems += srcScanner.otherVolumes.map { "\($0): another drive mounted here; not copied" }
        // An empty source next to a full backup is almost always a drive that is not there
        // (an unmounted share, a disconnected disk), never a wish to archive everything.
        if srcEntries.isEmpty && !dstEntries.isEmpty {
            throw ArchivistError.refused("The source has no files; the backup was left alone.")
        }
        // Temp files from a run that died are Archivist's own and never complete: remove them.
        func isTemp(_ path: String) -> Bool {
            (path as NSString).lastPathComponent.range(of: "^\\" + Names.tempPrefix + "[0-9A-F]{8}$", options: .regularExpression) != nil
        }
        if !options.dryRun { for e in dstEntries where isTemp(e.path) { unlink(destination + "/" + e.path) } }
        var suspect = Set<String>()
        if let since = deadRunStarted {   // a run died mid-way: its files are suspect until copied again
            for e in dstEntries where e.kind == .file {
                var st = stat()
                if lstat(destination + "/" + e.path, &st) == 0 && Double(st.st_ctimespec.tv_sec) >= since { suspect.insert(e.path) }
            }
            dstEntries.removeAll { suspect.contains($0.path) }
        }
        dstEntries.removeAll { isTemp($0.path) }

        var changes = Compare.changes(source: srcEntries, destination: dstEntries,
                                      mtimeWindow: src.mtimeWindow(with: dst), unreadable: srcScanner.unreadable)
        // A destination folder that could not be read is left alone too: nothing copied into it,
        // nothing moved out of it.
        if !dstScanner.unreadable.isEmpty {
            func underUnreadable(_ p: String) -> Bool { dstScanner.unreadable.contains { p == $0 || p.hasPrefix($0 + "/") } }
            changes.copy.removeAll { underUnreadable($0.path) }
            changes.makeDirs.removeAll { underUnreadable($0.path) }
            changes.retire.removeAll { underUnreadable($0) }
        }
        var report = Report(source: src, destination: dst, lanes: lanes, unchanged: changes.unchanged)
        report.sourceBytes = srcEntries.reduce(0) { $0 + ($1.kind == .file ? $1.size : 0) }
        // Not enough room: say so before writing anything (a full disk once took 10 minutes of
        // failing file by file).
        var fs = statfs()
        if statfs(destination, &fs) == 0 {
            let free = Int64(fs.f_bavail) * Int64(fs.f_bsize)
            if changes.bytes > free && !src.canClone(to: dst) {
                throw ArchivistError.refused("Not enough space on \(dst.name): this backup needs \(ByteCountFormatter.string(fromByteCount: changes.bytes, countStyle: .file)), \(ByteCountFormatter.string(fromByteCount: free, countStyle: .file)) is free.")
            }
        }
        if options.dryRun {
            report.copied = changes.copy.count
            report.bytes = changes.bytes
            report.retired = changes.retire.count
            report.seconds = Date().timeIntervalSince(start)
            return report
        }

        stamp = options.stamp ?? Past.stampFormat.string(from: start)

        // 1. Retire what is gone or changed kind. 2. Folders. 3. Files. 4. Hard links. 5. Folder dates.
        let inSource = Set(srcEntries.map(\.path))
        for path in changes.retire { retire(path, gone: !inSource.contains(path)) }
        // Never write through something that is not a real folder (a symlink, a file): a refused
        // folder takes everything under it out of the run.
        // shortcut: paths are still joined as strings, so a symlink swapped in *after* this check could be followed; move to openat/mkdirat/renameat on an O_NOFOLLOW destination fd in stage 2c.
        var refused: [String] = []
        func underRefused(_ path: String) -> Bool { refused.contains { path == $0 || path.hasPrefix($0 + "/") } }
        for d in changes.makeDirs where !underRefused(d.path) {
            let p = destination + "/" + d.path
            allowWriting((p as NSString).deletingLastPathComponent)
            if mkdir(p, 0o700) != 0 {
                var st = stat()
                if errno == ENOSPC { note(ArchivistError.refused("The destination is full; stopped.")); stop(); break }
                if errno != EEXIST || lstat(p, &st) != 0 || st.st_mode & S_IFMT != S_IFDIR {
                    refused.append(d.path)
                    note(ArchivistError.refused("\(d.path): the destination has something other than a folder here; left alone"))
                }
            }
        }
        if !refused.isEmpty {
            changes.copy.removeAll { underRefused($0.path) }
            changes.dirs.removeAll { underRefused($0.path) }
        }

        // Folders this run writes into must be writable (a read-only source folder arrived
        // read-only); their real modes go back on in the metadata pass at the end.
        for dir in Set((changes.copy.map(\.path) + changes.retire).map { ($0 as NSString).deletingLastPathComponent }) {
            allowWriting(destination + "/" + dir)
        }
        newPaths = changes.new.subtracting(suspect)   // something is there: replace it via temp → rename, never in place
        progress.filesTotal = changes.copy.count
        progress.bytesTotal = changes.bytes
        progress.stage = .copying
        onProgress?(progress)
        let cloneOK = options.allowClone && src.canClone(to: dst)

        // Hard links: the first path of each inode is copied, the rest are linked to it after.
        var firstOfInode: [UInt64: String] = [:]
        var linkLater: [(Entry, String)] = []
        var jobs: [Entry] = []
        for e in changes.copy {
            if e.kind == .file && e.links > 1 {
                if let first = firstOfInode[e.inode] { linkLater.append((e, first)); continue }
                firstOfInode[e.inode] = e.path
            }
            jobs.append(e)
        }
        // Hard-link groups whose first member is unchanged still link to it.
        for e in srcEntries where e.kind == .file && e.links > 1 && firstOfInode[e.inode] == nil {
            firstOfInode[e.inode] = e.path
        }

        var small = jobs.filter { $0.size < options.bigFile }
        let big = jobs.filter { $0.size >= options.bigFile }
        if lanes.diskOrder { small = sortedByDiskOffset(small) }

        if lanes.together {
            let g = DispatchGroup()
            DispatchQueue.global().async(group: g) { self.runLane(small, width: lanes.small, cloneOK: cloneOK) }
            DispatchQueue.global().async(group: g) { self.runLane(big, width: lanes.big, cloneOK: cloneOK) }
            g.wait()
        } else {
            runLane(small, width: lanes.small, cloneOK: cloneOK)
            runLane(big, width: lanes.big, cloneOK: cloneOK)
        }

        if isStopped {   // stopped: finished files are already renamed whole; flush them and go
            fullSync(lockFD)
            report.copied = copied; report.bytes = copiedBytes; report.retired = retired
            report.problems = problems; report.seconds = Date().timeIntervalSince(start); report.stopped = true
            report.pastFolder = retired > 0 ? pastFolder : nil
            return report
        }
        for (e, first) in linkLater { link(e, to: firstOfInode[e.inode] ?? first) }

        // Folder dates and metadata last (writing files inside changed them), deepest first.
        for d in changes.dirs.reversed() {
            let s = source + "/" + d.path, t = destination + "/" + d.path
            if copyfile(s, t, nil, copyfile_flags_t(COPYFILE_METADATA | COPYFILE_NOFOLLOW)) != 0 {
                note(ArchivistError.io("copyfile metadata", t, errno))
            }
        }
        if options.finalFlush { fullSync(lockFD) } else { barrierSync(lockFD) }

        report.copied = copied
        report.bytes = copiedBytes
        report.retired = retired
        report.problems = problems
        report.seconds = Date().timeIntervalSince(start)
        report.stopped = isStopped
        report.pastFolder = retired > 0 ? pastFolder : nil
        return report
    }

    // MARK: lanes


    private func runLane(_ jobs: [Entry], width: Int, cloneOK: Bool) {
        guard !jobs.isEmpty else { return }
        var next = 0
        let nextLock = NSLock()
        DispatchQueue.concurrentPerform(iterations: max(1, min(width, jobs.count))) { _ in
            var batch = Batch()
            while true {
                nextLock.lock()
                let i = next
                next += 1
                nextLock.unlock()
                if i >= jobs.count || isStopped { break }
                copyToTemp(jobs[i], cloneOK: cloneOK, into: &batch)
                if batch.files.count >= 64 || batch.bytes >= 64 << 20 { commit(&batch) }
            }
            commit(&batch)
        }
    }

    /// Files copied to temp names, waiting for one drive flush and their renames.
    struct Batch {
        var files: [(entry: Entry, temp: String, fd: Int32, finish: Bool)] = []
        var bytes: Int64 = 0
    }

    /// Copy one file or symlink to a temp name beside its target. The source is only read.
    private func copyToTemp(_ e: Entry, cloneOK: Bool, into batch: inout Batch) {
        let s = source + "/" + e.path
        let target = destination + "/" + e.path
        let dir = (target as NSString).deletingLastPathComponent
        // ACLs and lock flags (uchg, "deny delete") go on after the rename: on the temp file
        // they would forbid the rename itself (round-trip test).
        var flags = COPYFILE_DATA | COPYFILE_XATTR | COPYFILE_STAT | COPYFILE_NOFOLLOW
        // Gap-keeping only where gaps can matter (disk images, VMs, databases are big); on small
        // files it is extra work per file for nothing.
        flags |= cloneOK ? COPYFILE_CLONE : (e.size >= 1 << 20 ? COPYFILE_DATA_SPARSE : 0)   // probe: CLONE's fallback drops holes

        var direct = options.directNew && newPaths.contains(e.path)
        for attempt in 1...4 {
            let temp = direct ? target : dir + "/" + Names.tempPrefix + UUID().uuidString.prefix(8)
            report(current: e.path)
            // A status callback lets Stop cut a file mid-copy (COPYFILE_QUIT); its temp is removed,
            // never renamed, so nothing half-copied is kept.
            let state = copyfile_state_alloc()
            defer { copyfile_state_free(state) }
            let me = Unmanaged.passUnretained(self).toOpaque()
            let cb: copyfile_callback_t = { _, _, _, _, _, ctx in
                guard let ctx else { return COPYFILE_CONTINUE }
                return Unmanaged<Engine>.fromOpaque(ctx).takeUnretainedValue().isStopped ? COPYFILE_QUIT : COPYFILE_CONTINUE
            }
            // Only on big files: a small one is done in a blink anyway (measured: the callback itself
            // costs little; the per-batch flush was the cost).
            if e.size >= options.callbackFrom {
                copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CB), unsafeBitCast(cb, to: UnsafeRawPointer.self))
                copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CTX), me)
            }
            // copyfile reads and writes in the destination's block size (4–8 KB on HFS+): a 64 KB
            // file took 8–16 trips through the kernel, 60% of the time per small file (sample).
            // One buffer of up to 1 MB: a small file goes in one read and one write.
            var bsize = UInt32(min(max(e.size, 4096), 1 << 20))
            copyfile_state_set(state, UInt32(COPYFILE_STATE_BSIZE), &bsize)
            // Straight to its own name only if nothing is there (EXCL): never over a file that appeared.
            if copyfile(s, temp, state, copyfile_flags_t(flags | (direct ? COPYFILE_EXCL : 0))) != 0 {
                let err = errno
                if direct && err == EEXIST { direct = false; continue }   // not ours: go the temp → rename way
                unlink(temp)
                if err == ENOSPC || err == EDQUOT {   // the destination filled up: stop, don't fail file after file
                    if !isStopped { note(ArchivistError.refused("The destination is full; stopped.")) }
                    stop()
                    return
                }
                if !isStopped { note(ArchivistError.io("copy", e.path, err)) }
                return
            }
            // The file must not have changed while it was read (rclone's rule).
            var after = stat()
            if lstat(s, &after) != 0 { note(ArchivistError.io("lstat", s, errno)); unlink(temp); return }
            let mtime = Double(after.st_mtimespec.tv_sec) + Double(after.st_mtimespec.tv_nsec) / 1e9
            if (e.kind == .file && after.st_size != e.size) || abs(mtime - e.mtime) > 0.000_001 {
                unlink(temp)
                if attempt == 4 { note(ArchivistError.changedDuringCopy(e.path)) }
                continue
            }
            // Lock flags off on the temp; restored after the rename with the ACL.
            let locked = after.st_flags & UInt32(UF_IMMUTABLE | UF_APPEND | SF_IMMUTABLE | SF_APPEND) != 0
            if locked { lchflags(temp, 0) }
            let hasACL = e.hasACL   // read by the scan: a separate check cost a head move per file on a spinning disk
            // Until its ACL is on, a file whose ACL limits access stays private to the owner.
            if hasACL { lchmod(temp, 0o600) }
            // One open file per batch carries the write barrier; opening every temp again cost a
            // step per file.
            let fd = e.kind == .symlink || batch.files.contains(where: { $0.fd >= 0 }) ? -1 : open(temp, O_RDONLY)
            // copyfile and clonefile drop setuid/setgid (clonefile(2), round-trip test): put them back.
            let special = after.st_mode & (S_ISUID | S_ISGID | S_ISVTX) != 0
            batch.files.append((e, temp, fd, locked || hasACL || special))
            batch.bytes += e.size
            // Progress moves per file copied, not per batch renamed (a batch is up to 64 files).
            lock.lock()
            progress.filesDone += 1
            progress.bytesDone += e.size
            let p = progress
            lock.unlock()
            onProgress?(p)
            return
        }
    }

    /// A write barrier puts every temp file's data ahead of the renames that follow, then each is
    /// renamed into place (the old version to _Archive first). A crash leaves temps, never a half
    /// file. The barrier keeps order without emptying the drive's cache: a full flush per batch
    /// made an SMR drive 2x slower than ditto (race 2). One full flush ends the run.
    private func commit(_ batch: inout Batch) {
        guard !batch.files.isEmpty else { return }
        if options.barrier, let fd = batch.files.first(where: { $0.fd >= 0 })?.fd, fcntl(fd, F_BARRIERFSYNC) != 0 { fsync(fd) }
        for f in batch.files {
            if f.fd >= 0 { close(f.fd) }
            let target = destination + "/" + f.entry.path
            var st = stat()
            if f.temp != target, lstat(target, &st) == 0 && options.keepChanged && !retire(f.entry.path, gone: false) {   // off: the rename replaces it
                unlink(f.temp)   // the old version could not be archived: it stays, this copy waits for the next run
                continue
            }
            if f.temp != target, rename(f.temp, target) != 0 {
                note(ArchivistError.io("rename", target, errno))
                unlink(f.temp)
                continue
            }
            if f.finish, copyfile(source + "/" + f.entry.path, target, nil,
                                  copyfile_flags_t(COPYFILE_ACL | COPYFILE_STAT | COPYFILE_NOFOLLOW)) != 0 {
                note(ArchivistError.io("copy ACL and flags", target, errno))
                lchmod(target, 0o600) // fail closed: never leave it wider than its ACL meant
            }
            if f.finish {
                var st = stat()
                if lstat(source + "/" + f.entry.path, &st) == 0, st.st_mode & (S_ISUID | S_ISGID | S_ISVTX) != 0,
                   lchmod(target, st.st_mode & 0o7777) != 0 {
                    note(ArchivistError.io("set special mode", target, errno))
                }
            }
            lock.lock()
            copied += 1
            copiedBytes += f.entry.size
            lock.unlock()
        }
        batch = Batch()
    }

    private func link(_ e: Entry, to first: String) {
        let target = destination + "/" + e.path
        let temp = (target as NSString).deletingLastPathComponent + "/" + Names.tempPrefix + UUID().uuidString.prefix(8)
        guard Darwin.link(destination + "/" + first, temp) == 0 else {
            // exFAT, FAT and some shares can't hard-link: a plain copy keeps the file at least.
            var b = Batch()
            copyToTemp(e, cloneOK: false, into: &b)
            commit(&b)
            return
        }
        var st = stat()
        if lstat(target, &st) == 0 && options.keepChanged && !retire(e.path, gone: false) { unlink(temp); return }
        if rename(temp, target) != 0 { note(ArchivistError.io("rename", target, errno)); unlink(temp); return }
        lock.lock(); copied += 1; progress.filesDone += 1; let p = progress; lock.unlock()
        onProgress?(p)
    }

    // MARK: _Archive (earlier versions)

    /// Where this run's earlier versions go.
    var pastFolder: String {
        (options.pastRoot ?? destination + "/" + Names.past) + "/" + stamp + (options.pastSubfolder.map { "/" + $0 } ?? "")
    }

    /// Move a destination path into the earlier versions (same path inside). When the person
    /// chose not to keep that kind (deleted / changed), remove it instead.
    /// False when the old version is still in place and must not be replaced.
    @discardableResult
    private func retire(_ path: String, gone: Bool) -> Bool {
        let from = destination + "/" + path
        if gone ? !options.keepDeleted : !options.keepChanged {
            do { try FileManager.default.removeItem(atPath: from) } catch {
                if (error as NSError).code != NSFileNoSuchFileError { note(error); return false }
            }
            return true
        }
        let to = pastFolder + "/" + path
        do { try makeDirs((to as NSString).deletingLastPathComponent) } catch { note(error); return false }
        // RENAME_EXCL: a same-named file already in this run's folder is never replaced.
        if renamex_np(from, to, UInt32(RENAME_EXCL)) != 0 {
            if errno == ENOENT { return true } // already moved with its parent
            if errno == EEXIST, renamex_np(from, to + "~" + UUID().uuidString.prefix(8), UInt32(RENAME_EXCL)) == 0 {
                lock.lock(); retired += 1; lock.unlock()
                return true
            }
            note(ArchivistError.io("move to \(Names.past)", from, errno))
            return false
        }
        lock.lock(); retired += 1; lock.unlock()
        return true
    }

    /// A folder copied from a read-only source arrives read-only too; the next run must still
    /// write inside it. Its real mode goes back on in the metadata pass at the end.
    private func allowWriting(_ dir: String) {
        var st = stat()
        if lstat(dir, &st) == 0, st.st_mode & S_IFMT == S_IFDIR, st.st_mode & S_IWUSR == 0 { chmod(dir, st.st_mode & 0o7777 | S_IWUSR) }
    }

    // MARK: helpers

    private func offset(_ e: Entry) -> Int64 {
        let fd = open(source + "/" + e.path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { return Int64.max }
        defer { close(fd) }
        var l2p = log2phys(l2p_flags: 0, l2p_contigbytes: 1, l2p_devoffset: 0)
        return fcntl(fd, F_LOG2PHYS_EXT, &l2p) == 0 ? l2p.l2p_devoffset : Int64.max
    }

    /// Disk order pays on a scattered, well-used disk (2.7-4x, measured) and costs an open per
    /// file; a disk filled in one go is already in folder order (race: sorting lost ~5 s). So
    /// sample the first 64 files: mostly ascending already means leave the order alone.
    private func sortedByDiskOffset(_ jobs: [Entry]) -> [Entry] {
        let sample = jobs.prefix(64).map(offset)
        if sample.count >= 8 {
            let ascending = zip(sample, sample.dropFirst()).filter { $0 <= $1 }.count
            if Double(ascending) / Double(sample.count - 1) >= 0.8 { return jobs }
        }
        return jobs.map { ($0, offset($0)) }
        .sorted { $0.1 < $1.1 }
        .map(\.0)
    }

    /// Compared by device and inode, so case, firmlinks and symlinks can't hide one inside the other.
    private func refuseOverlap() throws {
        func id(_ p: String) -> (UInt32, UInt64)? { var st = stat(); return stat(p, &st) == 0 ? (UInt32(st.st_dev), st.st_ino) : nil }
        func ancestors(_ p: String) -> [String] {
            var out: [String] = [], cur = (p as NSString).standardizingPath
            while true {
                out.append(cur)
                let up = (cur as NSString).deletingLastPathComponent
                if cur == "/" || up == cur || up.isEmpty { break }
                cur = up
            }
            return out
        }
        func inside(_ a: String, _ b: String) -> Bool {   // a is b or lies under b
            guard let bid = id(b) else { return false }
            return ancestors(a).contains { id($0).map { $0 == bid } ?? false }
        }
        let dstOrParent = FileManager.default.fileExists(atPath: destination) ? destination : (destination as NSString).deletingLastPathComponent
        if inside(dstOrParent, source) || inside(source, dstOrParent) {
            throw ArchivistError.refused("The destination can't be inside the source, or the source inside the destination.")
        }
        if let past = options.pastRoot, inside(past, source) {
            throw ArchivistError.refused("The earlier-versions folder can't be inside the source.")
        }
    }

    private func takeRunLock(_ stateDir: String) throws -> Int32 {
        let path = stateDir + "/run.lock"
        for _ in 0..<2 {
            let fd = open(path, O_CREAT | O_EXCL | O_RDWR, 0o644)
            if fd >= 0 {
                let pid = "\(getpid())\n"
                _ = pid.withCString { write(fd, $0, strlen($0)) }
                return fd
            }
            // A lock left by a run that died: take it over. A live run: refuse.
            if let text = try? String(contentsOfFile: path, encoding: .utf8),
               let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)),
               kill(pid, 0) == 0 || errno == EPERM {
                throw ArchivistError.refused("Another Archivist run (pid \(pid)) is copying to this destination.")
            }
            // The dead run started when its lock was made: whatever it wrote since then may not
            // have reached the platter (no flush per file), so this run copies it again.
            var st = stat()
            if lstat(path, &st) == 0 { deadRunStarted = Double(st.st_birthtimespec.tv_sec) - 2 }
            unlink(path)
        }
        throw ArchivistError.io("lock", path, errno)
    }

    private func releaseRunLock(_ fd: Int32, _ stateDir: String) {
        close(fd)
        unlink(stateDir + "/run.lock")
    }

    private func barrierSync(_ fd: Int32) {
        if fcntl(fd, F_BARRIERFSYNC) != 0 { fsync(fd) }
    }

    private func fullSync(_ fd: Int32) {
        if fcntl(fd, F_FULLFSYNC) != 0 { fsync(fd) } // some USB bridges refuse the full flush
    }

    private func makeDirs(_ path: String) throws {
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    }

    private func note(_ error: Error) {
        lock.lock(); problems.append("\(error)"); lock.unlock()
    }

    private func report(current: String) {
        guard onProgress != nil else { return }
        lock.lock(); progress.current = current; lock.unlock()
    }
}

/// What a run would do, without doing it: for the window's source rows.
public struct Survey: Sendable {
    public init() {}
    public var files = 0
    public var bytes: Int64 = 0            // everything in the source (after leaving out)
    public var toCopy = 0
    public var bytesToCopy: Int64 = 0
    public var destinationExists = false
    public var compared = true             // false: only the source's size is known so far

    /// Just the source's size: a local scan, quick, so the window can size things before the
    /// (possibly slow) comparison with the destination finishes.
    public static func size(of source: String, excluded: Set<String> = [], patterns: [String] = []) throws -> Survey {
        var s = Survey()
        var src = TreeScanner(excluded: excluded)
        src.patterns = patterns + Options.alwaysLeftOut
        for e in try src.scan(source).entries where e.kind == .file { s.files += 1; s.bytes += e.size }
        s.compared = false
        return s
    }

    public static func of(source: String, destination: String, excluded: Set<String> = [], patterns: [String] = []) throws -> Survey {
        var s = Survey()
        var src = TreeScanner(excluded: excluded)
        src.patterns = patterns + Options.alwaysLeftOut
        let (entries, _) = try src.scan(source)
        for e in entries where e.kind == .file { s.files += 1; s.bytes += e.size }
        s.destinationExists = FileManager.default.fileExists(atPath: destination)
        guard s.destinationExists else { s.toCopy = entries.filter { $0.kind != .directory }.count; s.bytesToCopy = s.bytes; return s }
        var dst = TreeScanner(skipRootNames: Set([Names.past, Names.state] + Names.legacyPasts))
        dst.patterns = patterns + Options.alwaysLeftOut
        let (dEntries, _) = try dst.scan(destination)
        let window = (try? Drive.of(path: source).mtimeWindow(with: Drive.of(path: destination))) ?? 1
        let c = Compare.changes(source: entries, destination: dEntries, mtimeWindow: window)
        s.toCopy = c.copy.count
        s.bytesToCopy = c.bytes
        return s
    }
}
