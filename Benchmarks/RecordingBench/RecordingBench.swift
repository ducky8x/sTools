// Measures what a Screen Recording costs the process, with fake sources: no permission is asked, nothing shows on
// screen, and the files go to a temporary folder that's removed after. Not part of the app.
//
//   swift run -c release RecordingBench                 every scenario, at 1920 x 1080 and 3840 x 2160
//   swift run -c release RecordingBench record 3840x2160 --seconds 10
//
// Scenarios: record (Minecraft's picture changing every frame), still (Minecraft's picture standing still, as
// ScreenCaptureKit then sends no new frames), empty (no picture at all, as with Minecraft closed), pip (Minecraft plus
// a 30 fps camera in a corner with rounded corners and a border), armed (the sources running, no recording).

import AVFoundation
import CoreMedia
import CoreVideo
import Darwin
import Foundation
import os
import ScreenRecording
import STPlatform

// MARK: Fake sources

/// A source that delivers prepared frames at a fixed rate on its own queue, as ScreenCaptureKit or a camera does. The
/// frames are filled before the measurement starts, so the source itself costs almost nothing per frame.
final class BenchVideoSource: VideoCapture, @unchecked Sendable {
    private let frames: [CVPixelBuffer]
    private let framesPerSecond: Int
    /// Delivers only the first frame, as a stream whose content stands still.
    private let deliversOnce: Bool
    private let queue = DispatchQueue(label: "bench.source", qos: .userInteractive)
    private let handler = HandlerSlot<VideoCaptureEvent>()
    private let timer = OSAllocatedUnfairLock<DispatchSourceTimer?>(uncheckedState: nil)
    private let next = OSAllocatedUnfairLock(initialState: 0)

    init(size: PixelSize, pixelFormat: OSType, framesPerSecond: Int, deliversOnce: Bool = false) {
        frames = (0..<12).map { BenchVideoSource.makeFrame(size: size, pixelFormat: pixelFormat, index: $0) }
        self.framesPerSecond = framesPerSecond
        self.deliversOnce = deliversOnce
    }

    func start(deliver: @escaping @Sendable (VideoCaptureEvent) -> Void) async throws {
        handler.set(deliver)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .nanoseconds(1_000_000_000 / framesPerSecond), leeway: .microseconds(500))
        timer.setEventHandler { [weak self] in self?.deliverNext() }
        self.timer.withLock { $0 = timer }
        timer.resume()
    }

    func stop() async {
        timer.withLock { $0?.cancel(); $0 = nil }
        _ = handler.clear()
    }

    private func deliverNext() {
        let index = next.withLock { value -> Int? in
            if deliversOnce, value > 0 { return nil }
            defer { value += 1 }
            return value
        }
        guard let index else { return }
        let frame = VideoFrame(pixelBuffer: frames[index % frames.count], hostTime: CMClockGetTime(CMClockGetHostTimeClock()))
        handler(.frame(frame))
    }

    /// An IOSurface-backed frame (as ScreenCaptureKit's are) with a pattern that moves from frame to frame, so the
    /// encoder has real work.
    static func makeFrame(size: PixelSize, pixelFormat: OSType, index: Int) -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attributes: [String: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        CVPixelBufferCreate(nil, size.width, size.height, pixelFormat, attributes as CFDictionary, &buffer)
        guard let buffer else { fatalError("could not make a \(size.width) x \(size.height) frame") }
        CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_sRGB, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let planes = max(1, CVPixelBufferGetPlaneCount(buffer))
        for plane in 0..<planes {
            let isPlanar = CVPixelBufferIsPlanar(buffer)
            guard let base = isPlanar ? CVPixelBufferGetBaseAddressOfPlane(buffer, plane) : CVPixelBufferGetBaseAddress(buffer) else { continue }
            let rowBytes = isPlanar ? CVPixelBufferGetBytesPerRowOfPlane(buffer, plane) : CVPixelBufferGetBytesPerRow(buffer)
            let rows = isPlanar ? CVPixelBufferGetHeightOfPlane(buffer, plane) : CVPixelBufferGetHeight(buffer)
            let bytes = base.assumingMemoryBound(to: UInt8.self)
            for y in 0..<rows {
                let row = bytes + y * rowBytes
                for x in 0..<rowBytes {
                    // Diagonal bands that shift with the frame, plus a little texture.
                    row[x] = pixelFormat == kCVPixelFormatType_32BGRA && x % 4 == 3 ? 255 : UInt8(truncatingIfNeeded: (x + y + index * 24) / 3 &+ ((x * 7) ^ (y * 13)) & 0x0F)
                }
            }
        }
        return buffer
    }
}

