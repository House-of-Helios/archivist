import Foundation
import AppKit
import ArchivistCore

/// Installs a downloaded update (`AppSwap`), in two halves:
///
/// - `stage` — while this app still runs, copy the new version beside it under a hidden
///   name and check its signature. `Updater` runs this in the background as soon as an
///   update is downloaded, so Install rarely waits.
/// - `finish` — trade places by rename, open the new build and quit.
///
/// If anything before the swap fails, the app carries on as it was and says why.
enum AppInstaller {
    static var installed: URL { Bundle.main.bundleURL }

    /// Builds the new version at `AppSwap.stagedURL` from the unpacked `sourceApp` and
    /// checks it. Returns why it stopped, or nil when ready.
    static func stage(from sourceApp: URL) async -> String? {
        let installed = installed
        var isDir: ObjCBool = false
        guard sourceApp.pathExtension == "app",
              FileManager.default.fileExists(atPath: sourceApp.path, isDirectory: &isDir), isDir.boolValue
        else { return "The update didn't unpack to a Archivist.app." }
        let staged = AppSwap.stagedURL(for: installed)
        let bundleId = Bundle.main.bundleIdentifier ?? "com.houseofhelios.archivist"

        return await Task.detached {
            try? FileManager.default.removeItem(at: staged)
            guard run("/usr/bin/ditto", [sourceApp.path, staged.path]).ok else {
                try? FileManager.default.removeItem(at: staged)
                return "Couldn't copy the update."
            }
            // The update must carry this app's own signature (the steady "Archivist"
            // certificate), not just its name; an ad-hoc build falls back to the name.
            let check = run("/usr/bin/codesign", ["--verify", "--strict", "--deep", "-R", requirement(of: installed, id: bundleId), staged.path])
            guard check.ok else {
                try? FileManager.default.removeItem(at: staged)
                return "The update didn't check out (its signature), so it wasn't installed."
            }
            return nil
        }.value
    }

    /// Swaps the staged build in and restarts into it. Returns why it stopped; on success
    /// it doesn't return, since this app quits.
    @MainActor
    static func finish() -> String? {
        let installed = installed
        let staged = AppSwap.stagedURL(for: installed)
        guard !AppDelegate.store.anyRunning else { return "A backup is running — install the update when it's done." }
        guard FileManager.default.fileExists(atPath: staged.path) else { return "The update isn't ready yet." }
        // The staged copy may have sat beside the app for an hour: check it again now, and
        // that it is newer than this build.
        let bundleId = Bundle.main.bundleIdentifier ?? "com.houseofhelios.archivist"
        guard run("/usr/bin/codesign", ["--verify", "--strict", "--deep", "-R", requirement(of: installed, id: bundleId), staged.path]).ok,
              let stagedInfo = NSDictionary(contentsOf: staged.appendingPathComponent("Contents/Info.plist")),
              let stagedVersion = stagedInfo["CFBundleShortVersionString"] as? String,
              let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              UpdateChecker.isNewer(stagedVersion, than: current)
        else {
            try? FileManager.default.removeItem(at: staged)
            return "The update didn't check out, so it wasn't installed."
        }
        do { try AppSwap.swap(installed: installed, staged: staged) } catch {
            return "Couldn't swap in the update — Archivist is unchanged."
        }
        // If it won't open, stay up and say so: the new build is already in place, so
        // opening Archivist by hand finishes the update.
        // Open it again only once this copy has quit: `open -n` while it still ran gave a second
        // Dock icon. A small shell waits for this process to end, then opens the app normally.
        let relaunch = Process()
        relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
        relaunch.arguments = ["-c", "while kill -0 \(getpid()) 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$0\"", installed.path]
        do { try relaunch.run() } catch {
            return "Update installed — open Archivist again to finish."
        }
        NSApp.terminate(nil)
        return nil
    }

    /// This app's designated requirement ("identifier … and certificate root = H…"), as
    /// codesign prints it; the bundle id alone when the app is ad-hoc signed (cdhash only).
    nonisolated static func requirement(of app: URL, id: String) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        p.arguments = ["-d", "-r-", app.path]
        let out = Pipe()
        p.standardOutput = out; p.standardError = out
        try? p.run()
        let text = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        p.waitUntilExit()
        if let line = text.split(separator: "\n").first(where: { $0.hasPrefix("designated => ") }),
           line.contains("certificate") {
            return "=" + line.dropFirst("designated => ".count)
        }
        return "=identifier \"\(id)\""
    }

    /// Runs a tool; `why` holds its last error line (or the exit code) when it fails. A
    /// tool still running after `limit` seconds is stopped and counts as failed.
    nonisolated private static func run(_ tool: String, _ args: [String],
                                        limit: TimeInterval = 120) -> (ok: Bool, why: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let err = Pipe()
        p.standardOutput = FileHandle.nullDevice
        p.standardError = err
        do { try p.run() } catch { return (false, "couldn't start \(tool): \(error.localizedDescription)") }
        let timer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + limit, execute: timer)
        let text = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        p.waitUntilExit()
        timer.cancel()
        if p.terminationStatus == 0 { return (true, "") }
        if p.terminationReason == .uncaughtSignal { return (false, "stopped after \(Int(limit))s") }
        let last = text.split(separator: "\n").last.map(String.init) ?? ""
        return (false, last.isEmpty ? "exit \(p.terminationStatus)" : last)
    }
}
