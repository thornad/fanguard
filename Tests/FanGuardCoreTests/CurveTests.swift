import XCTest
@testable import FanGuardCore

final class CurveTests: XCTestCase {
    let max = 3625.0
    // Fixed test curve, independent of the shipped defaults.
    var c: Config = {
        var x = Config(); x.startTemp = 60; x.midTemp = 72; x.fullTemp = 76; x.releaseTemp = 58; x.midRPM = 3200
        return x
    }()

    func testShippedDefaults() {
        let d = Config()
        XCTAssertEqual([d.startTemp, d.midRPM, d.midTemp, d.fullTemp, d.releaseTemp, d.holdSeconds], [60, 3050, 65, 90, 55, 30])
    }

    func testStaysAutoBelowStart() {
        var k = Curve()
        XCTAssertNil(k.target(temp: 55, config: c, maxRPM: max, now: Date()))
    }

    func testRampAndFull() {
        var k = Curve(); let t = Date()
        XCTAssertEqual(k.target(temp: 60, config: c, maxRPM: max, now: t)!, 2000, accuracy: 1)
        XCTAssertEqual(k.target(temp: 72, config: c, maxRPM: max, now: t)!, 3200, accuracy: 1)
        XCTAssertEqual(k.target(temp: 75.9, config: c, maxRPM: max, now: t)!, 3200, accuracy: 1)   // held, not ramped
        XCTAssertEqual(k.target(temp: 76, config: c, maxRPM: max, now: t)!, max, accuracy: 1)
        XCTAssertEqual(k.target(temp: 90, config: c, maxRPM: max, now: t)!, max, accuracy: 1)
    }

    func testHysteresisRelease() {
        var k = Curve(); let t = Date()
        _ = k.target(temp: 70, config: c, maxRPM: max, now: t)
        // between release and start: still boosted, holds the level reached (70 C -> on the ramp)
        XCTAssertEqual(k.target(temp: 59, config: c, maxRPM: max, now: t)!, 2000 + 1200 * 10 / 12, accuracy: 1)
        // below release but not long enough
        XCTAssertNotNil(k.target(temp: 50, config: c, maxRPM: max, now: t))
        XCTAssertNotNil(k.target(temp: 50, config: c, maxRPM: max, now: t.addingTimeInterval(29)))
        // after hold time
        XCTAssertNil(k.target(temp: 50, config: c, maxRPM: max, now: t.addingTimeInterval(31)))
    }

    func testWarmingResetsHold() {
        var k = Curve(); let t = Date()
        _ = k.target(temp: 70, config: c, maxRPM: max, now: t)
        _ = k.target(temp: 50, config: c, maxRPM: max, now: t)
        _ = k.target(temp: 59, config: c, maxRPM: max, now: t.addingTimeInterval(20))
        XCTAssertNotNil(k.target(temp: 50, config: c, maxRPM: max, now: t.addingTimeInterval(40)))
    }

    func testModes() {
        var k = Curve(); var m = c
        m.mode = .max; XCTAssertEqual(k.target(temp: 40, config: m, maxRPM: max, now: Date()), max)
        m.mode = .auto; XCTAssertNil(k.target(temp: 95, config: m, maxRPM: max, now: Date()))
    }

    func testLeavingMaxStartsCurveFresh() {
        var k = Curve(); var m = c; let t = Date()
        m.mode = .max; _ = k.target(temp: 45, config: m, maxRPM: max, now: t)
        m.mode = .curve; XCTAssertNil(k.target(temp: 45, config: m, maxRPM: max, now: t))
    }

    func testRatchetHoldsSpeedThroughPauses() {
        var k = Curve(); let t = Date()
        XCTAssertEqual(k.target(temp: 73, config: c, maxRPM: max, now: t)!, 3200, accuracy: 1)
        XCTAssertEqual(k.target(temp: 61, config: c, maxRPM: max, now: t)!, 3200, accuracy: 1)   // pause: no drop
        XCTAssertEqual(k.target(temp: 77, config: c, maxRPM: max, now: t)!, max, accuracy: 1)    // full speed
        XCTAssertEqual(k.target(temp: 75, config: c, maxRPM: max, now: t)!, max, accuracy: 1)    // within 2 C: stay
        XCTAssertEqual(k.target(temp: 73, config: c, maxRPM: max, now: t)!, 3200, accuracy: 1)   // back to the held level
        XCTAssertEqual(k.target(temp: 50, config: c, maxRPM: max, now: t.addingTimeInterval(1))!, 3200, accuracy: 1) // cooling: held during the 30 s wait
        XCTAssertNil(k.target(temp: 50, config: c, maxRPM: max, now: t.addingTimeInterval(40)))  // released after hold
        XCTAssertEqual(k.target(temp: 61, config: c, maxRPM: max, now: t.addingTimeInterval(41))!, 2100, accuracy: 1) // new boost starts low
    }

    func testSanitize() {
        var bad = Config(); bad.startTemp = 200; bad.midRPM = 99999; bad.releaseTemp = 99; bad.fullTemp = -5
        let s = bad.sanitized(maxRPM: max)
        XCTAssertLessThanOrEqual(s.midRPM, max)
        XCTAssertLessThanOrEqual(s.releaseTemp, s.startTemp)
        XCTAssertGreaterThanOrEqual(s.fullTemp, s.midTemp)
        XCTAssertGreaterThan(s.midTemp, s.startTemp)
    }
}
