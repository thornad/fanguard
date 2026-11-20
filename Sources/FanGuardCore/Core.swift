import Foundation

/// Shared files between the menu bar app (runs as the user) and the root daemon.
/// The daemon only reads numbers from the config and clamps every value, so a
/// user-writable config can at most change fan speeds within the hardware range.
public enum Paths {
    public static let dir = URL(fileURLWithPath: "/Users/Shared/FanGuard")
    public static let config = dir.appendingPathComponent("config.json")
    public static let status = dir.appendingPathComponent("status.json")
}

public enum Override: String, Codable, CaseIterable, Sendable {
    case curve      // follow the temperature curve
    case max        // force full speed
    case auto       // always leave the fans to macOS
}

public struct Config: Codable, Equatable, Sendable {
    /// Below this GPU temperature the fans stay on macOS automatic (until boost engages).
    public var startTemp: Double = 60
    /// Fan speed reached at `midTemp`.
    public var midRPM: Double = 3050
    public var midTemp: Double = 65
    /// Between `midTemp` and this temperature the fans hold `midRPM`; at or above it, full speed.
    public var fullTemp: Double = 90
    /// Once boosted, hand back to macOS only after the GPU stays below this for `holdSeconds`.
    public var releaseTemp: Double = 55
    public var holdSeconds: Double = 30
    public var mode: Override = .curve
    /// Full speed for this many seconds once the GPU is thermally capped (0 = off).
    public var throttleBurstSeconds: Double = 120
    /// The GPU counts as throttled when its CLTM-capped share stays above this percent for `throttleTriggerSeconds`.
    public var throttleCLTMPercent: Double = 5
    public var throttleTriggerSeconds: Double = 6

    public init() {}

    // Decode every field if present, so a config written by an older version keeps its values.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Config()
        startTemp = try c.decodeIfPresent(Double.self, forKey: .startTemp) ?? d.startTemp
        midRPM = try c.decodeIfPresent(Double.self, forKey: .midRPM) ?? d.midRPM
        midTemp = try c.decodeIfPresent(Double.self, forKey: .midTemp) ?? d.midTemp
        fullTemp = try c.decodeIfPresent(Double.self, forKey: .fullTemp) ?? d.fullTemp
        releaseTemp = try c.decodeIfPresent(Double.self, forKey: .releaseTemp) ?? d.releaseTemp
        holdSeconds = try c.decodeIfPresent(Double.self, forKey: .holdSeconds) ?? d.holdSeconds
        mode = try c.decodeIfPresent(Override.self, forKey: .mode) ?? d.mode
        throttleBurstSeconds = try c.decodeIfPresent(Double.self, forKey: .throttleBurstSeconds) ?? d.throttleBurstSeconds
        throttleCLTMPercent = try c.decodeIfPresent(Double.self, forKey: .throttleCLTMPercent) ?? d.throttleCLTMPercent
        throttleTriggerSeconds = try c.decodeIfPresent(Double.self, forKey: .throttleTriggerSeconds) ?? d.throttleTriggerSeconds
    }

    /// Values forced into a sane, ordered range.
    public func sanitized(maxRPM: Double) -> Config {
        var c = self
        let clamp = { (v: Double, lo: Double, hi: Double) in Swift.min(Swift.max(v.isFinite ? v : lo, lo), hi) }
        c.startTemp = clamp(c.startTemp, 40, 90)
        c.midTemp = clamp(c.midTemp, c.startTemp + 1, 95)
        c.fullTemp = clamp(c.fullTemp, c.midTemp, 100)
        c.releaseTemp = clamp(c.releaseTemp, 30, c.startTemp)
        c.holdSeconds = clamp(c.holdSeconds, 0, 600)
        c.midRPM = clamp(c.midRPM, 1000, maxRPM)
        c.throttleBurstSeconds = clamp(c.throttleBurstSeconds, 0, 900)
        c.throttleCLTMPercent = clamp(c.throttleCLTMPercent, 1, 100)
        c.throttleTriggerSeconds = clamp(c.throttleTriggerSeconds, 0, 120)
        return c
    }

    public static func load() -> Config {
        guard let data = try? Data(contentsOf: Paths.config),
              let c = try? JSONDecoder().decode(Config.self, from: data) else { return Config() }
        return c
    }

    public func save() throws {
        try FileManager.default.createDirectory(at: Paths.dir, withIntermediateDirectories: true)
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(self).write(to: Paths.config, options: .atomic)
    }
}

public struct Status: Codable, Sendable {
    public var time: Date
    public var gpuTemp: Double
    public var gpuMHz: Double
    public var gpuBusy: Double
    public var gpuWatts: Double
    public var fanRPM: [Double]
    public var maxRPM: Double
    /// nil = fans on macOS automatic, otherwise the rpm FanGuard is holding.
    public var targetRPM: Double?
    public var mode: Override
    public var note: String
    /// Share of time (%) the GPU's performance states were capped by thermal management (IOReport GPU_CLTM).
    public var cltm: Double?
    /// The GPU's highest clock, for showing the current clock as a percentage.
    public var gpuMaxMHz: Double?
    /// Performance-core cluster clock.
    public var cpuMHz: Double?
    /// Seconds left in a full-speed throttle burst, nil when none is running.
    public var burstRemaining: Double?

