import SwiftUI
import FanGuardCore

@main
struct FanGuardApp: App {
    @StateObject private var model = Model()

    var body: some Scene {
        MenuBarExtra {
            PanelView().environmentObject(model)
        } label: {
            HStack(spacing: 3) {
                Image(systemName: model.iconName)
                Text(model.menuText).monospacedDigit()
            }
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class Model: ObservableObject {
    @Published var status: Status?
    @Published var config: Config = Config.load() { didSet { scheduleSave() } }
    @Published var saveError: String?
    private var timer: Timer?
    private var saveWork: DispatchWorkItem?

    init() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    var daemonAlive: Bool {
        guard let s = status else { return false }
        return Date().timeIntervalSince(s.time) < 10
    }

    var boosting: Bool { daemonAlive && status?.targetRPM != nil }

    var iconName: String {
        if !daemonAlive { return "exclamationmark.triangle" }
        if status?.note.contains("throttling") == true { return "flame" }
        return boosting ? "fan.fill" : "fan"
    }

    /// Shown in the menu bar next to the temperature; a per-user preference of the app only.
    @Published var showFanInMenuBar: Bool = UserDefaults.standard.object(forKey: "showFanInMenuBar") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showFanInMenuBar, forKey: "showFanInMenuBar") }
    }

    var menuText: String {
        guard daemonAlive, let s = status, s.gpuTemp.isFinite else { return "--" }
        let temp = "\(Int(s.gpuTemp.rounded()))°"
        guard showFanInMenuBar, !s.fanRPM.isEmpty else { return temp }
        let rpm = s.fanRPM.reduce(0, +) / Double(s.fanRPM.count)
        return temp + " " + String(format: "%.1fk", rpm / 1000)
    }

    func refresh() {
        status = Status.load()
        // Pick up edits made outside the app, unless a save of our own is still pending.
        if saveWork == nil || saveWork!.isCancelled || pendingSaveDone {
            let disk = Config.load()
            if disk != config { applyingExternal = true; config = disk; applyingExternal = false }
        }
    }
    private var applyingExternal = false
    private var pendingSaveDone = true

    private func scheduleSave() {
        if applyingExternal { return }
        saveWork?.cancel()
        pendingSaveDone = false
        let snapshot = config
        let work = DispatchWorkItem { [weak self] in
            do { try snapshot.save(); Task { @MainActor in self?.saveError = nil; self?.pendingSaveDone = true } }
            catch { Task { @MainActor in self?.saveError = "Could not save settings: \(error.localizedDescription)"; self?.pendingSaveDone = true } }
        }
        saveWork = work
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    func resetDefaults() {
        let mode = config.mode
        config = Config()
        config.mode = mode
    }
}

struct PanelView: View {
    @EnvironmentObject var model: Model

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            Picker("Mode", selection: $model.config.mode) {
                Text("Curve").tag(Override.curve)
                Text("Max").tag(Override.max)
                Text("macOS").tag(Override.auto)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            settings
                .disabled(model.config.mode != .curve)
                .opacity(model.config.mode == .curve ? 1 : 0.45)
            if let e = model.saveError { Text(e).font(.caption).foregroundStyle(.red) }
            Toggle("Show fan speed in the menu bar", isOn: $model.showFanInMenuBar)
                .font(.callout)
            Divider()
            HStack {
                Button("Defaults") { model.resetDefaults() }
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
            }
            Text("Quitting this app does not stop fan control; the background service keeps running with these settings.")
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(width: 320)
    }

    @ViewBuilder private var header: some View {
        if model.daemonAlive, let s = model.status {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("GPU \(fmt(s.gpuTemp)) °C").font(.title2.weight(.semibold)).monospacedDigit()
                    Spacer()
                    Text(model.boosting ? "FanGuard \(Int(s.targetRPM ?? 0)) rpm" : "macOS auto")
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(model.boosting ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.15),
                                    in: Capsule())
                }
                Text("\(Int(s.gpuMHz)) MHz · \(Int(s.gpuBusy * 100))% busy · \(Int(s.gpuWatts)) W")
                    .font(.callout).foregroundStyle(.secondary).monospacedDigit()
                Text("Fans " + s.fanRPM.map { "\(Int($0))" }.joined(separator: " / ") + " of \(Int(s.maxRPM)) rpm")
                    .font(.callout).foregroundStyle(.secondary).monospacedDigit()
                if !s.note.isEmpty {
                    Label(s.note, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
        } else {
            Label("Background service not running", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text("Install it with: sudo ./install.sh (in the fanguard folder)")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 8) {
            row("Boost from", value: $model.config.startTemp, range: 45...85, unit: "°C",
                help: "Take over from macOS at this GPU temperature")
            row("Reach", value: $model.config.midRPM, range: 2000...(model.status?.maxRPM ?? 3625), step: 50,
                unit: "rpm", help: "Fan speed reached at the next temperature, then held")
            row("…at", value: $model.config.midTemp, range: 50...90, unit: "°C", help: "")
            row("Full speed from", value: $model.config.fullTemp, range: 55...95, unit: "°C",
                help: "Below this the fans hold the speed above; from here on, maximum")
            row("Back to macOS below", value: $model.config.releaseTemp, range: 35...80, unit: "°C",
                help: "Hand back once the GPU stays below this")
            row("…for", value: $model.config.holdSeconds, range: 0...300, step: 5, unit: "s", help: "")
        }
    }

    private func row(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double = 1,
                     unit: String, help: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text("\(Int(value.wrappedValue)) \(unit)").monospacedDigit().foregroundStyle(.secondary)
            }
            .font(.callout)
            Slider(value: value, in: range, step: step)
                .controlSize(.small)
                .help(help)
        }
    }

    private func fmt(_ v: Double) -> String { v.isFinite ? String(format: "%.0f", v) : "--" }
}
