import XCTest
@testable import ArchivistCore

final class DriveMemoryTests: XCTestCase {
    /// Helios's 41-minute run, as a record: the next estimate for the same work comes out at its length.
    func testARememberedRunPredictsTheSameRun() {
        var m = DriveMemory(name: "Deep Time")
        let run = DriveMemory.Run(smallFiles: 99_344, bigMB: 4_400, looking: 60, small: 99_344.0 / 41, big: 4_400.0 / 6, finishing: 70)
        m.add(run)
        let total = run.looking + run.small + run.big + run.finishing
        let guess = m.estimate(smallFiles: 99_344, bigMB: 4_400, defaults: (1.0 / 40, 1.0 / 20))
        XCTAssertEqual(guess, total, accuracy: total * 0.02)
    }

    func testRecentRunsCountMost() {
        var m = DriveMemory(name: "d")
        m.add(.init(smallFiles: 1000, bigMB: 0, looking: 0, small: 100, big: 0, finishing: 0))   // 0.1 s/file, older
        m.add(.init(smallFiles: 1000, bigMB: 0, looking: 0, small: 20, big: 0, finishing: 0))    // 0.02 s/file, newest
        XCTAssertEqual(m.secondsPerSmallFile!, (0.02 * 1 + 0.1 * 0.5) / 1.5, accuracy: 1e-9)
    }

    func testTooLittleWorkTeachesNothingAndTheListIsBounded() {
        var m = DriveMemory(name: "d")
        m.add(.init(smallFiles: 5, bigMB: 3, looking: 1, small: 1, big: 1, finishing: 1))
        XCTAssertNil(m.secondsPerSmallFile)
        XCTAssertNil(m.secondsPerMB)
        for _ in 0..<50 { m.add(.init(smallFiles: 500, bigMB: 0, looking: 0, small: 5, big: 0, finishing: 0)) }
        XCTAssertEqual(m.runs.count, DriveMemory.limit)
    }
}
