import Foundation
import Observation
import ArchivistCore

/// One update pipeline for the whole app: the pill in the title strip goes
/// through it. Updates come from GitHub Releases only (`ReleaseFeed`). As soon as a newer build is
/// seen it is downloaded, checked and staged in the background (`prepare`), the way
/// Sparkle downloads ahead; Install then only swaps and restarts, waiting on the fetch if
/// it is still running, with the ring round the Archivist pill showing it is under way.
@MainActor @Observable
final class Updater {
    static let shared = Updater()

    /// 0 while a version is being fetched, 1 once it is staged.
    private(set) var progress: Double = 0
    /// The version being fetched or ready, if any.
    private(set) var preparing: String?
    private(set) var ready: String?
    /// Install was pressed: finish as soon as the fetch is done. Drives the ring.
    private(set) var installing: UpdateInfo?
    /// Why the last try stopped, for whoever asked.
    private(set) var problem: String?

    /// The newest version asked for, so a build published mid-fetch is fetched next.
    private var latest: UpdateInfo?

    /// A Debug build is never offered an update (ARCHIVIST_UPDATE_TEST=1 lets one try the road).
    static var isDev: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.environment["ARCHIVIST_UPDATE_TEST"] == nil
        #else
        return false
        #endif
    }

    /// Ask the latest GitHub release whether it is newer than `current`.
    static func check(current: String) async -> UpdateChecker.Status {
        if isDev { return .upToDate(current: current, published: nil) }
        return await ReleaseFeed().check(current: current)
    }

    /// Download, check and stage `u` ahead, quietly. A no-op when it is already done or on its way.
    func prepare(_ u: UpdateInfo) {
        guard !Self.isDev else { return }
        latest = u
        if ready == u.version || preparing == u.version { return }
        guard preparing == nil else { return }   // the running fetch re-checks when done
        preparing = u.version
        ready = nil
        progress = 0
        Task {
            var why: String?
            do {
                let dir = try await ReleaseFeed().fetch(u, into: JobStore.dataDirectory.appendingPathComponent("updates", isDirectory: true))
                why = await AppInstaller.stage(from: dir.appendingPathComponent("Archivist.app"))
            } catch { why = "\(error)" }
            preparing = nil
            if let why {
                problem = why
                if installing != nil { installing = nil }
                DevLog.write("update: \(why)")
                return
            }
            ready = u.version
            progress = 1
            if let l = latest, l.version != u.version { prepare(l) }   // published meanwhile
            else if installing != nil { finish() }   // the newest, even if Install named an older one
        }
    }

    /// Install `u`: fetch it if that hasn't happened, then swap and restart.
    func install(_ u: UpdateInfo) {
        guard !Self.isDev else { return }
        problem = nil
        installing = u
        if ready == u.version { finish() } else { prepare(u) }
    }

    private func finish() {
        // A beat at full so the ring is seen to close before the window goes.
        Task {
            try? await Task.sleep(nanoseconds: 350_000_000)
            if let why = AppInstaller.finish() {
                installing = nil
                ready = nil
                problem = why
                DevLog.write("update: \(why)")
            }
        }
    }

}
