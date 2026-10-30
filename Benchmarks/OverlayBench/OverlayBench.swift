// Measures what the overlays cost sTools in CPU while they're up, as an automated stand-in for the performance
// protocol's "tools off vs on" (spec 9.3). Crosshair, Timer Overlay (counting), NBB Overlay (showing a result) and Window
// Backdrop (a still fill) are real, drawn into real windows on a display far outside every real screen, with a made-up
// Minecraft window, a made-up Ninjabrain Bot (no port is opened), a silent alarm and settings in a temporary folder. No
// permission is asked and nothing shows. Not part of the app.
//
// What it measures is sTools' own CPU (its models, SwiftUI and the layer commits). It can't see the window server's
// compositing, the GPU, or Minecraft's frame rate: those stay with the hand check (F3 frame rate, tools off vs on).
//
//   swift run -c release OverlayBench                     every scenario, 3 rounds of 20 s, each paired with "off"
//   swift run -c release OverlayBench all --seconds 30 --rounds 5
//
// Scenarios: off (the app's run loop and nothing else), crosshair, backdrop (a still fill), timer (counting down, the
// overlay redrawn once a second), nbb (a result on the plate, standing still, as between throws), nbb-updating (a new
// result every second, far faster than a run makes them) and all (the four together). The numbers move by half or more
// with the Mac's load: compare scenarios inside one run, and rerun when the load changes.

import AppKit
import Backdrop
import Crosshair
import Darwin
import Foundation
import NBBOverlay
import STDesign
import STPlatform
import TimerOverlay

// MARK: Measuring

/// The main thread's port, taken on the main thread when the bench starts.
nonisolated(unsafe) var mainThreadPort: mach_port_t = 0

/// The whole process's user plus system CPU time, in seconds.
func processCPUSeconds() -> Double {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    func seconds(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1e6 }
    return seconds(usage.ru_utime) + seconds(usage.ru_stime)
}

/// The main thread's user plus system CPU time, in seconds.
func mainThreadCPUSeconds() -> Double {
    var info = thread_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<thread_basic_info_data_t>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { thread_info(mainThreadPort, thread_flavor_t(THREAD_BASIC_INFO), $0, &count) }
    }
    guard result == KERN_SUCCESS else { return 0 }
    func seconds(_ t: time_value_t) -> Double { Double(t.seconds) + Double(t.microseconds) / 1e6 }
    return seconds(info.user_time) + seconds(info.system_time)
}

