import Foundation
import FanGuardCore

// fanguardd: root daemon. Reads GPU temperature from `macmon pipe`, applies the
// curve from /Users/Shared/FanGuard/config.json to all fans through Stats' `smc`
// tool, and writes /Users/Shared/FanGuard/status.json every sample.
// Safety: fans go back to macOS automatic on start, on SIGTERM/SIGINT, when the
// sensor stream stops for 10 s, and whenever the curve says so.

let libexec = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/usr/local/libexec/fanguard"
let macmonPath = "\(libexec)/macmon"
let smcPath = "\(libexec)/smc"
let intervalMS = 2000

let logPath = ProcessInfo.processInfo.environment["FANGUARD_LOG"] ?? "/var/log/fanguard.log"   // override for testing
let logLock = NSLock()
var logDay = ""

/// Moves the log to fanguard.log.1 (replacing the previous one) and points stdout/stderr
/// at a fresh file, so at most two log files ever exist.
func rotateLog() {
    // Only when stderr really is our log file (as under launchd); never when run by hand.
    var a = stat(), b = stat()
    guard fstat(2, &a) == 0, stat(logPath, &b) == 0, a.st_ino == b.st_ino else { return }
    try? FileManager.default.removeItem(atPath: logPath + ".1")
    guard rename(logPath, logPath + ".1") == 0 else { return }
    let fd = open(logPath, O_WRONLY | O_CREAT | O_APPEND, 0o644)
    guard fd >= 0 else { return }
    dup2(fd, 1); dup2(fd, 2); close(fd)
}

func log(_ s: String) {
    logLock.lock(); defer { logLock.unlock() }
    let now = Date()
    let day = DateFormatter(); day.dateFormat = "yyyy-MM-dd"
    let today = day.string(from: now)
    if logDay.isEmpty || today != logDay { rotateLog(); logDay = today }   // first line after start, then daily
    let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"
    FileHandle.standardError.write("\(f.string(from: now)) \(s)\n".data(using: .utf8)!)
}

@discardableResult
func smc(_ args: [String]) -> Bool {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: smcPath)
    p.arguments = args
    let out = Pipe(); p.standardOutput = out; p.standardError = out
    do { try p.run() } catch { log("smc \(args) failed to start: \(error)"); return false }
    p.waitUntilExit()
    let text = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    if text.contains("failed") || text.contains("ERROR") || p.terminationStatus != 0 {
        log("smc \(args.joined(separator: " ")): \(text.trimmingCharacters(in: .whitespacesAndNewlines))")
        return false
    }
    return true
}

final class Controller {
    private let lock = NSLock()
    private var curve = Curve()
    private var held: Double?          // rpm currently forced, nil = automatic
    private var fanCount = 0
    private(set) var lastSample = Date.distantPast

    /// Gives a freshly started sensor stream the full watchdog window.
    func streamStarted() { lock.lock(); lastSample = Date(); lock.unlock() }

    /// `force` also writes when FanGuard is not holding the fans (used at start).
    func toAuto(reason: String, force: Bool = false) {
        lock.lock(); defer { lock.unlock() }
        if held != nil || force { autoLocked(reason: reason) }
    }

    private func autoLocked(reason: String) {
        let n = max(fanCount, 2)
        for f in 0..<n { smc(["fan", "\(f)", "-m", "0"]) }
        smc(["reset"])
        if held != nil { log("fans -> automatic (\(reason))") }
        held = nil
    }

    func handle(sample d: [String: Any]) {
        lock.lock(); defer { lock.unlock() }
        lastSample = Date()
        let temp = ((d["temp"] as? [String: Any])?["gpu_temp_avg"] as? Double) ?? .nan
        let fans = (d["fans"] as? [[String: Any]]) ?? []
        fanCount = fans.count
        let rpms = fans.map { ($0["rpm"] as? Double) ?? Double(($0["rpm"] as? Int) ?? 0) }
        let maxRPM = fans.compactMap { ($0["max_rpm"] as? Double) ?? ($0["max_rpm"] as? Int).map(Double.init) }.min() ?? 3625
        let config = Config.load().sanitized(maxRPM: maxRPM)
        var note = ""
        var want: Double?
        if temp.isFinite && temp > 5 && !fans.isEmpty {
            want = curve.target(temp: temp, config: config, maxRPM: maxRPM, now: Date())
        } else {
            note = "no GPU temperature; fans left to macOS"
            curve = Curve()
        }
        if let w = want {
            let rounded = Swift.min((w / 50).rounded() * 50, maxRPM)
            if held == nil {
                for f in 0..<fans.count { smc(["fan", "\(f)", "-m", "1"]) }
                log("boost on at \(String(format: "%.1f", temp)) C")
            }
            if held == nil || abs(rounded - held!) >= 50 {
                var ok = true
                for f in 0..<fans.count { ok = smc(["fan", "\(f)", "-v", "\(Int(rounded))"]) && ok }
                log("fans -> \(Int(rounded)) rpm (GPU \(String(format: "%.1f", temp)) C)")
                held = rounded
                if !ok { note = "fan write failed" }
            }
        } else if held != nil {
            autoLocked(reason: config.mode == .auto ? "mode auto" : String(format: "GPU %.1f C", temp))
        }
        let busy = (d["gpu_active_ratio"] as? Double) ?? 0
        let mhz = (d["gpu_freq_mhz"] as? Double) ?? Double((d["gpu_freq_mhz"] as? Int) ?? 0)
        if note.isEmpty && busy > 0.9 && mhz > 0 && mhz < 1300 { note = "GPU clock reduced (throttling)" }
        let status = Status(time: Date(), gpuTemp: temp, gpuMHz: mhz, gpuBusy: busy,
                            gpuWatts: (d["gpu_power"] as? Double) ?? 0, fanRPM: rpms, maxRPM: maxRPM,
                            targetRPM: held, mode: config.mode, note: note)
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .secondsSince1970
        if let data = try? enc.encode(status) {
            try? FileManager.default.createDirectory(at: Paths.dir, withIntermediateDirectories: true)
            try? data.write(to: Paths.status, options: .atomic)
            chmod(Paths.status.path, 0o644)
        }
    }
}

