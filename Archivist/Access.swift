import Foundation
import Observation

/// Folders macOS is holding until the person answers a permission popup.
///
/// A read of a shared drive (Network Volumes) or a private folder (Desktop, Documents…) by an app
/// macOS hasn't asked about yet does not fail: it waits, with no error, until someone answers the
/// popup. A run started before walking away waited 9 hours that way (2026-11-28). So a folder is
/// touched the moment it is added, at app open and at Start: any popup shows while the person is
/// there, and a folder still not answering after a few seconds is named in the window.
@MainActor @Observable
final class Access {
    static let shared = Access()
    /// Paths whose first read hasn't come back after `patience` seconds.
    private(set) var waiting: Set<String> = []
    private var pending: Set<String> = []
    nonisolated static let patience: Double = 5

    /// Read the top of each folder off the main thread; a read that hangs past `patience` is named.
    func touch(_ paths: [String]) {
        for p in paths where !pending.contains(p) {
            pending.insert(p)
            let started = Date()
            Thread.detachNewThread {
                Access.firstEntry(p)
                let took = Date().timeIntervalSince(started)
                DispatchQueue.main.async {
                    Access.shared.pending.remove(p)
                    if Access.shared.waiting.remove(p) != nil {
                        DevLog.write(String(format: "access: %@ answered after %.0f s", p, took))
                    }
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + Access.patience) {
                guard Access.shared.pending.contains(p) else { return }
                Access.shared.waiting.insert(p)
                DevLog.write("access: \(p) still waiting after \(Int(Access.patience)) s (permission popup?)")
            }
        }
    }

    func isWaiting(_ path: String) -> Bool { waiting.contains(path) }
    var anyWaiting: Bool { !waiting.isEmpty }

    /// The read that makes macOS ask: open the folder and read one name.
    nonisolated static func firstEntry(_ path: String) {
        guard let d = opendir(path) else { return }
        _ = readdir(d)
        closedir(d)
    }

    /// What the window says while macOS waits for an answer.
    static let message = "Waiting for your OK: System Settings › Privacy & Security › Files & Folders › Archivist"
}