/// Minecraft's sound: 10 ms chunks of a tone, as a process tap delivers.
final class BenchAudioSource: AudioCapture, @unchecked Sendable {
    private let queue = DispatchQueue(label: "bench.audio", qos: .userInteractive)
    private let handler = HandlerSlot<AudioChunk>()
    private let timer = OSAllocatedUnfairLock<DispatchSourceTimer?>(uncheckedState: nil)
    private let samples: [Float] = (0..<480).flatMap { i -> [Float] in
        let v = Float(sin(Double(i) * 2 * .pi * 440 / 48_000) * 0.2)
        return [v, v]
    }

    func start(deliver: @escaping @Sendable (AudioChunk) -> Void) async throws {
        handler.set(deliver)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(10), leeway: .microseconds(500))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let start = CMTimeSubtract(CMClockGetTime(CMClockGetHostTimeClock()), CMTime(value: 480, timescale: 48_000))
            self.handler(AudioChunk(samples: self.samples, sampleRate: 48_000, channelCount: 2, hostTime: start))
        }
        self.timer.withLock { $0 = timer }
        timer.resume()
    }

    func stop() async {
        timer.withLock { $0?.cancel(); $0 = nil }
        _ = handler.clear()
    }
}

// MARK: Measuring

/// The real frame timer, with each tick's wall and thread CPU time recorded.
final class TimedTickDriver: TickDriver, @unchecked Sendable {
    private let inner = DispatchTickDriver(queue: DispatchQueue(label: "sTools.recording.frames", qos: .userInteractive))
    private let samples = OSAllocatedUnfairLock(initialState: (wall: [Double](), cpu: [Double]()))
    private let measuring = OSAllocatedUnfairLock(initialState: false)

    func start(interval: Double, handler: @escaping @Sendable () -> Void) {
        inner.start(interval: interval) { [weak self] in
            let wall0 = DispatchTime.now().uptimeNanoseconds
            let cpu0 = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
            handler()
            let cpu = Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - cpu0) / 1e6
            let wall = Double(DispatchTime.now().uptimeNanoseconds - wall0) / 1e6
            guard let self, self.measuring.withLock({ $0 }) else { return }
            self.samples.withLock { $0.wall.append(wall); $0.cpu.append(cpu) }
        }
    }

    func stop() { inner.stop() }

    func beginMeasuring() { measuring.withLock { $0 = true } }

    var results: (wall: [Double], cpu: [Double]) { samples.withLock { $0 } }
}

/// The process's user plus system CPU time, in seconds.
func processCPUSeconds() -> Double {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    func seconds(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1e6 }
    return seconds(usage.ru_utime) + seconds(usage.ru_stime)
}

func percentile(_ values: [Double], _ p: Double) -> Double {
    guard !values.isEmpty else { return 0 }
    let sorted = values.sorted()
    return sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * p))]
}

func mean(_ values: [Double]) -> Double { values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count) }

// MARK: Scenarios

enum Scenario: String, CaseIterable {
    case record, still, empty, pip, armed
}

struct Result {
    var scenario: Scenario
    var canvas: PixelSize
    var cpuPercent: Double
    var tickWallMean = 0.0, tickWallP95 = 0.0, tickCPUMean = 0.0
    var framesWritten = 0, dropped = 0
    var colorTags = ""
}

/// The color tags of a movie's video track and the first frame's attachments, to check that a change keeps the file's
/// color the same.
func colorTags(of url: URL) async -> String {
    let asset = AVURLAsset(url: url)
    guard let track = try? await asset.loadTracks(withMediaType: .video).first,
          let description = try? await track.load(.formatDescriptions).first else { return "no video" }
    let extensions = CMFormatDescriptionGetExtensions(description) as? [String: Any] ?? [:]
    let keys = [kCVImageBufferColorPrimariesKey, kCVImageBufferTransferFunctionKey, kCVImageBufferYCbCrMatrixKey] as [CFString]
    let tags = keys.map { "\(extensions[$0 as String] ?? "none")" }
    let range = (extensions["FullRangeVideo"] as? Bool) == true ? "full" : "video"
    return tags.joined(separator: "/") + " \(range) range"
}

/// The default layout, or one with a camera in the bottom-right corner.
func layout(for scenario: Scenario, cameraID: UUID, canvas: PixelSize) -> RecordingLayout {
    var layout = RecordingLayout()
    if scenario == .pip {
        let width = Double(canvas.width) * 0.25, height = width * 9 / 16
        layout.add(VideoSource(
            id: cameraID, kind: .camera(CameraReference(uniqueID: "bench", name: "Camera")),
            frame: PixelRect(x: Double(canvas.width) - width - 40, y: Double(canvas.height) - height - 40, width: width, height: height),
            on: canvas, cornerRadius: 24, border: SourceBorder(width: 4, colorHex: "#E4BC62")))
    }
    return layout
}

