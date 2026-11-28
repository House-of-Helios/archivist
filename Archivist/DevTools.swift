import AppKit
import ArchivistCore
import Foundation

/// A plain-text timeline of what the app does, for reading after the fact:
/// `_devdata/app/dev.log` in dev builds, `~/Library/Logs/Archivist/archivist.log` in a release.
/// Capped at 5 MB, then rolled to `.1` (one old copy kept).
enum DevLog {
    private static let queue = DispatchQueue(label: "archivist.devlog")
    private static let cap: UInt64 = 5 << 20
    static let file: URL = {
        #if DEBUG
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("_devdata/app")
        #else
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0].appendingPathComponent("Logs/Archivist")
        #endif
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = dir.appendingPathComponent(dir.lastPathComponent == "app" ? "dev.log" : "archivist.log")
        // Paths of the person's files go in here: readable by them alone.
        if !FileManager.default.fileExists(atPath: f.path) { FileManager.default.createFile(atPath: f.path, contents: nil, attributes: [.posixPermissions: 0o600]) }
        return f
    }()
    private static let stamp: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"; return f
    }()

    static func write(_ line: String) {
        let text = "\(stamp.string(from: Date())) \(line)\n"
        queue.async {
            let fm = FileManager.default
            if let size = (try? fm.attributesOfItem(atPath: file.path))?[.size] as? UInt64, size > cap {
                let old = file.appendingPathExtension("1")
                try? fm.removeItem(at: old)
                try? fm.moveItem(at: file, to: old)
            }
            if let h = try? FileHandle(forWritingTo: file) {
                h.seekToEndOfFile(); h.write(text.data(using: .utf8)!); try? h.close()
            } else {
                try? text.write(to: file, atomically: false, encoding: .utf8)
            }
        }
    }

    static func mb(_ b: Int64) -> String { String(format: "%.1f MB", Double(b) / 1e6) }
}

#if DEBUG
/// Dev builds only: drive the real app from outside. Drop a JSON file into
/// `_devdata/app/control/`; the app runs it and moves it to `control/done/` with a result.
///
///   {"cmd":"state"}                                   → _devdata/app/state.json
///   {"cmd":"snapshot"}                                → _devdata/app/window.png (the live window, drawn by the app itself)
///   {"cmd":"add","title":"T","sources":["/…"],"destination":"/…"}
///   {"cmd":"select","job":"T"}   {"cmd":"start","job":"T"}   {"cmd":"stop","job":"T"}
///   {"cmd":"remove","job":"T"}
@MainActor
enum DevControl {
    static var store: JobStore!
    static var select: ((Job.ID) -> Void)?
    private static var timer: Timer?
    static let dir = DevLog.file.deletingLastPathComponent().appendingPathComponent("control")

