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

    func testThrottleBurst() {
        var b = ThrottleBurst(); var c = Config(); c.mode = .curve
        let t = Date()
        XCTAssertNil(b.update(cltm: 0, config: c, now: t))
        XCTAssertNil(b.update(cltm: 80, config: c, now: t.addingTimeInterval(1)))          // just started
        XCTAssertNil(b.update(cltm: 90, config: c, now: t.addingTimeInterval(6)))          // 5 s high: not yet
        XCTAssertEqual(b.update(cltm: 95, config: c, now: t.addingTimeInterval(7))!, 120, accuracy: 0.1)  // 6 s: burst
        XCTAssertEqual(b.update(cltm: 0, config: c, now: t.addingTimeInterval(67))!, 60, accuracy: 0.1)   // runs its course
        XCTAssertNil(b.update(cltm: 0, config: c, now: t.addingTimeInterval(128)))         // over, cool
        // still capped when a burst ends: the next one follows at once (no drop to the curve in between)
        var d = ThrottleBurst()
        _ = d.update(cltm: 90, config: c, now: t); _ = d.update(cltm: 90, config: c, now: t.addingTimeInterval(6))
        XCTAssertEqual(d.update(cltm: 90, config: c, now: t.addingTimeInterval(126))!, 120, accuracy: 0.1)
        // throttling cleared during the burst and came back later: a new burst after the trigger time
        var g = ThrottleBurst()
        _ = g.update(cltm: 90, config: c, now: t); _ = g.update(cltm: 90, config: c, now: t.addingTimeInterval(6))
        _ = g.update(cltm: 0, config: c, now: t.addingTimeInterval(60))
        XCTAssertNil(g.update(cltm: 0, config: c, now: t.addingTimeInterval(130)))
        _ = g.update(cltm: 90, config: c, now: t.addingTimeInterval(200))
        XCTAssertNil(g.update(cltm: 90, config: c, now: t.addingTimeInterval(204)))
        XCTAssertNotNil(g.update(cltm: 90, config: c, now: t.addingTimeInterval(206)))
        // off when 0 s or not in curve mode
        var e = ThrottleBurst(); var off = c; off.throttleBurstSeconds = 0
        _ = e.update(cltm: 99, config: off, now: t); XCTAssertNil(e.update(cltm: 99, config: off, now: t.addingTimeInterval(10)))
        var m = c; m.mode = .auto; var f = ThrottleBurst()
        _ = f.update(cltm: 99, config: m, now: t); XCTAssertNil(f.update(cltm: 99, config: m, now: t.addingTimeInterval(10)))
    }

    func testOldConfigKeepsValues() throws {
        let old = #"{"fullTemp":90,"holdSeconds":30,"midRPM":2800,"midTemp":65,"mode":"curve","releaseTemp":55,"startTemp":60}"#
        let c = try JSONDecoder().decode(Config.self, from: Data(old.utf8))
        XCTAssertEqual(c.midRPM, 2800); XCTAssertEqual(c.mode, .curve)
        XCTAssertEqual(c.throttleBurstSeconds, 120); XCTAssertEqual(c.throttleCLTMPercent, 5)
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
