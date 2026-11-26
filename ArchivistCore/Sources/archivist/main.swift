import ArchivistCore
import Foundation

let usage = """
archivist: copy any drive or folder to another, the way each drive moves best.

  archivist copy SOURCE DESTINATION [--exclude PATH]... [--dry-run]
                 [--source-kind ssd|spinning|unknown|network] [--destination-kind ...]
                 [--lanes SMALL,BIG] [--order small|big]
  archivist drive PATH          what Archivist sees for the drive under PATH

Nothing is ever deleted: a replaced or vanished file moves to DESTINATION/_📚archive/<date>/.
"""

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write((msg + "\n").data(using: .utf8)!)
    exit(1)
}

func human(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }

var args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else { print(usage); exit(2) }
args.removeFirst()

switch command {
case "drive":
    guard let path = args.first else { fail(usage) }
    do {
        let d = try Drive.of(path: path)
        print("\(d.name): \(d.kind.rawValue), \(d.fileSystem), mounted at \(d.mountPoint)")
    } catch { fail("\(error)") }

case "copy":
    var opts = Options()
    var paths: [String] = []
    var i = 0
    func value() -> String {
        i += 1
        guard i < args.count else { fail("\(args[i - 1]) needs a value") }
        return args[i]
    }
    while i < args.count {
        switch args[i] {
        case "--exclude": opts.excluded.insert(value().trimmingCharacters(in: CharacterSet(charactersIn: "/")))
        case "--dry-run": opts.dryRun = true
        case "--barrier": opts.barrier = true
        case "--temp-all": opts.directNew = false
        case "--callback-all": opts.callbackFrom = 0
        case "--source-kind": opts.sourceKind = DriveKind(rawValue: value()) ?? { fail("unknown kind") }()
        case "--destination-kind": opts.destinationKind = DriveKind(rawValue: value()) ?? { fail("unknown kind") }()
        case "--order":   // bench: small | big (one lane after the other); default: the lanes decide
            let v = value(); guard v == "small" || v == "big" else { fail("--order small|big") }
            opts.bigFirst = v == "big"
        case "--lanes":
            let n = value().split(separator: ",").compactMap { Int($0) }
            guard n.count == 2, n.allSatisfy({ $0 > 0 }) else { fail("--lanes SMALL,BIG") }
            opts.lanes = Lanes(small: n[0], big: n[1], together: true, diskOrder: false)
        default: paths.append(args[i])
        }
        i += 1
    }
    guard paths.count == 2 else { fail(usage) }

    let engine = Engine(source: paths[0], destination: paths[1], options: opts)
    var last = Date.distantPast
    let printLock = NSLock()
    engine.onProgress = { p in
        printLock.lock(); defer { printLock.unlock() }
        guard Date().timeIntervalSince(last) >= 1 else { return }
        last = Date()
        FileHandle.standardError.write("\r\(p.filesDone)/\(p.filesTotal) files, \(human(p.bytesDone)) of \(human(p.bytesTotal))   ".data(using: .utf8)!)
    }
    do {
        let r = try engine.run()
        FileHandle.standardError.write("\r\u{1B}[K".data(using: .utf8)!)
        print("""
        \(r.source.name) (\(r.source.kind.rawValue), \(r.source.fileSystem)) → \(r.destination.name) (\(r.destination.kind.rawValue), \(r.destination.fileSystem))
        lanes: small \(r.lanes.small), big \(r.lanes.big)\(r.lanes.diskOrder ? ", disk order" : "")\(r.lanes.together ? "" : ", one after the other")
        \(opts.dryRun ? "would copy" : "copied") \(r.copied) files (\(human(r.bytes))), \(r.unchanged) unchanged, \(r.retired) moved to _📚archive, \(String(format: "%.2f", r.seconds)) s
        """)
        if let past = r.pastFolder { print("old versions: \(past)") }
        for p in r.problems { print("problem: \(p)") }
        exit(r.problems.isEmpty ? 0 : 3)
    } catch { fail("\(error)") }

default:
    print(usage)
    exit(2)
}
