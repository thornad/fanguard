import Foundation
import IOKit

/// Reads the GPU's thermal-capping share (IOReport "GPU Stats" / "CLTM-induced GPU Performance States",
/// channel GPU_CLTM) and its highest clock, without root. Adapted from Okle42/cool42 (MIT),
/// Sources/Cool42Core/GPUStats.swift.
final class GPUThrottle {
    private typealias CopyChannelsInGroup = @convention(c) (CFString, CFString?, UInt64, UInt64, UInt64) -> CFMutableDictionary?
    private typealias CreateSubscription = @convention(c) (UnsafeMutableRawPointer?, CFMutableDictionary, UnsafeMutablePointer<Unmanaged<CFMutableDictionary>?>?, UInt64, CFTypeRef?) -> UnsafeMutableRawPointer?
    private typealias CreateSamples = @convention(c) (UnsafeMutableRawPointer, CFMutableDictionary, CFTypeRef?) -> CFDictionary?
    private typealias CreateSamplesDelta = @convention(c) (CFDictionary, CFDictionary, CFTypeRef?) -> CFDictionary?
    private typealias Iterate = @convention(c) (CFDictionary, @convention(block) (CFDictionary) -> Int32) -> Void
    private typealias StateCount = @convention(c) (CFDictionary) -> Int32
    private typealias StateName = @convention(c) (CFDictionary, Int32) -> CFString?
    private typealias StateRes = @convention(c) (CFDictionary, Int32) -> Int64
    private typealias GetName = @convention(c) (CFDictionary) -> CFString?

    private var sub: UnsafeMutableRawPointer?
    private var subbed: Unmanaged<CFMutableDictionary>?
    private var prev: CFDictionary?
    private var createSamples: CreateSamples?
    private var samplesDelta: CreateSamplesDelta?
    private var iterate: Iterate?
    private var stateCount: StateCount?
    private var stateName: StateName?
    private var stateRes: StateRes?
    private var chanName: GetName?
    let maxMHz: Double?

    init() {
        maxMHz = GPUThrottle.freqTable().max()
        guard let lib = dlopen("/usr/lib/libIOReport.dylib", RTLD_NOW) else { return }
        func sym<T>(_ n: String, _ t: T.Type) -> T? { dlsym(lib, n).map { unsafeBitCast($0, to: t) } }
        guard let copy = sym("IOReportCopyChannelsInGroup", CopyChannelsInGroup.self),
              let create = sym("IOReportCreateSubscription", CreateSubscription.self),
              let chans = copy("GPU Stats" as CFString, "CLTM-induced GPU Performance States" as CFString, 0, 0, 0)
        else { return }
        createSamples = sym("IOReportCreateSamples", CreateSamples.self)
        samplesDelta = sym("IOReportCreateSamplesDelta", CreateSamplesDelta.self)
        iterate = sym("IOReportIterate", Iterate.self)
        stateCount = sym("IOReportStateGetCount", StateCount.self)
        stateName = sym("IOReportStateGetNameForIndex", StateName.self)
        stateRes = sym("IOReportStateGetResidency", StateRes.self)
        chanName = sym("IOReportChannelGetChannelName", GetName.self)
        sub = create(nil, chans, &subbed, 0, nil)
        if let sub, let subbed, let cs = createSamples { prev = cs(sub, subbed.takeUnretainedValue(), nil) }
    }

    /// CLTM-capped share (%) since the previous call, nil if IOReport is unavailable.
    func sample() -> Double? {
        guard let sub, let subbed, let cs = createSamples, let sd = samplesDelta, let it = iterate,
              let sc = stateCount, let sn = stateName, let sr = stateRes,
              let cur = cs(sub, subbed.takeUnretainedValue(), nil) else { return nil }
        defer { prev = cur }
        guard let prev, let delta = sd(prev, cur, nil) else { return nil }
        var no = 0.0, total = 0.0
        let cn = chanName
        it(delta) { item in
            guard (cn?(item) as String?) == "GPU_CLTM" else { return 0 }
            for i in 0..<sc(item) {
                let r = Double(sr(item, i)); total += r
                if (sn(item, i) as String?) == "NO_CLTM" { no += r }
            }
            return 0
        }
        return total > 0 ? 100 * (1 - no / total) : nil
    }

    /// GPU clock table from pmgr voltage-states9-sram (Hz, u32 pairs); index 0 is OFF.
    static func freqTable() -> [Double] {
        var it: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleARMIODevice"), &it) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(it) }
        var out: [Double] = []
        while case let s = IOIteratorNext(it), s != 0 {
            defer { IOObjectRelease(s) }
            var nameBuf = [CChar](repeating: 0, count: 128); IORegistryEntryGetName(s, &nameBuf)
            guard String(cString: nameBuf) == "pmgr",
                  let d = IORegistryEntryCreateCFProperty(s, "voltage-states9-sram" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Data else { continue }
            d.withUnsafeBytes { p in for i in stride(from: 0, to: d.count - 7, by: 8) { out.append(Double(p.load(fromByteOffset: i, as: UInt32.self)) / 1_000_000) } }
            break
        }
        return out
    }
}