func median(_ values: [Double]) -> Double {
    guard !values.isEmpty else { return 0 }
    let sorted = values.sorted()
    return sorted.count % 2 == 1 ? sorted[sorted.count / 2] : (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
}

// MARK: Fakes

/// Ninjabrain Bot's API without Ninjabrain Bot: the stronghold stream sends a result as soon as it opens and, when asked,
/// a new one every second; the others stay open and quiet. Nothing connects anywhere.
struct ScriptedNinjabrainBot: NBBEventSource {
    var updatesEverySecond = false

    func connect(to url: URL) async throws -> AsyncThrowingStream<[UInt8], Error> {
        let updates = updatesEverySecond
        return AsyncThrowingStream { continuation in
            if url.path.hasSuffix("version") {
                continuation.yield(Array(#"{"version":"1.5.2"}"#.utf8))
                continuation.finish()
            } else if url.path.hasSuffix("stronghold/events") {
                continuation.yield(Array("data: \(Self.result(step: 0))\n\n".utf8))
                guard updates else { return }
                let task = Task {
                    var step = 1
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(1))
                        continuation.yield(Array("data: \(Self.result(step: step))\n\n".utf8))
                        step += 1
                    }
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }
    }

    /// Five predictions and three eye throws, the most the default plate shows; `step` changes the numbers.
    static func result(step: Int) -> String {
        let predictions = (0..<5).map { index in
            let certainty = Double(5 - index) / 15 + Double(step % 7) * 0.001
            return #"{"chunkX":\#(12 + index * 3),"chunkZ":\#(-34 + index),"certainty":\#(certainty),"overworldDistance":\#(512.3 + Double(index) * 40)}"#
        }
        let eyeThrows = (0..<3).map { index in
            #"{"xInOverworld":\#(100 + index * 12).0,"zInOverworld":-200.0,"angle":\#(45 + index).0,"angleWithoutCorrection":44.5,"correction":0.5,"correctionIncrements":\#(step % 5),"error":0.01,"type":"NORMAL"}"#
        }
        return #"{"resultType":"TRIANGULATION","predictions":[\#(predictions.joined(separator: ","))],"eyeThrows":[\#(eyeThrows.joined(separator: ","))],"playerPosition":{"xInOverworld":1.0,"zInOverworld":2.0,"horizontalAngle":90.0,"isInOverworld":true,"isInNether":false}}"#
    }
}

/// A prober that grants everything and shows no prompt.
struct GrantsEverything: PermissionProbing {
    func status(for permission: Permission) -> PermissionStatus { .granted }
    func request(_ permission: Permission) async -> PermissionStatus { .granted }
}

@MainActor
final class SilentAlarm: AlarmPlaying {
    var isPlaying: Bool { false }
    var onRenderedBuffer: (@Sendable (AlarmRenderedBuffer) -> Void)?
    func ring(_ sound: URL, volume: Double, schedule: AlarmSchedule, onRing: @escaping @MainActor (Int) -> Void, onEnd: @escaping @MainActor () -> Void) {}
    func playCue(_ cue: AlarmSchedule.Cue, volume: Double) {}
    func preview(_ sound: URL, volume: Double, rings: Int, onEnd: @escaping @MainActor () -> Void) {}
    func stop() {}
}

@MainActor
final class SilentAnnouncer: TimerAnnouncing {
    func announce(_ announcement: TimerAnnouncement) {}
}

// MARK: The rig

enum Scenario: String, CaseIterable {
    case off, crosshair, backdrop, timer, nbb, nbbUpdating = "nbb-updating", all

    var tools: Set<String> {
        switch self {
        case .off: []
        case .crosshair: ["crosshair"]
        case .backdrop: ["backdrop"]
        case .timer: ["timer"]
        case .nbb, .nbbUpdating: ["nbb"]
        case .all: ["crosshair", "backdrop", "timer", "nbb"]
        }
    }
}

/// Four controllers on one off-screen display, switched on as a scenario says.
@MainActor
final class Rig {
    let directory = FileManager.default.temporaryDirectory.appending(path: "sTools-overlay-bench-\(UUID().uuidString)", directoryHint: .isDirectory)
    let crosshair: CrosshairController
    let backdrop: BackdropController
    let nbb: NBBOverlayController
    let timer: TimerOverlayController

    init(updatingNinjabrainBot: Bool) {
        let frame = CGRect(x: -40_000, y: -40_000, width: 1920, height: 1080)
        let display = DisplayInfo(
            id: 1, name: "Off screen", frame: frame, bounds: CGRect(x: frame.minX, y: 1080 - frame.maxY, width: 1920, height: 1080),
            backingScale: 2, pixelSize: CGSize(width: 3840, height: 2160), isMain: true)
        let window = MinecraftWindow(windowNumber: 7_777, processID: 4_242, title: "Minecraft* 1.16.1",
                                     frame: display.bounds.insetBy(dx: 160, dy: 90))
        let minecraft = MinecraftLocator(source: StaticMinecraftWindowSource(instances: [
            MinecraftInstance(window: window, launchDate: Date(), isFrontmost: true, displayID: 1),
        ]))
        minecraft.refresh()
        let services = ToolServices(
            settings: SettingsStore(directory: directory), displays: DisplayDirectory(screenProvider: { [display] }),
            minecraft: minecraft, permissions: PermissionCenter(prober: GrantsEverything(), openURL: { _ in }))
        let theme = STTheme()
        let images = directory.appending(path: "Images", directoryHint: .isDirectory)
        crosshair = CrosshairController(services: services, imagesDirectory: images)
        backdrop = BackdropController(services: services, imagesDirectory: images, theme: theme)
        nbb = NBBOverlayController(
            services: services, connection: NBBConnection(source: ScriptedNinjabrainBot(updatesEverySecond: updatingNinjabrainBot)),
            copies: NBBCopiesMonitor(scanner: NoNBBCopiesScanner()), theme: theme)
        timer = TimerOverlayController(services: services, theme: theme, alarm: SilentAlarm(), announcer: SilentAnnouncer())
    }

    func switchOn(_ tools: Set<String>) {
        if tools.contains("backdrop") { backdrop.setEnabled(true) }
        if tools.contains("crosshair") { crosshair.setEnabled(true) }
        if tools.contains("nbb") { nbb.setEnabled(true) }
        if tools.contains("timer") { timer.start() }
    }

    func switchOff() {
        timer.setEnabled(false)
        nbb.setEnabled(false)
        crosshair.setEnabled(false)
        backdrop.setEnabled(false)
        try? FileManager.default.removeItem(at: directory)
    }
}

// MARK: Running

struct Sample {
    var processMillisecondsPerSecond: [Double]
    var mainThreadMillisecondsPerSecond: [Double]
}

/// Runs `scenario` for `seconds` after a short settle, sampling the CPU once a second.
@MainActor
func run(_ scenario: Scenario, seconds: Int) async -> Sample {
    let rig = Rig(updatingNinjabrainBot: scenario == .nbbUpdating)
    rig.switchOn(scenario.tools)
    try? await Task.sleep(for: .seconds(2))
    var sample = Sample(processMillisecondsPerSecond: [], mainThreadMillisecondsPerSecond: [])
    var process0 = processCPUSeconds(), main0 = mainThreadCPUSeconds()
    var last = ContinuousClock.now
    for _ in 0..<seconds {
        try? await Task.sleep(for: .seconds(1))
        let now = ContinuousClock.now
        let elapsed = Double((now - last).components.seconds) + Double((now - last).components.attoseconds) / 1e18
        last = now
        let (process1, main1) = (processCPUSeconds(), mainThreadCPUSeconds())
        sample.processMillisecondsPerSecond.append((process1 - process0) * 1e3 / elapsed)
        sample.mainThreadMillisecondsPerSecond.append((main1 - main0) * 1e3 / elapsed)
        (process0, main0) = (process1, main1)
    }
    rig.switchOff()
    try? await Task.sleep(for: .milliseconds(500))
    return sample
}

@main
struct OverlayBench {
    @MainActor
    static func main() async {
        mainThreadPort = mach_thread_self()
        NSApplication.shared.setActivationPolicy(.prohibited)
        _ = STFont.register()
        var arguments = Array(CommandLine.arguments.dropFirst())
        func option(_ name: String, default value: Int) -> Int {
            guard let i = arguments.firstIndex(of: name), i + 1 < arguments.count else { return value }
            let parsed = Int(arguments[i + 1]) ?? value
            arguments.removeSubrange(i...i + 1)
            return parsed
        }
        let seconds = option("--seconds", default: 20)
        let rounds = option("--rounds", default: 3)
        let chosen = arguments.first.flatMap(Scenario.init(rawValue:))
        guard arguments.isEmpty || arguments.first == "all" || chosen != nil else {
            print("scenarios: " + Scenario.allCases.map(\.rawValue).joined(separator: ", ") + "; options: --seconds S, --rounds N")
            return
        }
        let scenarios = chosen.map { [$0] } ?? Scenario.allCases.filter { $0 != .off }
        print("OverlayBench: sTools' own CPU in ms per second (1000 ms a second is one whole core), \(seconds) s a run, \(rounds) rounds.")
        print("Every scenario runs between two runs of \"off\"; drawn off-screen with fakes, so the window server's work isn't in it.")
        var medians: [Scenario: [Double]] = [:]
        var mainMedians: [Scenario: [Double]] = [:]
        var worst: [Scenario: Double] = [:]
        for round in 1...rounds {
            for kind in [Scenario.off] + scenarios.flatMap({ [$0, Scenario.off] }) {
                let sample = await run(kind, seconds: seconds)
                medians[kind, default: []].append(median(sample.processMillisecondsPerSecond))
                mainMedians[kind, default: []].append(median(sample.mainThreadMillisecondsPerSecond))
                worst[kind] = max(worst[kind] ?? 0, sample.processMillisecondsPerSecond.max() ?? 0)
            }
            print("round \(round) done")
        }
        let baseline = median(medians[.off] ?? [])
        let mainBaseline = median(mainMedians[.off] ?? [])
        func cell(_ text: String, _ width: Int, left: Bool = false) -> String {
            let padding = String(repeating: " ", count: max(0, width - text.count))
            return left ? text + padding : padding + text
        }
        print(cell("scenario", 14, left: true) + cell("process", 10) + cell("over off", 10) + cell("main thread", 13) + cell("worst 1 s", 11))
        for scenario in [Scenario.off] + scenarios {
            let process = median(medians[scenario] ?? []), main = median(mainMedians[scenario] ?? [])
            let extra = scenario == .off ? "" : String(format: "%+.2f", process - baseline)
            print(cell(scenario.rawValue, 14, left: true) + cell(String(format: "%.2f", process), 10) + cell(extra, 10)
                  + cell(String(format: "%.2f", main), 13) + cell(String(format: "%.2f", worst[scenario] ?? 0), 11))
        }
        print(String(format: "(the median of %d runs of off: %.2f ms/s for the process, %.2f ms/s for the main thread)",
                     medians[.off]?.count ?? 0, baseline, mainBaseline))
    }
}
