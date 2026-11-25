import ArchivistCore
import Foundation
import UserNotifications
import ServiceManagement

/// Scheduled backups with the window closed. macOS starts this same app with `--scheduled`
/// (launchd agent `Contents/Library/LaunchAgents/com.houseofhelios.archivist.scheduler.plist`,
/// registered through SMAppService): every 5 minutes and whenever a drive mounts. It runs
/// whatever is due, writes the results into the shared jobs file, and exits. No window.
enum Scheduler {
    static let plist = "com.houseofhelios.archivist.scheduler.plist"
    static var agent: SMAppService { SMAppService.agent(plistName: plist) }

    /// The launchd agent is retired: macOS kills an SMAppService agent of an app signed without
    /// an Apple team ID at every start ("Launch Constraint Violation", even right after the same
    /// build registered it), and each kill shows "Archivist quit unexpectedly". Any registration
    /// an older build left is removed; schedules run while Archivist is open (`runDueInApp`).
    static func sync(_ jobs: [Job]) {
        guard !requested else { return }
        if agent.status != .notRegistered { try? agent.unregister() }
    }

    /// The window's clock: every minute, start each backup whose time has come.
    @MainActor static func runDueInApp(_ store: JobStore) {
        let now = Date()
        for job in store.jobs {
            let present = job.destination.map { FileManager.default.fileExists(atPath: $0) } ?? false
            let since = present ? (job.destinationSince ?? now) : nil
            if since != job.destinationSince, let i = store.jobs.firstIndex(where: { $0.id == job.id }) { store.jobs[i].destinationSince = since }
            guard job.ready, !store.runner(for: job.id).running,
                  job.schedule.isDue(now: now, lastRun: job.lastRun, destinationSince: since) else { continue }
            DevLog.write("schedule: starting \(job.title) (\(job.schedule.words))")
            store.start(job.id)
        }
    }

    static var requested: Bool { CommandLine.arguments.contains("--scheduled") }

    /// Runs every due backup, one after another, then returns.
    static func runDue() {
        let store = JobStore()
        let now = Date()
        guard store.jobs.contains(where: { $0.schedule != .byHand }) else { return }   // nothing scheduled: nothing to do
        // A laptop must not sleep, and a background process must not be napped, mid-copy.
        let awake = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled, .userInitiated], reason: "Scheduled backup")
        defer { ProcessInfo.processInfo.endActivity(awake) }
        for id in store.jobs.map(\.id) {
            guard let i = store.jobs.firstIndex(where: { $0.id == id }) else { continue }
            var job = store.jobs[i]
            let present = job.destination.map { FileManager.default.fileExists(atPath: $0) } ?? false
            job.destinationSince = present ? (job.destinationSince ?? now) : nil
            store.jobs[i] = job
            guard job.ready, job.schedule.isDue(now: now, lastRun: job.lastRun, destinationSince: job.destinationSince) else { continue }
            var copied = 0, problems = 0
            var bytes: Int64 = 0, total: Int64 = 0
            var past: String?
            let live = job.sources.filter { !$0.skip }
            let stamp: String = { let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd HHmmss"; return f.string(from: Date()) }()
            for (i, s) in live.enumerated() {
                guard let target = job.target(for: s) else { continue }
                var o = Options()
                o.excluded = Set(s.leftOut)
                o.patterns = s.namesLeftOut
                o.destinationKind = job.destinationKind
                o.finalFlush = i == live.count - 1
                o.keepDeleted = job.keepDeleted; o.keepChanged = job.keepChanged
                o.pastRoot = job.pastRoot; o.pastSubfolder = s.name; o.stamp = stamp
                do {
                    let r = try Engine(source: s.readPath, destination: target, options: o).run()
                    copied += r.copied; bytes += r.bytes; problems += r.problems.count
                    total += r.sourceBytes
                    past = r.pastFolder.map { ($0 as NSString).deletingLastPathComponent } ?? past
                } catch {
                    problems += 1   // e.g. the app is copying this one right now: its run lock refuses us
                }
            }
            let size = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
            job.lastResult = (copied == 0 ? "Nothing had changed" : "\(copied) copied (\(size))") + " (\(job.schedule.words.lowercased()))"
            job.lastState = problems == 0 ? "Backed up" : "Backed up, \(problems) skipped"
            job.lastPast = past ?? job.lastPast
            job.lastRun = Date()
            if let root = job.pastRoot { Past.prune(root, keepDays: job.keepDays, minFree: job.makeRoom ? Past.guardSpace(root) : 0) }
            job.lastBytes = total
            // The window may have edited the file during this run: take its copy, put only our results on it.
            if var fresh = JobStore.read(store.file) {
                if let k = fresh.firstIndex(where: { $0.id == job.id }) { fresh[k].takeResults(from: job) }
                store.jobs = fresh
            } else {
                store.jobs[i] = job
            }
            store.save()
            if problems > 0 { notify("\(job.title): \(problems) skipped", "Open Archivist to see which files.") }
        }
        store.save()
    }

    /// A scheduled run has no window: a problem is said through Notification Center.
    private static func notify(_ title: String, _ body: String) {
        let center = UNUserNotificationCenter.current()
        let done = DispatchSemaphore(value: 0)
        center.requestAuthorization(options: [.alert]) { ok, _ in
            guard ok else { done.signal(); return }
            let c = UNMutableNotificationContent(); c.title = title; c.body = body
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil)) { _ in done.signal() }
        }
        _ = done.wait(timeout: .now() + 3)
    }
}
