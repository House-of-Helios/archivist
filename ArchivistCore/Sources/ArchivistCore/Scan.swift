import Darwin
import Foundation

public enum EntryKind: UInt8, Sendable { case file, directory, symlink, other }

/// One thing found by a scan. `path` is relative to the scan root, "/"-separated.
public struct Entry: Sendable, Equatable {
    public var path: String
    public var kind: EntryKind
    public var size: Int64
    public var mtime: Double       // seconds since 1970, with nanoseconds
    public var inode: UInt64
    public var links: UInt32
    public var hasACL = false      // from the scan itself: no extra look per file later
}

/// Scans a folder tree with getattrlistbulk(2): one call returns many entries with
/// their attributes, the fast path on APFS, HFS+, exFAT and SMB (measured on each).
public struct TreeScanner {
    public var excluded: Set<String>          // relative paths, skipped with everything under them
    public var skipRootNames: Set<String>     // names skipped only at the root
    public var skipAppleDouble = false        // `._name` twins on FAT-family drives belong to macOS
    /// Names left out anywhere in the tree, fnmatch style (`*.tmp`, `node_modules`). `name@marker`
    /// leaves out a folder only when `marker` sits beside it: `target@Cargo.toml` is Rust's build
    /// output, while a folder named `target` anywhere else is someone's work.
    public var patterns: [String] = []
    /// Folders that are another drive mounted inside this tree: never entered (a whole-drive
    /// backup must not wander into other volumes; inode numbers are only unique per volume).
    public private(set) var otherVolumes: [String] = []
    /// Folders that could not be listed: what is under them is unknown, not gone.
    public private(set) var unreadable: [String] = []
    /// Asked between folders: true ends the scan early (Stop must not wait out a million-file walk).
    public var shouldStop: (() -> Bool)?
    /// Files found so far, after each level of the tree: a long walk shows it is moving.
    public var onCount: ((Int) -> Void)?

    public init(excluded: Set<String> = [], skipRootNames: Set<String> = []) {
        self.excluded = excluded
        self.skipRootNames = skipRootNames
    }

    /// Folders listed at once. nil: 16 on a network drive (each listing waits a round trip;
    /// 16 in flight read 11x faster over SMB, THESIS §6), 1 on a local one (a spinning disk
    /// must not seek between folders).
    public var width: Int?
    /// Whether each entry's ACL was read by the scan. Not on a network drive: there it cost an
    /// extra trip per entry (132 vs 643 entries/s over SMB/WiFi, 1 folder at a time); callers
    /// look it up per file with `hasACL(_:)`, only for the files they copy.
    public private(set) var askedACL = true

    /// Every entry under `root`, parents before children, sorted by path within a folder.
    /// Unreadable folders are reported in `problems`, never silently skipped.
    public mutating func scan(_ root: String) throws -> (entries: [Entry], problems: [String]) {
        var rootStat = stat()
        guard lstat(root, &rootStat) == 0 else { throw ArchivistError.io("lstat", root, errno) }
        let network = TreeScanner.isNetwork(root)
        let width = self.width ?? (network ? 16 : 1)
        askedACL = !network
        let me = self, rootDev = rootStat.st_dev
        var problems: [String] = []
        // Level by level, each level's folders listed `width` at a time ...
        var listings: [String: Listing] = [:]
        var level = [""]
        var found = 0
        // Stop and the running count are checked per folder, not per level: one level of a big
        // tree over WiFi held thousands of folders and took minutes, so the window showed no
        // number and Stop seemed hung until the level ended (the Mini, 2026-11-28).
        let tally = NSLock()
        var running = 0, lastShown = Date.distantPast
        let stop = shouldStop, count = onCount
        while !level.isEmpty {
            if stop?() == true { break }
            let results = TreeScanner.map(level, width: width) { rel -> Listing in
                if stop?() == true { return Listing(stopped: true) }
                let l = me.listOne(rel, root: root, rootDev: rootDev)
                let files = l.entries.reduce(0) { $0 + ($1.kind == .file ? 1 : 0) }
                tally.lock()
                running += files
                let show = Date().timeIntervalSince(lastShown) > 0.5 ? running : nil
                if show != nil { lastShown = Date() }
                tally.unlock()
                if let show { count?(show) }
                return l
            }
            if stop?() == true || results.contains(where: \.stopped) { break }   // a half level is no tree
            var next: [String] = []
            for (rel, l) in zip(level, results) {
                if let error = l.error {
                    if rel.isEmpty { throw error }
                    problems.append("\(error)")
                    unreadable.append(rel)
                    continue
                }
                otherVolumes += l.otherVolumes
                next += l.dirs
                found += l.entries.reduce(0) { $0 + ($1.kind == .file ? 1 : 0) }
                listings[rel] = l
            }
            onCount?(found)
            level = next
        }
        // ... then laid out depth first, the order callers have always had.
        var out: [Entry] = []
        var stack = [""]
        while let rel = stack.popLast() {
            guard let l = listings.removeValue(forKey: rel) else { continue }
            out += l.entries
            stack.append(contentsOf: l.dirs.reversed())
        }
        return (out, problems)
    }

