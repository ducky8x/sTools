// Measures what watching Ninjabrain Bot costs the NBB Overlay, on this Mac's real process table and, if asked, a real
// Ninjabrain Bot window. It only reads: nothing is changed or quit, no window shows, and no permission is asked (the
// window read runs only when Accessibility is already allowed). It prints timings and counts, never what it read. Not
// part of the app.
//
//   swift run -c release NBBBench                      scan: ms per LiveNBBCopiesScanner().scan()
//   swift run -c release NBBBench monitor --seconds 10 the main thread's time per second while NBBCopiesMonitor watches
//   swift run -c release NBBBench window --seconds 10  ms per read of a copy's window, for a copy without the API

import ApplicationServices
import Darwin
import Foundation
import NBBOverlay

// MARK: Measuring

/// The main thread's port, taken on the main thread when the bench starts.
nonisolated(unsafe) var mainThreadPort: mach_port_t = 0

/// The main thread's user plus system CPU time, in seconds.
func mainThreadCPUSeconds() -> Double {
    let port = mainThreadPort
    var info = thread_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<thread_basic_info_data_t>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { thread_info(port, thread_flavor_t(THREAD_BASIC_INFO), $0, &count) }
    }
    guard result == KERN_SUCCESS else { return 0 }
    func seconds(_ t: time_value_t) -> Double { Double(t.seconds) + Double(t.microseconds) / 1e6 }
    return seconds(info.user_time) + seconds(info.system_time)
}

func milliseconds(since start: ContinuousClock.Instant) -> Double {
    let elapsed = ContinuousClock.now - start
    return Double(elapsed.components.seconds) * 1e3 + Double(elapsed.components.attoseconds) / 1e15
}

func percentile(_ values: [Double], _ p: Double) -> Double {
    guard !values.isEmpty else { return 0 }
    let sorted = values.sorted()
    return sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * p))]
}

func summary(_ values: [Double]) -> String {
    let mean = values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
    return String(format: "mean %.3f  median %.3f  p95 %.3f  min %.3f  max %.3f ms (%d runs)",
                  mean, percentile(values, 0.5), percentile(values, 0.95), values.min() ?? 0, values.max() ?? 0, values.count)
}

/// Times every scan and says whether it ran on the main thread.
final class TimingScanner: NBBCopiesScanning, @unchecked Sendable {
    private let inner = LiveNBBCopiesScanner()
    private let lock = NSLock()
    private var onMain: [Double] = []
    private var offMain: [Double] = []

    func scan() -> [NBBCopy] {
        let start = ContinuousClock.now
        let found = inner.scan()
        let ms = milliseconds(since: start)
        let main = Thread.isMainThread
        lock.withLock { if main { onMain.append(ms) } else { offMain.append(ms) } }
        return found
    }

    var results: (onMain: [Double], offMain: [Double]) { lock.withLock { (onMain, offMain) } }
}

// MARK: Modes

func scanMode(runs: Int) {
    let scanner = LiveNBBCopiesScanner()
    _ = scanner.scan()
    var times: [Double] = []
    var found = 0
    for _ in 0..<runs {
        let start = ContinuousClock.now
        found = scanner.scan().count
        times.append(milliseconds(since: start))
    }
    print("scan: \(summary(times)); \(found) copies found")
}

@MainActor
func monitorMode(seconds: Double) async {
    let scanner = TimingScanner()
    let monitor = NBBCopiesMonitor(scanner: scanner)
    let cpu0 = mainThreadCPUSeconds(), start = ContinuousClock.now
    monitor.start()
    try? await Task.sleep(for: .seconds(seconds))
    monitor.stop()
    let wall = milliseconds(since: start) / 1e3
    let cpu = (mainThreadCPUSeconds() - cpu0) * 1e3 / wall
    let (onMain, offMain) = scanner.results
    print(String(format: "monitor: main thread CPU %.2f ms/s over %.1f s", cpu, wall))
    print(String(format: "  scans on the main thread: %d, %.2f ms/s", onMain.count, onMain.reduce(0, +) / wall))
    print(String(format: "  scans off the main thread: %d, %.2f ms/s", offMain.count, offMain.reduce(0, +) / wall))
}

@MainActor
func windowMode(seconds: Double) async {
    guard AXIsProcessTrusted() else {
        print("window: Accessibility isn't allowed for this process; nothing read")
        return
    }
    guard let copy = LiveNBBCopiesScanner().scan().last(where: { !$0.holdsAPI }) else {
        print("window: no Ninjabrain Bot without the API is open; nothing read")
        return
    }
    let reader = AXNBBWindowReader()
    var times: [Double] = []
    var unread = 0
    let cpu0 = mainThreadCPUSeconds(), start = ContinuousClock.now
    while milliseconds(since: start) < seconds * 1e3 {
        let readStart = ContinuousClock.now
        if reader.read(pid: copy.pid) == nil { unread += 1 }
        times.append(milliseconds(since: readStart))
        try? await Task.sleep(for: .milliseconds(500))
    }
    let wall = milliseconds(since: start) / 1e3
    print("window: \(summary(times)); \(unread) reads found nothing")
    print(String(format: "  main actor in reads %.2f ms/s, main thread CPU %.2f ms/s over %.1f s",
                 times.reduce(0, +) / wall, (mainThreadCPUSeconds() - cpu0) * 1e3 / wall, wall))
}

// MARK: Main

@main
struct NBBBench {
    @MainActor
    static func main() async {
        mainThreadPort = mach_thread_self()
        var arguments = Array(CommandLine.arguments.dropFirst())
        var seconds = 10.0
        if let i = arguments.firstIndex(of: "--seconds"), i + 1 < arguments.count {
            seconds = Double(arguments[i + 1]) ?? seconds
            arguments.removeSubrange(i...i + 1)
        }
        var runs = 40
        if let i = arguments.firstIndex(of: "--runs"), i + 1 < arguments.count {
            runs = Int(arguments[i + 1]) ?? runs
            arguments.removeSubrange(i...i + 1)
        }
        switch arguments.first ?? "scan" {
        case "scan": scanMode(runs: runs)
        case "monitor": await monitorMode(seconds: seconds)
        case "window": await windowMode(seconds: seconds)
        default: print("modes: scan [--runs N], monitor [--seconds S], window [--seconds S]")
        }
    }
}
