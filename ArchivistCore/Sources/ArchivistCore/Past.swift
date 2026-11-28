import Foundation

/// Earlier versions: what a backup moved aside (`_Archive/<yyyy-MM-dd HHmmss>/<source>/<path>`),
/// listed by date and pruned by age and by free space. The newest is never removed.
public enum Past {
    public struct Version: Sendable, Identifiable {
        public var id: String { path }
        public let date: Date
        public let path: String
        public let files: Int
        public let bytes: Int64
        public var changed = 0     // an older copy of a file the backup still has
        public var deleted = 0     // a file no longer in the backup
    }

    static let stampFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HHmmss"
        return f
    }()

    /// The dated version folders directly under `root`: Archivist's own, whatever the root is
    /// called (an earlier release called it _Past or _Archive).
    public static func versionNames(in root: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []).filter { stampFormat.date(from: $0) != nil }
    }

    /// Every dated folder under `root`, newest first, with its file count and size.
    /// `backup`: the folder holding the current copies (the destination). A file in a version
    /// that the backup still has is an earlier version of it; one it lacks was deleted.
    public static func list(_ root: String, backup: String? = nil) -> [Version] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: root) else { return [] }
        return names.compactMap { name -> Version? in
            guard let date = stampFormat.date(from: name) else { return nil }
            let path = root + "/" + name
            var files = 0, changed = 0, deleted = 0
            var bytes: Int64 = 0
            if let walk = FileManager.default.enumerator(at: URL(fileURLWithPath: path), includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) {
                for case let u as URL in walk where u.lastPathComponent != ".DS_Store" {
                    let v = try? u.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                    guard v?.isRegularFile == true else { continue }
                    files += 1; bytes += Int64(v?.fileSize ?? 0)
                    if let backup {
                        let rel = String(u.path.dropFirst(path.count))
                        if FileManager.default.fileExists(atPath: backup + rel) { changed += 1 } else { deleted += 1 }
                    }
                }
            }
            var version = Version(date: date, path: path, files: files, bytes: bytes)
            version.changed = changed; version.deleted = deleted
            return version
        }
        .sorted { $0.date > $1.date }
    }

    /// Removes dated folders older than `keepDays` (nil = keep by age forever), then the oldest
    /// while the drive has less than `minFree` bytes free. The newest is never removed.
    /// Returns what was removed.
    @discardableResult
    public static func prune(_ root: String, keepDays: Int?, minFree: Int64, now: Date = Date(),
                             freeSpace: (String) -> Int64 = Past.free) -> [String] {
        let dated = (try? FileManager.default.contentsOfDirectory(atPath: root))?
            .compactMap { n in stampFormat.date(from: n).map { (n, $0) } }
            .sorted { $0.1 < $1.1 } ?? []
        guard dated.count > 1 else { return [] }
        var candidates = Array(dated.dropLast())   // never the newest
        var removed: [String] = []
        func drop(_ name: String) {
            if (try? FileManager.default.removeItem(atPath: root + "/" + name)) != nil { removed.append(name) }
        }
        if let days = keepDays {
            let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
            for c in candidates where c.1 < cutoff { drop(c.0) }
            candidates.removeAll { $0.1 < cutoff }
        }
        while freeSpace(root) < minFree, let oldest = candidates.first {
            drop(oldest.0)
            candidates.removeFirst()
        }
        return removed
    }

    public static func free(_ path: String) -> Int64 {
        var fs = statfs()
        return statfs(path, &fs) == 0 ? Int64(fs.f_bavail) * Int64(fs.f_bsize) : .max
    }

    /// Room kept free by the space guard: 5% of the drive, between 2 GB and 50 GB.
    public static func guardSpace(_ path: String) -> Int64 {
        var fs = statfs()
        guard statfs(path, &fs) == 0 else { return 0 }
        let total = Int64(fs.f_blocks) * Int64(fs.f_bsize)
        return min(max(total / 20, 2 << 30), 50 << 30)
    }
}