    static func start(_ s: JobStore, select sel: @escaping (Job.ID) -> Void) {
        store = s; select = sel
        try? FileManager.default.createDirectory(at: dir.appendingPathComponent("done"), withIntermediateDirectories: true)
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in Task { @MainActor in poll() } }
        DevLog.write("control: watching \(dir.path)")
    }

    private static func poll() {
        let files = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        for f in files {
            var result: [String: Any] = ["ok": false]
            if let data = try? Data(contentsOf: f), let cmd = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                result = run(cmd)
                DevLog.write("control: \(cmd["cmd"] ?? "?") \(cmd["job"] ?? "") -> \(result["ok"] ?? false) \(result["error"] ?? "")")
            } else {
                result["error"] = "not JSON"
            }
            let done = dir.appendingPathComponent("done").appendingPathComponent(f.lastPathComponent)
            try? FileManager.default.removeItem(at: done)
            try? FileManager.default.moveItem(at: f, to: done)
            if let out = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) {
                try? out.write(to: done.deletingPathExtension().appendingPathExtension("result.json"))
            }
        }
    }

    private static func job(_ cmd: [String: Any]) -> Job? {
        guard let key = cmd["job"] as? String else { return nil }
        return store.jobs.first { $0.title == key || $0.id.uuidString == key }
    }

    private static func run(_ cmd: [String: Any]) -> [String: Any] {
        switch cmd["cmd"] as? String {
        case "forgetDrive":   // {"cmd":"forgetDrive","path":"/Volumes/X"}: Settings' "Start fresh"
            guard let p = cmd["path"] as? String else { return ["ok": false, "error": "no path"] }
            DriveMemories.forget(p)
            return ["ok": true, "left": DriveMemories.load()[DriveMemories.key(for: p)] == nil]
        case "state":
            writeState()
            return ["ok": true, "file": DevLog.file.deletingLastPathComponent().appendingPathComponent("state.json").path]
        case "snapshot":
            // Every visible window the app owns: the main window, and any popover or sheet open.
            var files: [String] = []
            let dir = DevLog.file.deletingLastPathComponent()
            for (i, w) in NSApp.windows.filter({ $0.isVisible && $0.contentView != nil }).enumerated() {
                guard let v = w.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { continue }
                v.cacheDisplay(in: v.bounds, to: rep)
                let out = dir.appendingPathComponent(i == 0 ? "window.png" : "window-\(i).png")
                try? rep.representation(using: .png, properties: [:])?.write(to: out)
                files.append(out.path)
            }
            return files.isEmpty ? ["ok": false, "error": "no window"] : ["ok": true, "files": files]
        case "showSettings":
            guard let j = job(cmd) else { return ["ok": false, "error": "no such job"] }
            select?(j.id)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { NotificationCenter.default.post(name: .showSettings, object: nil) }
            return ["ok": true]
        case "add":
            var j = store.add()
            j.title = cmd["title"] as? String ?? j.title
            _ = j.addSources(cmd["sources"] as? [String] ?? [])
            if let d = cmd["destination"] as? String {
                j.destination = d
                if !j.lookChosen { let l = Contrast.look(for: d, pool: Job.icons); j.icon = l.icon; j.color = l.color }
            }
            store.update(j)
            select?(j.id)
            return ["ok": true, "id": j.id.uuidString]
        case "select":
            guard let j = job(cmd) else { return ["ok": false, "error": "no such job"] }
            select?(j.id)
            return ["ok": true]
        case "start":
            guard let j = job(cmd) else { return ["ok": false, "error": "no such job"] }
            guard j.ready else { return ["ok": false, "error": "not ready (sources/destination)"] }
            select?(j.id)
            store.start(j.id)
            return ["ok": true]
        case "stop":
            guard let j = job(cmd) else { return ["ok": false, "error": "no such job"] }
            store.runner(for: j.id).stop()
            return ["ok": true]
        case "remove":
            guard let j = job(cmd) else { return ["ok": false, "error": "no such job"] }
            store.remove(j.id)
            return ["ok": true]
        case "resize":   // {"cmd":"resize","w":780,"h":400}: the main window's content size
            guard let w = cmd["w"] as? Double, let h = cmd["h"] as? Double,
                  let win = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }) else { return ["ok": false] }
            win.setContentSize(NSSize(width: w, height: h))
            return ["ok": true, "size": "\(win.frame.size)"]
        case "update":   // press "Install & restart" on whatever GitHub offers
            Task { @MainActor in
                let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
                let status = await Updater.check(current: v)
                DevLog.write("update test: \(status)")
                if let u = status.update { Updater.shared.install(u) }
            }
            return ["ok": true]
        default:
            return ["ok": false, "error": "unknown cmd"]
        }
    }

    static func writeState() {
        let jobs: [[String: Any]] = store.jobs.map { j in
            let r = store.runners[j.id]
            let o = r?.overall
            var d: [String: Any] = ["title": j.title, "id": j.id.uuidString, "destination": j.destination ?? "",
                                    "sources": j.sources.map(\.path), "lastResult": j.lastResult ?? "", "schedule": j.schedule.words]
            // Each source row as the window reads it: size, what is still to copy, and whether what is
            // left is only live or unreadable files (shown "up to date" with an info dot).
            d["rows"] = j.sources.map { s -> [String: Any] in
                var row: [String: Any] = ["name": s.name, "skip": s.skip]
                if let v = store.surveys[s.id] {
                    row["bytes"] = v.bytes; row["files"] = v.files; row["toCopy"] = v.toCopy; row["bytesToCopy"] = v.bytesToCopy
                    row["compared"] = v.compared; row["pending"] = v.pending.count
                }
                if let q = SourceRow.settled(job: j, source: s, survey: store.surveys[s.id]) { row["settled"] = ["live": q.live, "unreadable": q.unreadable.count] }
                return row
            }
            if let r, r.running, let o {
                d["running"] = ["files": o.files, "filesTotal": o.filesTotal, "bytes": o.bytes, "bytesTotal": o.bytesTotal,
                                "mbPerSecond": r.bytesPerSecond / 1e6, "source": r.currentSource ?? "",
                                "eta": r.remaining(at: Date()) ?? -1, "finishing": r.finishing,
                                "doneSources": j.sources.filter { r.doneSources.contains($0.id) }.map(\.name),
                                "sourceBytes": [r.progress.bytesDone, r.progress.bytesTotal]]
            }
            return d
        }
        let out = DevLog.file.deletingLastPathComponent().appendingPathComponent("state.json")
        if let data = try? JSONSerialization.data(withJSONObject: ["jobs": jobs, "at": ISO8601DateFormatter().string(from: Date())],
                                                  options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: out) }
    }
}
#endif
