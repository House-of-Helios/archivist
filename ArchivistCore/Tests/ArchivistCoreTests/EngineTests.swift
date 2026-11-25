import Darwin
import Foundation
import XCTest
@testable import ArchivistCore

/// Test trees live in _devdata/tests (gitignored).
let testRoot: String = {
    let here = URL(fileURLWithPath: #filePath)
    return here.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("_devdata/tests").path
}()

final class EngineTests: XCTestCase {
    var src = "", dst = ""

    override func setUpWithError() throws {
        let base = testRoot + "/" + name.filter { $0.isLetter || $0.isNumber } + "-" + UUID().uuidString.prefix(6)
        src = base + "/src"
        dst = base + "/dst"
        try FileManager.default.createDirectory(atPath: src, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: dst, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        // The fixture's "deny delete" ACL would make the tree undeletable: strip ACLs first.
        let base = (src as NSString).deletingLastPathComponent
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/chmod")
        p.arguments = ["-RN", base]
        try? p.run(); p.waitUntilExit()
        try? FileManager.default.removeItem(atPath: base)
    }

    // MARK: fixture

    func write(_ rel: String, _ text: String, mtime: Double? = nil) {
        let p = src + "/" + rel
        try! FileManager.default.createDirectory(atPath: (p as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try! text.write(toFile: p, atomically: false, encoding: .utf8)
        if let mtime { setMtime(p, mtime) }
    }

    func setMtime(_ p: String, _ t: Double) {
        var times = [timespec(tv_sec: Int(t), tv_nsec: Int((t - floor(t)) * 1e9)),
                     timespec(tv_sec: Int(t), tv_nsec: Int((t - floor(t)) * 1e9))]
        XCTAssertEqual(utimensat(AT_FDCWD, p, &times, AT_SYMLINK_NOFOLLOW), 0)
    }

    func sh(_ args: String...) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: args[0])
        p.arguments = Array(args.dropFirst())
        try! p.run()
        p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0, args.joined(separator: " "))
    }

    /// A tree with every Mac file detail Archivist promises to keep.
    func buildFixture() {
        write("plain.txt", "hello")
        write("café ☀️ name with spaces.txt", "unicode")
        write("deep/" + (1...30).map { "d\($0)" }.joined(separator: "/") + "/bottom.txt", "deep")
        try! FileManager.default.createDirectory(atPath: src + "/empty", withIntermediateDirectories: true)

        write("xattr.txt", "x")
        XCTAssertEqual(setxattr(src + "/xattr.txt", "org.house.note", "warm", 4, 0, 0), 0)
        let fork = [UInt8](repeating: 7, count: 300)
        XCTAssertEqual(setxattr(src + "/xattr.txt", XATTR_RESOURCEFORK_NAME, fork, fork.count, 0, 0), 0)

        write("acl.txt", "acl")
        sh("/bin/chmod", "+a", "everyone deny delete", src + "/acl.txt")

        write("hidden-flag.txt", "flag")
        XCTAssertEqual(chflags(src + "/hidden-flag.txt", UInt32(UF_HIDDEN)), 0)

        write("setuid-tool", "#!/bin/sh\n")
        XCTAssertEqual(chmod(src + "/setuid-tool", 0o4755), 0)

        write("links/a.txt", "linked")
        XCTAssertEqual(link(src + "/links/a.txt", src + "/links/b.txt"), 0)
        XCTAssertEqual(symlink("a.txt", src + "/links/sym"), 0)

        // Sparse: 1 MiB data, 64 MiB hole, 1 MiB data.
        let fd = open(src + "/sparse.img", O_CREAT | O_WRONLY, 0o644)
        let mb = [UInt8](repeating: 1, count: 1 << 20)
        _ = mb.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        lseek(fd, 65 << 20, SEEK_SET)
        _ = mb.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        close(fd)

        write("dated.txt", "old", mtime: 1_000_000_000.123456789)
        setMtime(src + "/deep", 1_100_000_000)
    }

    func backup(_ opts: Options = Options()) throws -> Report {
        var o = opts
        if o.lanes == nil { o.lanes = Lanes(small: 4, big: 2, together: true, diskOrder: false) }
        return try Engine(source: src, destination: dst, options: o).run()
    }

    // MARK: checks

    func xattrs(_ p: String) -> [String: [UInt8]] {
        let n = listxattr(p, nil, 0, XATTR_NOFOLLOW)
        guard n > 0 else { return [:] }
        var names = [CChar](repeating: 0, count: n)
        listxattr(p, &names, n, XATTR_NOFOLLOW)
        var out: [String: [UInt8]] = [:]
        for name in names.split(separator: 0).map({ String(cString: Array($0) + [0]) }) {
            if name == "com.apple.provenance" { continue } // stamped by macOS on every write
            let size = getxattr(p, name, nil, 0, 0, XATTR_NOFOLLOW)
            var v = [UInt8](repeating: 0, count: max(size, 0))
            getxattr(p, name, &v, v.count, 0, XATTR_NOFOLLOW)
            out[name] = v
        }
        return out
    }

    func acl(_ p: String) -> String {
        guard let a = acl_get_link_np(p, ACL_TYPE_EXTENDED) else { return "" }
        defer { acl_free(UnsafeMutableRawPointer(a)) }
        guard let t = acl_to_text(a, nil) else { return "" }
        defer { acl_free(t) }
        // Drop the owner UUID column noise: keep the rule lines as written.
        return String(cString: t).split(separator: "\n").map { $0.split(separator: ":").suffix(3).joined(separator: ":") }.joined(separator: "\n")
    }

    func lst(_ p: String) -> stat { var s = stat(); XCTAssertEqual(lstat(p, &s), 0, p); return s }

    func assertSame(_ rel: String, file: StaticString = #filePath, line: UInt = #line) {
        let a = src + "/" + rel, b = dst + "/" + rel
        let sa = lst(a), sb = lst(b)
        XCTAssertEqual(sa.st_mode, sb.st_mode, "mode \(rel)", file: file, line: line)
        XCTAssertEqual(sa.st_flags, sb.st_flags, "flags \(rel)", file: file, line: line)
        if sa.st_mode & S_IFMT != S_IFDIR { // a folder's size is the file system's own bookkeeping
            XCTAssertEqual(sa.st_size, sb.st_size, "size \(rel)", file: file, line: line)
            XCTAssertEqual(sa.st_mtimespec.tv_sec, sb.st_mtimespec.tv_sec, "mtime \(rel)", file: file, line: line)
            XCTAssertEqual(sa.st_mtimespec.tv_nsec, sb.st_mtimespec.tv_nsec, "mtime ns \(rel)", file: file, line: line)
        }
        XCTAssertEqual(xattrs(a), xattrs(b), "xattrs \(rel)", file: file, line: line)
        XCTAssertEqual(acl(a), acl(b), "acl \(rel)", file: file, line: line)
        if sa.st_mode & S_IFMT == S_IFREG {
            XCTAssertEqual(FileManager.default.contents(atPath: a), FileManager.default.contents(atPath: b), "data \(rel)", file: file, line: line)
        }
    }

    func allPaths(_ root: String) -> Set<String> {
        Set(FileManager.default.enumerator(atPath: root)!.compactMap { $0 as? String }
            .filter { !$0.hasPrefix(Names.past) && !$0.hasPrefix(Names.state) })
    }

    // MARK: tests

    func testRoundTripKeepsEveryMacDetail() throws {
        buildFixture()
        for clone in [false, true] {
            try? FileManager.default.removeItem(atPath: dst)
            try FileManager.default.createDirectory(atPath: dst, withIntermediateDirectories: true)
            var o = Options()
            o.allowClone = clone
            let r = try backup(o)
            XCTAssertEqual(r.problems, [], "clone \(clone)")
            XCTAssertEqual(allPaths(src), allPaths(dst), "clone \(clone)")
            for rel in allPaths(src) { assertSame(rel) }

            // Hard links stay one file; symlinks stay links; holes stay holes.
            XCTAssertEqual(lst(dst + "/links/a.txt").st_ino, lst(dst + "/links/b.txt").st_ino, "hard link, clone \(clone)")
            let target = try FileManager.default.destinationOfSymbolicLink(atPath: dst + "/links/sym")
            XCTAssertEqual(target, "a.txt")
            XCTAssertLessThan(Int64(lst(dst + "/sparse.img").st_blocks) * 512, 8 << 20, "sparse, clone \(clone)")
            // Folder dates survive the files written inside them.
            XCTAssertEqual(lst(dst + "/deep").st_mtimespec.tv_sec, 1_100_000_000)
        }
    }

    func testSecondRunWithNothingChangedCopiesNothing() throws {
        buildFixture()
        _ = try backup()
        let r = try backup()
        XCTAssertEqual(r.copied, 0)
        XCTAssertEqual(r.retired, 0)
        XCTAssertEqual(r.problems, [])
        XCTAssertNil(r.pastFolder)
    }

    func testChangedAndDeletedFilesMoveToPastNeverLost() throws {
        write("keep.txt", "same", mtime: 1_500_000_000)
        write("change.txt", "version one", mtime: 1_500_000_000)
        write("gone.txt", "bye", mtime: 1_500_000_000)
        write("gone-dir/inner.txt", "inner")
        _ = try backup()
        let keepInode = lst(dst + "/keep.txt").st_ino

        write("change.txt", "version two!", mtime: 1_600_000_000)
        unlink(src + "/gone.txt")
        try FileManager.default.removeItem(atPath: src + "/gone-dir")
        let r = try backup()

        XCTAssertEqual(r.copied, 1)
        XCTAssertEqual(r.retired, 3) // old change.txt, gone.txt, gone-dir
        XCTAssertEqual(try String(contentsOfFile: dst + "/change.txt", encoding: .utf8), "version two!")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dst + "/gone.txt"))
        let past = try XCTUnwrap(r.pastFolder)
        XCTAssertEqual(try String(contentsOfFile: past + "/change.txt", encoding: .utf8), "version one")
        XCTAssertEqual(try String(contentsOfFile: past + "/gone.txt", encoding: .utf8), "bye")
        XCTAssertEqual(try String(contentsOfFile: past + "/gone-dir/inner.txt", encoding: .utf8), "inner")
        XCTAssertEqual(lst(dst + "/keep.txt").st_ino, keepInode, "unchanged file untouched")
    }

    func testAFileThatBecomesAFolderKeepsTheOldFileInPast() throws {
        write("thing", "a file")
        _ = try backup()
        unlink(src + "/thing")
        write("thing/inside.txt", "now a folder")
        let r = try backup()
        XCTAssertEqual(r.problems, [])
        XCTAssertEqual(try String(contentsOfFile: dst + "/thing/inside.txt", encoding: .utf8), "now a folder")
        XCTAssertEqual(try String(contentsOfFile: r.pastFolder! + "/thing", encoding: .utf8), "a file")
    }

    func testExcludedFoldersAreLeftOut() throws {
        write("keep/a.txt", "a")
        write("skip/b.txt", "b")
        write("keep/skip/c.txt", "c")
        var o = Options()
        o.excluded = ["skip"]
        _ = try backup(o)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dst + "/keep/a.txt"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dst + "/keep/skip/c.txt"), "only the top-level path is excluded")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dst + "/skip"))
    }

    func testLeftoverTempsAreRemovedAndADeadRunsLockIsTakenOver() throws {
        write("a.txt", "a")
        try FileManager.default.createDirectory(atPath: dst + "/" + Names.state, withIntermediateDirectories: true)
        try "999999\n".write(toFile: dst + "/" + Names.state + "/run.lock", atomically: false, encoding: .utf8)
        try "half".write(toFile: dst + "/" + Names.tempPrefix + "DEADBEEF", atomically: false, encoding: .utf8)
        let r = try backup()
        XCTAssertEqual(r.problems, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: dst + "/" + Names.tempPrefix + "DEADBEEF"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dst + "/" + Names.state + "/run.lock"))
        XCTAssertEqual(r.retired, 0, "temps are not the person's files: never moved to _Archive")
    }

    func testALiveRunsLockRefuses() throws {
        write("a.txt", "a")
        try FileManager.default.createDirectory(atPath: dst + "/" + Names.state, withIntermediateDirectories: true)
        try "\(getpid())\n".write(toFile: dst + "/" + Names.state + "/run.lock", atomically: false, encoding: .utf8)
        XCTAssertThrowsError(try backup())
    }

    func testRefusesADestinationInsideTheSource() throws {
        write("a.txt", "a")
        XCTAssertThrowsError(try Engine(source: src, destination: src + "/inner").run())
        XCTAssertThrowsError(try Engine(source: src, destination: (src as NSString).deletingLastPathComponent).run())
    }

    func testDryRunWritesNothing() throws {
        write("a.txt", "a")
        var o = Options()
        o.dryRun = true
        let r = try backup(o)
        XCTAssertEqual(r.copied, 1)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dst), [], "a dry run makes no state, no lock")
        _ = try backup()
        let before = try FileManager.default.subpathsOfDirectory(atPath: dst).sorted()
        _ = try backup(o)
        XCTAssertEqual(try FileManager.default.subpathsOfDirectory(atPath: dst).sorted(), before)
    }

    func testUnreadableSourceFolderKeepsItsBackup() throws {
        write("locked/keep.txt", "k")
        write("open/a.txt", "a")
        _ = try backup()
        chmod(src + "/locked", 0)
        defer { chmod(src + "/locked", 0o755) }
        let r = try backup()
        XCTAssertFalse(r.problems.isEmpty, "the unreadable folder is reported")
        XCTAssertEqual(r.retired, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dst + "/locked/keep.txt"), "what can't be read is not treated as gone")
    }

    func testEmptySourceLeavesTheBackupAlone() throws {
        write("a.txt", "a")
        _ = try backup()
        try FileManager.default.removeItem(atPath: src + "/a.txt")
        XCTAssertThrowsError(try backup())
        XCTAssertTrue(FileManager.default.fileExists(atPath: dst + "/a.txt"))
    }

    func testOldVersionStaysWhenItCannotBeArchived() throws {
        write("a.txt", "one")
        _ = try backup()
        write("a.txt", "two", mtime: 2_000_000_000)
        FileManager.default.createFile(atPath: dst + "/" + Names.past, contents: Data())   // a file blocks the archive folder
        let r = try backup()
        XCTAssertFalse(r.problems.isEmpty)
        XCTAssertEqual(try String(contentsOfFile: dst + "/a.txt", encoding: .utf8), "one", "never replaced without its archive copy")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dst).filter { $0.hasPrefix(Names.tempPrefix) }, [])
    }

    func testReadOnlySourceFolderCanStillBeBackedUpAgain() throws {
        write("ro/a.txt", "a")
        chmod(src + "/ro", 0o555)
        defer { chmod(src + "/ro", 0o755); chmod(dst + "/ro", 0o755) }
        _ = try backup()                      // the backup's ro/ folder is now read-only too
        chmod(src + "/ro", 0o755); write("ro/b.txt", "b"); chmod(src + "/ro", 0o555)
        XCTAssertEqual(try backup().problems, [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: dst + "/ro/b.txt"))
    }

    func testDestinationInsideSourceIsRefusedByIdentity() throws {
        write("a.txt", "a")
        let link = testRoot + "/link-\(UUID().uuidString.prefix(6))"
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: src)
        defer { try? FileManager.default.removeItem(atPath: link) }
        XCTAssertThrowsError(try Engine(source: src, destination: link + "/inside", options: Options()).run())
    }

    func testTheSourceIsNeverWritten() throws {
        buildFixture()
        let before = allPaths(src).map { rel -> String in
            let s = lst(src + "/" + rel)
            return "\(rel) \(s.st_mtimespec.tv_sec).\(s.st_mtimespec.tv_nsec) \(s.st_size) \(s.st_ino)"
        }.sorted()
        _ = try backup()
        let after = allPaths(src).map { rel -> String in
            let s = lst(src + "/" + rel)
            return "\(rel) \(s.st_mtimespec.tv_sec).\(s.st_mtimespec.tv_nsec) \(s.st_size) \(s.st_ino)"
        }.sorted()
        XCTAssertEqual(before, after)
    }

    func testScannerSeesWhatFileManagerSees() throws {
        buildFixture()
        var scanner = TreeScanner()
        let (entries, problems) = try scanner.scan(src)
        XCTAssertEqual(problems, [])
        XCTAssertEqual(Set(entries.map(\.path)), allPaths(src))
        let plain = try XCTUnwrap(entries.first { $0.path == "plain.txt" })
        XCTAssertEqual(plain.size, 5)
        XCTAssertEqual(plain.kind, .file)
        XCTAssertEqual(entries.first { $0.path == "links/a.txt" }?.links, 2)
        XCTAssertEqual(entries.first { $0.path == "dated.txt" }?.mtime ?? 0, 1_000_000_000.123456789, accuracy: 1e-6)
    }

    func testASymlinkAtTheDestinationIsNeverWrittenThrough() throws {
        write("docs/a.txt", "mine")
        let outside = (dst as NSString).deletingLastPathComponent + "/outside"
        try FileManager.default.createDirectory(atPath: outside, withIntermediateDirectories: true)
        XCTAssertEqual(symlink(outside, dst + "/docs"), 0)
        let r = try backup()
        XCTAssertEqual(r.problems, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside + "/a.txt"), "nothing lands outside the destination")
        XCTAssertEqual(try String(contentsOfFile: dst + "/docs/a.txt", encoding: .utf8), "mine")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: r.pastFolder! + "/docs"), outside)
    }

    func testPatternsLeaveNamesOutAnywhereAndNeverRetireThem() throws {
        write("a.txt", "a")
        write("deep/b.tmp", "b")
        write("node_modules/x.js", "x")
        try FileManager.default.createDirectory(atPath: dst + "/deep", withIntermediateDirectories: true)
        try "old".write(toFile: dst + "/deep/old.tmp", atomically: false, encoding: .utf8)
        var o = Options()
        o.patterns = ["*.tmp", "node_modules"]
        let r = try backup(o)
        XCTAssertEqual(r.problems, [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: dst + "/a.txt"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dst + "/deep/b.tmp"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dst + "/node_modules"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dst + "/deep/old.tmp"), "left-out names at the destination are not ours to move")
        XCTAssertEqual(r.retired, 0)
    }

    func testSurveyCountsWhatWouldBeCopied() throws {
        write("a.txt", "aaaa")
        write("b/c.txt", "cc")
        var s = try Survey.of(source: src, destination: dst + "/nothing-yet")
        XCTAssertEqual(s.files, 2); XCTAssertEqual(s.bytes, 6); XCTAssertFalse(s.destinationExists); XCTAssertEqual(s.bytesToCopy, 6)
        _ = try backup()
        s = try Survey.of(source: src, destination: dst)
        XCTAssertEqual(s.toCopy, 0)
        write("a.txt", "changed!", mtime: 1_700_000_000)
        s = try Survey.of(source: src, destination: dst)
        XCTAssertEqual(s.toCopy, 1)
    }

    func testModelNamesTellTheKindWhenTheCaseHidesIt() {
        XCTAssertEqual(Drive.kindFromModel(vendor: "WD", product: "My Passport 2629"), .spinning)
        XCTAssertEqual(Drive.kindFromModel(vendor: "WD", product: "My Passport SSD"), .ssd)
        XCTAssertEqual(Drive.kindFromModel(vendor: "Samsung", product: "PSSD T7"), .ssd)
        XCTAssertEqual(Drive.kindFromModel(vendor: "Seagate", product: "Expansion HDD"), .spinning)
        XCTAssertEqual(Drive.kindFromModel(vendor: "ASMedia", product: "ASM2362"), .unknown, "a bare bridge chip says nothing")
        XCTAssertEqual(Drive.kindFromModel(vendor: nil, product: nil), .unknown)
    }

    func testFinderViewFilesAreNeverCopiedOrRetired() throws {
        write("a.txt", "a")
        write(".DS_Store", "finder at the source")
        try "finder at the destination".write(toFile: dst + "/.DS_Store", atomically: false, encoding: .utf8)
        let r = try backup()
        XCTAssertEqual(r.retired, 0)
        XCTAssertEqual(try String(contentsOfFile: dst + "/.DS_Store", encoding: .utf8), "finder at the destination")
    }

    func testScheduleRules() {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        func at(_ h: Int, _ m: Int, day: Int = 24) -> Date { cal.date(from: DateComponents(year: 2026, month: 11, day: day, hour: h, minute: m))! }
        let here = at(0, 0, day: 1)
        XCTAssertFalse(Schedule.hourly(minute: 15).isDue(now: at(12, 20), lastRun: nil, destinationSince: nil, calendar: cal), "no destination, no run")
        XCTAssertTrue(Schedule.hourly(minute: 15).isDue(now: at(12, 20), lastRun: at(11, 16), destinationSince: here, calendar: cal))
        XCTAssertFalse(Schedule.hourly(minute: 15).isDue(now: at(12, 20), lastRun: at(12, 16), destinationSince: here, calendar: cal))
        XCTAssertFalse(Schedule.hourly(minute: 15).isDue(now: at(12, 10), lastRun: at(11, 16), destinationSince: here, calendar: cal), "12:15 not reached yet")
        let daily = Schedule.daily(hour: 14, minute: 0)
        XCTAssertFalse(daily.isDue(now: at(13, 0), lastRun: at(14, 5, day: 23), destinationSince: here, calendar: cal))
        XCTAssertTrue(daily.isDue(now: at(14, 10), lastRun: at(14, 5, day: 23), destinationSince: here, calendar: cal))
        XCTAssertTrue(daily.isDue(now: at(9, 0), lastRun: at(14, 5, day: 22), destinationSince: here, calendar: cal), "slept through yesterday's time")
        XCTAssertFalse(daily.isDue(now: at(14, 20), lastRun: at(14, 15), destinationSince: here, calendar: cal))
        // 2026-11-24 is a Tuesday (weekday 3).
        let weekly = Schedule.weekly(weekday: 3, hour: 9, minute: 0)
        XCTAssertTrue(weekly.isDue(now: at(9, 30), lastRun: at(9, 5, day: 17), destinationSince: here, calendar: cal))
        XCTAssertFalse(weekly.isDue(now: at(8, 30), lastRun: at(9, 5, day: 17), destinationSince: here, calendar: cal), "this Tuesday's 9:00 not reached")
        XCTAssertFalse(weekly.isDue(now: at(9, 30), lastRun: at(9, 10), destinationSince: here, calendar: cal))
        XCTAssertTrue(Schedule.whenConnected.isDue(now: at(12, 0), lastRun: at(9, 0), destinationSince: at(11, 50), calendar: cal))
        XCTAssertFalse(Schedule.whenConnected.isDue(now: at(12, 0), lastRun: at(11, 55), destinationSince: at(11, 50), calendar: cal), "once per connection")
        XCTAssertFalse(Schedule.byHand.isDue(now: at(12, 0), lastRun: nil, destinationSince: here, calendar: cal))
    }

    func testABackupCanBeBackedUpAgain() throws {
        write("a.txt", "a")
        _ = try backup()                                   // dst now has .archivist/ (and _Past/ after a change)
        write("a.txt", "changed", mtime: 1_700_000_000)
        _ = try backup()
        let second = (dst as NSString).deletingLastPathComponent + "/second"
        let r = try Engine(source: dst, destination: second).run()
        XCTAssertEqual(r.problems, [])
        XCTAssertEqual(try String(contentsOfFile: second + "/a.txt", encoding: .utf8), "changed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: second + "/" + Names.past + "/" + (try FileManager.default.contentsOfDirectory(atPath: dst + "/" + Names.past)).first! + "/a.txt"),
                       "the first backup's earlier versions are not copied into the second's")
    }

    func testStopCutsABigFileMidCopyAndLeavesNothingHalfDone() throws {
        let fd = open(src + "/big.bin", O_CREAT | O_WRONLY, 0o644)
        let chunk = (0..<(8 << 20)).map { UInt8(truncatingIfNeeded: $0 &* 2654435761) }
        for _ in 0..<64 { _ = chunk.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) } }   // 512 MiB
        close(fd)
        write("small.txt", "s")
        var o = Options(); o.allowClone = false; o.lanes = Lanes(small: 1, big: 1, together: false, diskOrder: false)
        let engine = Engine(source: src, destination: dst, options: o)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.15) { engine.stop() }
        let t = Date()
        let r = try engine.run()
        XCTAssertTrue(r.stopped)
        XCTAssertLessThan(Date().timeIntervalSince(t), 5)
        let left = try FileManager.default.contentsOfDirectory(atPath: dst)
        XCTAssertFalse(left.contains { $0.hasPrefix(Names.tempPrefix) }, "no temp file left behind")
        if FileManager.default.fileExists(atPath: dst + "/big.bin") {
            XCTAssertEqual(lst(dst + "/big.bin").st_size, 512 << 20, "a big file there must be whole")
        }
    }

    func testOnePastPerBackupAndTheKeepSwitches() throws {
        write("keep.txt", "k", mtime: 1_500_000_000)
        write("change.txt", "one", mtime: 1_500_000_000)
        write("gone.txt", "bye", mtime: 1_500_000_000)
        _ = try backup()
        write("change.txt", "two", mtime: 1_600_000_000)
        unlink(src + "/gone.txt")
        let root = (dst as NSString).deletingLastPathComponent + "/pastroot"
        var o = Options(); o.pastRoot = root; o.pastSubfolder = "Music"; o.stamp = "2026-11-24 120000"
        let r = try backup(o)
        XCTAssertEqual(r.retired, 2)
        XCTAssertEqual(try String(contentsOfFile: root + "/2026-11-24 120000/Music/change.txt", encoding: .utf8), "one")
        XCTAssertEqual(try String(contentsOfFile: root + "/2026-11-24 120000/Music/gone.txt", encoding: .utf8), "bye")

        // Switches off: a mirror. Changed replaced in place, deleted removed.
        write("change.txt", "three", mtime: 1_700_000_000)
        unlink(src + "/keep.txt")
        var off = Options(); off.keepChanged = false; off.keepDeleted = false; off.pastRoot = root; off.stamp = "2026-11-25 120000"
        let r2 = try backup(off)
        XCTAssertEqual(r2.retired, 0)
        XCTAssertEqual(try String(contentsOfFile: dst + "/change.txt", encoding: .utf8), "three")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dst + "/keep.txt"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root + "/2026-11-25 120000"))
    }

    func testPruneByAgeAndSpaceNeverTheNewest() throws {
        let root = (dst as NSString).deletingLastPathComponent + "/prune"
        for n in ["2025-01-01 000000", "2026-06-01 000000", "2026-11-20 000000", "2026-11-24 000000"] {
            try FileManager.default.createDirectory(atPath: root + "/" + n, withIntermediateDirectories: true)
            try "x".write(toFile: root + "/" + n + "/f", atomically: false, encoding: .utf8)
        }
        let now = Past.stampFormat.date(from: "2026-11-24 120000")!
        var removed = Past.prune(root, keepDays: 90, minFree: 0, now: now)
        XCTAssertEqual(removed, ["2025-01-01 000000", "2026-06-01 000000"])
        var calls = 0
        removed = Past.prune(root, keepDays: nil, minFree: 100, now: now, freeSpace: { _ in calls += 1; return calls > 1 ? 1000 : 0 })
        XCTAssertEqual(removed, ["2026-11-20 000000"], "space guard: oldest first, newest kept")
        XCTAssertEqual(Past.prune(root, keepDays: 0, minFree: .max, now: now), [], "the newest is never removed")
        XCTAssertEqual(Past.list(root).map(\.files), [1])
    }

    func testCustomFolderIconsSurviveTheBackup() throws {
        write("Photos/a.jpg", "a")
        let iconFile = src + "/Photos/Icon\r"
        FileManager.default.createFile(atPath: iconFile, contents: Data())
        let fork = [UInt8](repeating: 9, count: 512)
        XCTAssertEqual(setxattr(iconFile, XATTR_RESOURCEFORK_NAME, fork, fork.count, 0, 0), 0)
        var info = [UInt8](repeating: 0, count: 32); info[8] = 0x04   // kHasCustomIcon
        XCTAssertEqual(setxattr(src + "/Photos", XATTR_FINDERINFO_NAME, info, info.count, 0, 0), 0)
        XCTAssertEqual(try backup().problems, [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: dst + "/Photos/Icon\r"), "the icon file is copied")
        XCTAssertEqual(xattrs(dst + "/Photos/Icon\r")[XATTR_RESOURCEFORK_NAME], fork, "with the icon in its resource fork")
        XCTAssertEqual(xattrs(dst + "/Photos")[XATTR_FINDERINFO_NAME]?[8], 0x04, "and the folder still says it has a custom icon")
    }

    func testBuildOutputIsLeftOutOnlyBesideItsProjectFile() throws {
        write("rust/Cargo.toml", "x")
        write("rust/target/debug/big.bin", "b")
        write("essay/target/goal.txt", "keep")   // a folder named target that is someone's work
        var o = Options()
        o.patterns = ["target@Cargo.toml"]
        _ = try backup(o)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dst + "/rust/target"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dst + "/rust/Cargo.toml"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dst + "/essay/target/goal.txt"))
    }

    func testStopDuringTheScanWritesNothingAndArchivesNothing() throws {
        for i in 0..<50 { write("d\(i)/f.txt", "x") }
        _ = try backup()
        let e = Engine(source: src, destination: dst, options: Options())
        e.stop()   // stopped before the scan begins: the scan ends at once
        let r = try e.run()
        XCTAssertTrue(r.stopped)
        XCTAssertEqual(r.retired, 0, "a cut-short scan must not make the rest look deleted")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dst + "/d49/f.txt"))
    }

    func testRelativePathsFinish() throws {
        write("a.txt", "a")
        let cwd = FileManager.default.currentDirectoryPath
        FileManager.default.changeCurrentDirectoryPath(testRoot)
        defer { FileManager.default.changeCurrentDirectoryPath(cwd) }
        let rel = { (p: String) in String(p.dropFirst(testRoot.count + 1)) }
        let r = try Engine(source: rel(src), destination: rel(dst) + "/rel", options: Options()).run()   // looped forever before
        XCTAssertEqual(r.copied, 1)
    }

    func testWhatADeadRunWroteIsCopiedAgain() throws {
        write("a.txt", "good")
        write("b.txt", "good")
        _ = try backup()
        sleep(3)   // the dead run starts later than the good backup
        // A run that died: its lock is left, and it wrote a.txt half (right size and date, wrong bytes).
        try FileManager.default.createDirectory(atPath: dst + "/.archivist", withIntermediateDirectories: true)
        try "999999\n".write(toFile: dst + "/.archivist/run.lock", atomically: false, encoding: .utf8)
        let h = open(dst + "/a.txt", O_WRONLY); _ = "XXXX".withCString { Darwin.write(h, $0, 4) }; close(h)
        var t = [timespec](repeating: timespec(tv_sec: 1_000_000_000, tv_nsec: 0), count: 2)
        var st = stat(); lstat(src + "/a.txt", &st); t[0] = st.st_mtimespec; t[1] = st.st_mtimespec
        utimensat(AT_FDCWD, dst + "/a.txt", &t, AT_SYMLINK_NOFOLLOW)
        let r = try backup()
        XCTAssertEqual(try String(contentsOfFile: dst + "/a.txt", encoding: .utf8), "good", "the dead run's half file is copied again")
        XCTAssertEqual(r.copied, 1, "only what the dead run touched")
    }

    func testLanesFollowTheMeasurements() {
        XCTAssertEqual(Lanes.choose(source: .ssd, destination: .ssd), Lanes(small: 8, big: 2, together: true, diskOrder: false))
        XCTAssertEqual(Lanes.choose(source: .spinning, destination: .ssd), Lanes(small: 1, big: 1, together: false, diskOrder: true))
        XCTAssertEqual(Lanes.choose(source: .unknown, destination: .ssd).diskOrder, true, "unknown is treated as spinning")
        XCTAssertEqual(Lanes.choose(source: .ssd, destination: .spinning), Lanes(small: 1, big: 1, together: false, diskOrder: false))
        XCTAssertEqual(Lanes.choose(source: .network, destination: .spinning).small, 16, "network rules over a disk behind it")
        XCTAssertEqual(Lanes.choose(source: .ssd, destination: .network).small, 16)
    }
}
