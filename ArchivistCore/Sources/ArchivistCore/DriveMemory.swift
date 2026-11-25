import Foundation

/// What one destination drive has done in past backups, so a time estimate can be right from the
/// first minute: seconds per small file, seconds per big megabyte, and the fixed costs around the
/// copy (looking for changes, finishing: folder dates and the final flush). Recent runs count most.
/// Kept per drive by its volume UUID, at most `limit` runs (bounded where it is written).
public struct DriveMemory: Codable, Sendable, Equatable {
    public struct Run: Codable, Sendable, Equatable {
        public var date: Date
        public var smallFiles: Int          // small files copied
        public var bigMB: Double            // megabytes of big files copied
        public var looking: Double          // seconds before the first file
        public var small: Double            // seconds spent on small files
        public var big: Double              // seconds spent on big files
        public var finishing: Double        // seconds after the last file
        public init(date: Date = Date(), smallFiles: Int, bigMB: Double, looking: Double, small: Double, big: Double, finishing: Double) {
            self.date = date; self.smallFiles = smallFiles; self.bigMB = bigMB
            self.looking = looking; self.small = small; self.big = big; self.finishing = finishing
        }
    }

    public static let limit = 20
    public var name: String
    public var runs: [Run] = []

    public init(name: String) { self.name = name }

    public mutating func add(_ run: Run) {
        runs.append(run)
        if runs.count > Self.limit { runs.removeFirst(runs.count - Self.limit) }
    }

    /// Weighted by recency: the newest run counts 1, each older one half as much as the next.
    private func weighted(_ value: (Run) -> Double?) -> Double? {
        var sum = 0.0, weight = 0.0, w = 1.0
        for r in runs.reversed() {
            if let v = value(r), v.isFinite, v > 0 { sum += v * w; weight += w }
            w *= 0.5
        }
        return weight > 0 ? sum / weight : nil
    }

    /// Only runs with enough of that kind of work to mean something.
    public var secondsPerSmallFile: Double? { weighted { $0.smallFiles >= 200 ? $0.small / Double($0.smallFiles) : nil } }
    public var secondsPerMB: Double? { weighted { $0.bigMB >= 100 ? $0.big / $0.bigMB : nil } }
    /// Looking and finishing grow with how much there is: priced per file copied.
    public var lookingPerFile: Double? { weighted { r in let n = r.smallFiles + max(1, Int(r.bigMB / 50)); return n >= 200 ? r.looking / Double(n) : nil } }
    public var finishingPerFile: Double? { weighted { r in let n = r.smallFiles + max(1, Int(r.bigMB / 50)); return n >= 200 ? r.finishing / Double(n) : nil } }

    /// The whole run, from what is planned.
    public func estimate(smallFiles: Int, bigMB: Double, defaults: (small: Double, mb: Double)) -> Double {
        let n = Double(smallFiles + max(1, Int(bigMB / 50)))
        return Double(smallFiles) * (secondsPerSmallFile ?? defaults.small)
             + bigMB * (secondsPerMB ?? defaults.mb)
             + n * ((lookingPerFile ?? 0) + (finishingPerFile ?? 0))
    }
}