let controller = Controller()
var current: Process?

func readerLoop() {
    var failures = 0          // macmon runs that ended without delivering a sample
    var backoff: UInt32 = 3
    while true {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: macmonPath)
        p.arguments = ["pipe", "-i", "\(intervalMS)"]
        let out = Pipe(), err = Pipe()
        p.standardOutput = out; p.standardError = err
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { log("macmon failed to start: \(error)"); sleep(5); continue }
        current = p
        controller.streamStarted()
        var buffer = Data()
        var samples = 0
        let h = out.fileHandleForReading
        while true {
            let chunk = h.availableData
            if chunk.isEmpty {
                // An empty read while macmon still runs is not EOF; give it a moment.
                if p.isRunning { usleep(200_000); if p.isRunning { continue } }
                break
            }
            buffer.append(chunk)
            while let nl = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<nl]
                buffer.removeSubrange(buffer.startIndex...nl)
                if let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] {
                    controller.handle(sample: obj)
                    samples += 1
                }
            }
        }
        controller.toAuto(reason: "sensor stream ended")
        if p.isRunning { kill(p.processIdentifier, SIGKILL) }
        p.waitUntilExit()
        // Close both ends of both pipes so restarts never leak file descriptors.
        for handle in [out.fileHandleForReading, out.fileHandleForWriting,
                       err.fileHandleForWriting] { try? handle.close() }
        let errText = String(data: (try? err.fileHandleForReading.readToEnd()) ?? Data(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        try? err.fileHandleForReading.close()
        let reason = p.terminationReason == .uncaughtSignal ? "signal" : "exit"
        failures = samples == 0 ? failures + 1 : 0
        backoff = samples == 0 ? min(backoff * 2, 30) : 3
        log("macmon ended (\(reason) \(p.terminationStatus), \(samples) samples)"
            + (errText.isEmpty ? "" : ": " + String(errText.suffix(300)))
            + "; restarting in \(backoff) s")
        if failures >= 10 {
            // Repeated failures without data: start over in a fresh process (launchd restarts us).
            log("macmon failed 10 times in a row; restarting fanguardd")
            controller.toAuto(reason: "restarting", force: true)
            exit(1)
        }
        sleep(backoff)
    }
}

// Start from a known state.
try? FileManager.default.createDirectory(at: Paths.dir, withIntermediateDirectories: true)
chmod(Paths.dir.path, 0o777)
if !FileManager.default.fileExists(atPath: Paths.config.path) {
    try? Config().save()
    chmod(Paths.config.path, 0o666)
}
controller.toAuto(reason: "start", force: true)
log("fanguardd started (macmon \(macmonPath), smc \(smcPath))")

var _signalSources: [DispatchSourceSignal] = []
for sig in [SIGTERM, SIGINT, SIGHUP] {
    signal(sig, SIG_IGN)
    let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    src.setEventHandler {
        if let p = current, p.isRunning { kill(p.processIdentifier, SIGKILL) }
        controller.toAuto(reason: "stopping")
        log("stopped")
        exit(0)
    }
    src.resume()
    _signalSources.append(src)
}

// Watchdog: no sample for 10 s -> automatic, and kill macmon so it restarts.
let watchdog = DispatchSource.makeTimerSource(queue: .main)
watchdog.schedule(deadline: .now() + 15, repeating: 5)
watchdog.setEventHandler {
    if Date().timeIntervalSince(controller.lastSample) > 10 {
        controller.toAuto(reason: "no sensor data for 10 s")
        if let p = current, p.isRunning { kill(p.processIdentifier, SIGKILL) }   // a stopped process ignores SIGTERM
    }
}
watchdog.resume()

Thread.detachNewThread { readerLoop() }
dispatchMain()
