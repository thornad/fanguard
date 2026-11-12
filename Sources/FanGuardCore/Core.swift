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

    public init() {}

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

    public init(time: Date, gpuTemp: Double, gpuMHz: Double, gpuBusy: Double, gpuWatts: Double,
                fanRPM: [Double], maxRPM: Double, targetRPM: Double?, mode: Override, note: String) {
        self.time = time; self.gpuTemp = gpuTemp; self.gpuMHz = gpuMHz; self.gpuBusy = gpuBusy
        self.gpuWatts = gpuWatts; self.fanRPM = fanRPM; self.maxRPM = maxRPM
        self.targetRPM = targetRPM; self.mode = mode; self.note = note
    }

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