    public init(time: Date, gpuTemp: Double, gpuMHz: Double, gpuBusy: Double, gpuWatts: Double,
                fanRPM: [Double], maxRPM: Double, targetRPM: Double?, mode: Override, note: String,
                cltm: Double? = nil, gpuMaxMHz: Double? = nil, cpuMHz: Double? = nil, burstRemaining: Double? = nil) {
        self.time = time; self.gpuTemp = gpuTemp; self.gpuMHz = gpuMHz; self.gpuBusy = gpuBusy
        self.gpuWatts = gpuWatts; self.fanRPM = fanRPM; self.maxRPM = maxRPM
        self.targetRPM = targetRPM; self.mode = mode; self.note = note
        self.cltm = cltm; self.gpuMaxMHz = gpuMaxMHz; self.cpuMHz = cpuMHz; self.burstRemaining = burstRemaining
    }

    public var throttling: Bool { (cltm ?? 0) > 5 }

    public static func load() -> Status? {
        guard let data = try? Data(contentsOf: Paths.status) else { return nil }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .secondsSince1970
        return try? dec.decode(Status.self, from: data)
    }
}

/// Temperature curve with hysteresis. Pure, so it can be tested without hardware.
public struct Curve {
    public private(set) var boosted = false
    private var coolSince: Date?
    private var lastMode: Override?
    /// Highest non-maximum speed reached in the current boost; the fans never drop below it until release.
    private var level = 0.0
    private var atMax = false

    public init() {}

    /// Returns the rpm to hold, or nil to leave the fans on macOS automatic.
    public mutating func target(temp: Double, config c: Config, maxRPM: Double, now: Date) -> Double? {
        if c.mode != lastMode { boosted = false; coolSince = nil; level = 0; atMax = false; lastMode = c.mode }
        switch c.mode {
        case .auto: boosted = false; coolSince = nil; return nil
        case .max: boosted = true; coolSince = nil; return maxRPM
        case .curve: break
        }
        if temp >= c.startTemp { boosted = true; coolSince = nil }
        guard boosted else { return nil }
        if temp < c.releaseTemp {
            if coolSince == nil { coolSince = now }
            if now.timeIntervalSince(coolSince!) >= c.holdSeconds { boosted = false; coolSince = nil; level = 0; atMax = false; return nil }
        } else {
            coolSince = nil
        }
        let floorRPM = 2000.0
        // Full speed from fullTemp; leave it only 2 degrees below, so it does not flip at the edge.
        if temp >= c.fullTemp || (atMax && temp >= c.fullTemp - 2) {
            atMax = true
            return maxRPM
        }
        atMax = false
        let base: Double
        if temp >= c.midTemp {
            base = c.midRPM
        } else if temp >= c.startTemp {
            base = floorRPM + (c.midRPM - floorRPM) * (temp - c.startTemp) / Swift.max(c.midTemp - c.startTemp, 0.1)
        } else {
            base = floorRPM
        }
        // During a boost the speed only ratchets up (to at most midRPM), so short pauses between
        // prompts don't make the fans wind down and up again.
        level = Swift.max(level, Swift.min(base, c.midRPM))
        let rpm = Swift.max(base, level)
        return Swift.min(Swift.max(rpm, 1000), maxRPM)
    }
}

/// Full-speed burst when the GPU is thermally capped: once CLTM stays above the threshold for
/// `throttleTriggerSeconds`, hold full speed for `throttleBurstSeconds`; if it is still capped
/// when the burst ends, the next burst starts at once. Pure, so it can be tested without hardware.
public struct ThrottleBurst {
    private var highSince: Date?
    private var burstUntil: Date?

    public init() {}

    /// Returns the seconds left in the current burst, or nil when no burst is running.
    public mutating func update(cltm: Double?, config c: Config, now: Date) -> Double? {
        guard c.mode == .curve, c.throttleBurstSeconds > 0 else { highSince = nil; burstUntil = nil; return nil }
        if let v = cltm, v > c.throttleCLTMPercent {
            if highSince == nil { highSince = now }
        } else {
            highSince = nil
        }
        let running = burstUntil.map { now < $0 } ?? false
        if !running, let since = highSince, now.timeIntervalSince(since) >= c.throttleTriggerSeconds {
            burstUntil = now.addingTimeInterval(c.throttleBurstSeconds)
            highSince = now   // a new burst needs the full trigger time again once it ends
        }
        guard let until = burstUntil, now < until else { return nil }
        return until.timeIntervalSince(now)
    }
}
