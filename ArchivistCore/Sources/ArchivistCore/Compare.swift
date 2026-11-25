import Foundation

/// What a run must do, from a source scan and a destination scan.
public struct Changes: Sendable {
    public var copy: [Entry] = []            // new or changed files and symlinks (source entries)
    public var makeDirs: [Entry] = []        // folders missing at the destination
    public var retire: [String] = []         // destination paths to move into _Archive (gone or replaced by another kind)
    public var unchanged = 0
    public var new = Set<String>()           // copies with nothing at the destination yet
    public var dirs: [Entry] = []            // every source folder (its dates are set at the end)

    public var bytes: Int64 { copy.reduce(0) { $0 + $1.size } }
}

public enum Compare {
    /// Size + modification date, with the drives' timestamp slack (rsync's quick check;
    /// a whole-file fingerprint is a separate, optional check).
    public static func changes(source: [Entry], destination: [Entry], mtimeWindow: Double, unreadable: [String] = []) -> Changes {
        var dest: [String: Entry] = [:]
        dest.reserveCapacity(destination.count)
        for e in destination { dest[e.path] = e }

        var c = Changes()
        var seen = Set<String>()
        seen.reserveCapacity(source.count)
        for s in source {
            seen.insert(s.path)
            let d = dest[s.path]
            switch s.kind {
            case .directory:
                c.dirs.append(s)
                if let d, d.kind == .directory { continue }
                if d != nil { c.retire.append(s.path) }
                c.makeDirs.append(s)
            case .file, .symlink:
                if let d, d.kind == s.kind, d.size == s.size, abs(d.mtime - s.mtime) <= mtimeWindow {
                    c.unchanged += 1
                    continue
                }
                if let d, d.kind != s.kind { c.retire.append(s.path) }
                if d == nil { c.new.insert(s.path) }
                c.copy.append(s)
            case .other:
                continue // sockets, FIFOs, devices: never copied
            }
        }
        // Gone from the source: retire only the top-most path of a gone subtree.
        for d in destination where !seen.contains(d.path) {
            // A folder the scan could not read: its backup stays until it can be read again.
            if unreadable.contains(where: { d.path == $0 || d.path.hasPrefix($0 + "/") }) { continue }
            let parent = (d.path as NSString).deletingLastPathComponent
            if !parent.isEmpty && !seen.contains(parent) { continue }
            c.retire.append(d.path)
        }
        return c
    }
}