    struct Listing { var entries: [Entry] = []; var dirs: [String] = []; var otherVolumes: [String] = []; var error: Error?; var stopped = false }

    /// One folder's kept entries and subfolders, after the leaving-out rules.
    func listOne(_ rel: String, root: String, rootDev: dev_t) -> Listing {
        let abs = rel.isEmpty ? root : root + "/" + rel
        var l = Listing()
        let children: [Entry]
        do { children = try TreeScanner.list(abs, relative: rel, acl: askedACL) } catch { l.error = error; return l }
        for e in children.sorted(by: { $0.path < $1.path }) {
            let name = (e.path as NSString).lastPathComponent
            if rel.isEmpty && skipRootNames.contains(name) { continue }
            if skipAppleDouble && name.hasPrefix("._") { continue }
            if patterns.contains(where: { p in
                guard let at = p.firstIndex(of: "@") else { return fnmatch(p, name, 0) == 0 }
                return e.kind == .directory && fnmatch(String(p[..<at]), name, 0) == 0
                    && access(abs + "/" + p[p.index(after: at)...], F_OK) == 0
            }) { continue }
            if excluded.contains(e.path) { continue }
            if e.kind == .directory {
                var st = stat()
                if lstat(root + "/" + e.path, &st) == 0, st.st_dev != rootDev {
                    l.otherVolumes.append(e.path)
                    continue
                }
                l.dirs.append(e.path)
            }
            l.entries.append(e)
        }
        return l
    }

    /// `f` over `items`, `width` at a time, results in order.
    static func map<T>(_ items: [String], width: Int, _ f: @escaping (String) -> T) -> [T] {
        guard width > 1, items.count > 1 else { return items.map(f) }
        var out = [T?](repeating: nil, count: items.count)
        let lock = NSLock()
        var next = 0
        out.withUnsafeMutableBufferPointer { b in
            let buf = b   // each slot written by exactly one worker, all done before this returns
            onThreads(min(width, items.count)) {
                while true {
                    lock.lock(); let i = next; next += 1; lock.unlock()
                    guard i < items.count else { return }
                    buf[i] = f(items[i])
                }
            }
        }
        return out.map { $0! }
    }

    /// `body` on `count` threads of their own, at the caller's QoS; returns when all are done.
    /// Not GCD's pool: it holds back at about the core count, and these threads mostly wait.
    public static func onThreads(_ count: Int, _ body: @escaping () -> Void) {
        let group = DispatchGroup()
        let qos = qos_class_self()
        for _ in 0..<count {
            group.enter()
            let t = Thread {
                pthread_set_qos_class_self_np(qos, 0)
                body()
                group.leave()
            }
            t.start()
        }
        group.wait()
    }

