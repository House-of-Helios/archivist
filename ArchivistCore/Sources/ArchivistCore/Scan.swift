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
    public var patterns: [String] = []        // names left out anywhere in the tree, fnmatch style (`*.tmp`, `node_modules`)
    /// Folders that are another drive mounted inside this tree: never entered (a whole-drive
    /// backup must not wander into other volumes; inode numbers are only unique per volume).
    public private(set) var otherVolumes: [String] = []
    /// Folders that could not be listed: what is under them is unknown, not gone.
    public private(set) var unreadable: [String] = []

    public init(excluded: Set<String> = [], skipRootNames: Set<String> = []) {
        self.excluded = excluded
        self.skipRootNames = skipRootNames
    }

    /// Every entry under `root`, parents before children, sorted by path within a folder.
    /// Unreadable folders are reported in `problems`, never silently skipped.
    public mutating func scan(_ root: String) throws -> (entries: [Entry], problems: [String]) {
        var rootStat = stat()
        guard lstat(root, &rootStat) == 0 else { throw ArchivistError.io("lstat", root, errno) }
        var out: [Entry] = []
        var problems: [String] = []
        var stack: [String] = [""]
        while let rel = stack.popLast() {
            let abs = rel.isEmpty ? root : root + "/" + rel
            let children: [Entry]
            do {
                children = try TreeScanner.list(abs, relative: rel)
            } catch {
                if rel.isEmpty { throw error }
                problems.append("\(error)")
                unreadable.append(rel)
                continue
            }
            var dirs: [String] = []
            for e in children.sorted(by: { $0.path < $1.path }) {
                let name = (e.path as NSString).lastPathComponent
                if rel.isEmpty && skipRootNames.contains(name) { continue }
                if skipAppleDouble && name.hasPrefix("._") { continue }
                if patterns.contains(where: { fnmatch($0, name, 0) == 0 }) { continue }
                if excluded.contains(e.path) { continue }
                if e.kind == .directory {
                    var st = stat()
                    if lstat(root + "/" + e.path, &st) == 0, st.st_dev != rootStat.st_dev {
                        otherVolumes.append(e.path)
                        continue
                    }
                    dirs.append(e.path)
                }
                out.append(e)
            }
            stack.append(contentsOf: dirs.reversed())
        }
        return (out, problems)
    }

    /// One folder's entries via getattrlistbulk.
    static func list(_ dir: String, relative rel: String) throws -> [Entry] {
        let fd = open(dir, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard fd >= 0 else { throw ArchivistError.io("open", dir, errno) }
        defer { close(fd) }

        var al = attrlist()
        al.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        al.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS) | attrgroup_t(ATTR_CMN_NAME)
            | attrgroup_t(ATTR_CMN_OBJTYPE) | attrgroup_t(ATTR_CMN_MODTIME) | attrgroup_t(ATTR_CMN_EXTENDED_SECURITY)
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