func run(_ scenario: Scenario, canvas: PixelSize, seconds: Double, warmUp: Double, pixelFormat: OSType, withSound: Bool) async throws -> Result {
    let cameraID = UUID()
    var video: [SourceKey: any VideoCapture] = [:]
    if scenario != .empty {
        video[.base] = BenchVideoSource(size: canvas, pixelFormat: pixelFormat, framesPerSecond: 60, deliversOnce: scenario == .still)
    }
    if scenario == .pip {
        video[.source(cameraID)] = BenchVideoSource(size: PixelSize(width: 1280, height: 720), pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, framesPerSecond: 30)
    }
    let rig = CaptureRig(video: video, audio: withSound ? [.minecraft: BenchAudioSource()] : [:], minimizedShowsNothing: false)
    await rig.start()

    let folder = FileManager.default.temporaryDirectory.appending(path: "sTools bench \(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: folder) }
    var result = Result(scenario: scenario, canvas: canvas, cpuPercent: 0)

    if scenario == .armed {
        try await Task.sleep(for: .seconds(warmUp))
        let cpu0 = processCPUSeconds(), wall0 = Date()
        try await Task.sleep(for: .seconds(seconds))
        result.cpuPercent = (processCPUSeconds() - cpu0) / Date().timeIntervalSince(wall0) * 100
        await rig.stop()
        return result
    }

    let options = RecordingOptions()
    let configuration = RecordingSession.Configuration(
        layout: layout(for: scenario, cameraID: cameraID, canvas: canvas), options: options, canvas: canvas,
        baseName: "bench", directory: folder)
    let driver = TimedTickDriver()
    let session = try RecordingSession(configuration: configuration, rig: rig, driver: driver)
    try session.start()
    try await Task.sleep(for: .seconds(warmUp))
    driver.beginMeasuring()
    let cpu0 = processCPUSeconds(), wall0 = Date()
    try await Task.sleep(for: .seconds(seconds))
    result.cpuPercent = (processCPUSeconds() - cpu0) / Date().timeIntervalSince(wall0) * 100
    await rig.stopVideo()
    let written = await session.stop()
    await rig.stop()
    if let file = written.files.first { result.colorTags = await colorTags(of: file) }
    let ticks = driver.results
    result.tickWallMean = mean(ticks.wall)
    result.tickWallP95 = percentile(ticks.wall, 0.95)
    result.tickCPUMean = mean(ticks.cpu)
    result.framesWritten = written.framesWritten
    result.dropped = written.droppedFrames
    return result
}

// MARK: Main

@main
struct RecordingBench {
    static func main() async throws {
        var arguments = Array(CommandLine.arguments.dropFirst())
        var seconds = 8.0
        var format = kCVPixelFormatType_32BGRA
        if let i = arguments.firstIndex(of: "--seconds"), i + 1 < arguments.count {
            seconds = Double(arguments[i + 1]) ?? seconds
            arguments.removeSubrange(i...i + 1)
        }
        var withSound = true
        if let i = arguments.firstIndex(of: "--no-sound") {
            withSound = false
            arguments.remove(at: i)
        }
        if let i = arguments.firstIndex(of: "--420v") {
            format = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            arguments.remove(at: i)
        }
        let scenarios = arguments.first.flatMap(Scenario.init(rawValue:)).map { [$0] } ?? Scenario.allCases
        let sizes: [PixelSize] = arguments.dropFirst().compactMap { text in
            let parts = text.split(separator: "x").compactMap { Int($0) }
            return parts.count == 2 ? PixelSize(width: parts[0], height: parts[1]) : nil
        }
        let canvases = sizes.isEmpty ? [PixelSize(width: 1920, height: 1080), PixelSize(width: 3840, height: 2160)] : sizes

        print("scenario  canvas       CPU % of a core   tick wall ms (mean / p95)   tick CPU ms   frames   dropped")
        for canvas in canvases {
            for scenario in scenarios {
                let r = try await run(scenario, canvas: canvas, seconds: seconds, warmUp: 2, pixelFormat: format, withSound: withSound)
                let line = String(
                    format: "%-8@  %4dx%-4d   %8.1f          %6.2f / %6.2f             %6.2f      %5d    %4d   %@",
                    scenario.rawValue as NSString, r.canvas.width, r.canvas.height, r.cpuPercent,
                    r.tickWallMean, r.tickWallP95, r.tickCPUMean, r.framesWritten, r.dropped, r.colorTags as NSString)
                print(line)
            }
        }
    }
}