    /// Does this one item (not followed if a link) carry an ACL?
    public static func hasACL(_ path: String) -> Bool {
        var al = attrlist()
        al.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        al.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS) | attrgroup_t(ATTR_CMN_EXTENDED_SECURITY)
        var buf = [UInt8](repeating: 0, count: 4096)
        return buf.withUnsafeMutableBytes { b -> Bool in
            // Unanswered (a network error, an ACL too big for the buffer): taken as "has one", so the
            // copy re-applies the ACL from the source rather than leaving the file open to all.
            guard getattrlist(path, &al, b.baseAddress!, b.count, UInt32(FSOPT_NOFOLLOW)) == 0 else { return errno != ENOENT }
            let returned = b.loadUnaligned(fromByteOffset: 4, as: attribute_set_t.self)
            guard returned.commonattr & attrgroup_t(ATTR_CMN_EXTENDED_SECURITY) != 0 else { return false }
            return b.loadUnaligned(fromByteOffset: 4 + MemoryLayout<attribute_set_t>.size, as: attrreference_t.self).attr_length > 0
        }
    }

    /// A drive reached over a network (SMB, NFS, AFP, WebDAV): not marked local by the kernel.
    static func isNetwork(_ path: String) -> Bool {
        var s = statfs()
        return statfs(path, &s) == 0 && s.f_flags & UInt32(MNT_LOCAL) == 0
    }

    /// One folder's entries via getattrlistbulk.
    static func list(_ dir: String, relative rel: String, acl: Bool = true) throws -> [Entry] {
        let fd = open(dir, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard fd >= 0 else { throw ArchivistError.io("open", dir, errno) }
        defer { close(fd) }

        var al = attrlist()
        al.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        al.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS) | attrgroup_t(ATTR_CMN_NAME)
            | attrgroup_t(ATTR_CMN_OBJTYPE) | attrgroup_t(ATTR_CMN_MODTIME) | (acl ? attrgroup_t(ATTR_CMN_EXTENDED_SECURITY) : 0)
            | attrgroup_t(ATTR_CMN_FILEID)
        al.fileattr = attrgroup_t(ATTR_FILE_LINKCOUNT) | attrgroup_t(ATTR_FILE_DATALENGTH)

        var out: [Entry] = []
        let bufSize = 256 * 1024
        let buf = UnsafeMutableRawPointer.allocate(byteCount: bufSize, alignment: 8)
        defer { buf.deallocate() }
        while true {
            let n = getattrlistbulk(fd, &al, buf, bufSize, 0)
            if n < 0 { throw ArchivistError.io("getattrlistbulk", dir, errno) }
            if n == 0 { break }
            var entry = buf
            for _ in 0..<n {
                let length = Int(entry.loadUnaligned(as: UInt32.self))
                var p = entry + 4
                let returned = p.loadUnaligned(as: attribute_set_t.self)
                p += MemoryLayout<attribute_set_t>.size

                var name = ""
                if returned.commonattr & attrgroup_t(ATTR_CMN_NAME) != 0 {
                    let ref = p.loadUnaligned(as: attrreference_t.self)
                    name = String(cString: (p + Int(ref.attr_dataoffset)).assumingMemoryBound(to: CChar.self))
                    p += MemoryLayout<attrreference_t>.size
                }
                var objType: UInt32 = 0
                if returned.commonattr & attrgroup_t(ATTR_CMN_OBJTYPE) != 0 {
                    objType = p.loadUnaligned(as: UInt32.self)
                    p += 4
                }
                var mtime = 0.0
                if returned.commonattr & attrgroup_t(ATTR_CMN_MODTIME) != 0 {
                    let ts = p.loadUnaligned(as: timespec.self)
                    mtime = Double(ts.tv_sec) + Double(ts.tv_nsec) / 1e9
                    p += MemoryLayout<timespec>.size
                }
                // Returned only when the object has an ACL; attributes come in bit order.
                var hasACL = false
                if returned.commonattr & attrgroup_t(ATTR_CMN_EXTENDED_SECURITY) != 0 {
                    hasACL = p.loadUnaligned(as: attrreference_t.self).attr_length > 0
                    p += MemoryLayout<attrreference_t>.size
                }
                var inode: UInt64 = 0
                if returned.commonattr & attrgroup_t(ATTR_CMN_FILEID) != 0 {
                    inode = p.loadUnaligned(as: UInt64.self)
                    p += 8
                }
                var links: UInt32 = 1
                if returned.fileattr & attrgroup_t(ATTR_FILE_LINKCOUNT) != 0 {
                    links = p.loadUnaligned(as: UInt32.self)
                    p += 4
                }
                var size: Int64 = 0
                if returned.fileattr & attrgroup_t(ATTR_FILE_DATALENGTH) != 0 {
                    size = p.loadUnaligned(as: Int64.self)
                    p += 8
                }
                let kind: EntryKind
                switch Int(objType) {
                case Int(VREG.rawValue): kind = .file
                case Int(VDIR.rawValue): kind = .directory
                case Int(VLNK.rawValue): kind = .symlink
                default: kind = .other
                }
                if kind != .file { size = 0 }
                out.append(Entry(path: rel.isEmpty ? name : rel + "/" + name, kind: kind,
                                 size: size, mtime: mtime, inode: inode, links: links, hasACL: hasACL))
                entry += length
            }
        }
        return out
    }
}
