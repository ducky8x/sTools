// Measures what an animated Window Backdrop fill costs while it plays: the CPU the process spends, how busy the GPU is,
// and how much memory the animation holds, for a few videos and GIFs it makes itself in a temporary folder (random
// patches that move, so a video has a real bitrate to decode). It plays them with the backdrop's own player and view,
// in a window that is never ordered onto a screen, so nothing shows, no permission is asked and no file of yours is read.
// Not part of the app.
//
//   swift run -c release BackdropBench                  every case, each measured for 8 s between two idle measurements
//   swift run -c release BackdropBench --seconds 15     a longer measurement
//   swift run -c release BackdropBench video            only the videos (also: gif)
//   swift run -c release BackdropBench --off-screen     also order the window in, far outside every display
//   swift run -c release BackdropBench --only 4K        only the cases whose name has the text
//
// What it cannot see: the window server's share. On screen, every new picture is composited there, which this process's
// numbers don't include, and nothing here is on a screen. The GPU figure is the whole GPU's, other apps included, and a
// video's decoding runs on the media engine, which isn't counted in it. So these are the cost of decoding and handing
// pictures over, to be read next to Activity Monitor's CPU and GPU history with Minecraft open (spec 9.3). The same machine's
// numbers move by half or more with its load, so each case is measured between two idle runs.

import AppKit
import AVFoundation
import Backdrop
import CoreVideo
import Darwin
import Foundation
import ImageIO
import IOKit
import UniformTypeIdentifiers

// MARK: - Measuring

/// The process's user plus system CPU time, in seconds.
func cpuSeconds() -> Double {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    func seconds(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1e6 }
    return seconds(usage.ru_utime) + seconds(usage.ru_stime)
}

/// The memory the process holds, in megabytes (its footprint, as Activity Monitor's Memory column).
func footprintMB() -> Double {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
    }
    return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : 0
}

/// How busy the GPU is right now, 0 to 100, from the accelerator's own statistics. Nil where the Mac doesn't report it.
func gpuBusyPercent() -> Double? {
    var iterator: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS else { return nil }
    defer { IOObjectRelease(iterator) }
    var busiest: Double?
    var service = IOIteratorNext(iterator)
    while service != 0 {
        var properties: Unmanaged<CFMutableDictionary>?
        if IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
           let dictionary = properties?.takeRetainedValue() as? [String: Any],
           let statistics = dictionary["PerformanceStatistics"] as? [String: Any],
           let busy = statistics["Device Utilization %"] as? NSNumber {
            busiest = max(busiest ?? 0, busy.doubleValue)
        }
        IOObjectRelease(service)
        service = IOIteratorNext(iterator)
    }
    return busiest
}

struct Measurement {
    var cpuPercent: Double
    var gpuAverage: Double?
    var gpuMax: Double?
    var footprintMB: Double
}

/// Runs the main run loop for `seconds` (the layer tree needs it to commit pictures, as the app's does), sampling the GPU
/// every half second, and reports what the process spent meanwhile.
@MainActor
func measure(seconds: Double) -> Measurement {
    let cpuStart = cpuSeconds(), start = ContinuousClock.now
    var gpu: [Double] = []
    let end = start + .seconds(seconds)
    while ContinuousClock.now < end {
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        if let busy = gpuBusyPercent() { gpu.append(busy) }
    }
    let elapsed = ContinuousClock.now - start
    let wall = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
    return Measurement(
        cpuPercent: (cpuSeconds() - cpuStart) / wall * 100,
        gpuAverage: gpu.isEmpty ? nil : gpu.reduce(0, +) / Double(gpu.count), gpuMax: gpu.max(), footprintMB: footprintMB())
}

@MainActor
func spin(seconds: Double) {
    let end = ContinuousClock.now + .seconds(seconds)
    while ContinuousClock.now < end { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
}

/// Where `runToEnd` leaves the result of the async work for the run loop's turns to find.
final class ResultBox<T: Sendable>: @unchecked Sendable {
    var result: Result<T, any Error>?
    init() {}
}

/// Runs async work to its end while the main run loop keeps turning, which the players and the layer tree need. The
/// bench's main isn't async because an async main sits inside a main-queue job, and a run loop turned inside one never
/// reaches the jobs queued behind it.
@MainActor
func runToEnd<T: Sendable>(_ work: @escaping @Sendable () async throws -> T) throws -> T {
    let box = ResultBox<T>()
    Task {
        do { box.result = .success(try await work()) } catch { box.result = .failure(error) }
    }
    while box.result == nil { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
    return try box.result!.get()
}

// MARK: - Making the media

/// One picture's worth of random 16 x 16 patches, which the frames then slide across so everything changes each frame.
final class PatchField {
    let width: Int, height: Int
    private var bytes: [UInt8]

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
        bytes = [UInt8](repeating: 255, count: width * height * 4)
        var state: UInt64 = 0x9E3779B97F4A7C15
        func next() -> UInt8 {
            state ^= state << 13; state ^= state >> 7; state ^= state << 17
            return UInt8(truncatingIfNeeded: state >> 24)
        }
        for blockY in stride(from: 0, to: height, by: 16) {
            for blockX in stride(from: 0, to: width, by: 16) {
                let (blue, green, red) = (next(), next(), next())
                for y in blockY..<min(blockY + 16, height) {
                    for x in blockX..<min(blockX + 16, width) {
                        let offset = (y * width + x) * 4
                        bytes[offset] = blue; bytes[offset + 1] = green; bytes[offset + 2] = red
                    }
                }
            }
        }
    }

    /// Writes the field slid `shift` pixels to the left into `buffer`.
    func draw(into buffer: CVPixelBuffer, shift: Int) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        let offset = (shift % width) * 4
        bytes.withUnsafeBufferPointer { source in
            for y in 0..<height {
                let row = source.baseAddress! + y * width * 4
                let target = base + y * rowBytes
                memcpy(target, row + offset, width * 4 - offset)
                memcpy(target + (width * 4 - offset), row, offset)
            }
        }
    }
}

enum BenchError: Error { case writer(String) }

/// A video of `seconds` seconds at `fps`, `width` x `height`, with the codec and a bitrate in bits a second.
func writeVideo(to url: URL, width: Int, height: Int, fps: Int32, seconds: Int, codec: AVVideoCodecType, bitsPerSecond: Int) async throws {
    let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: codec, AVVideoWidthKey: width, AVVideoHeightKey: height,
        AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: bitsPerSecond, AVVideoExpectedSourceFrameRateKey: fps],
    ])
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
    ])
    guard writer.canAdd(input) else { throw BenchError.writer("the writer can't take \(codec.rawValue) at \(width) x \(height)") }
    writer.add(input)
    guard writer.startWriting() else { throw writer.error ?? BenchError.writer("startWriting failed") }
    writer.startSession(atSourceTime: .zero)
    let field = PatchField(width: width, height: height)
    for index in 0..<Int(fps) * seconds {
        while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &buffer)
        guard let buffer else { throw BenchError.writer("no pixel buffer") }
        field.draw(into: buffer, shift: index * 4)
        guard adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(index), timescale: fps)) else {
            throw writer.error ?? BenchError.writer("append failed")
        }
    }
    input.markAsFinished()
    await writer.finishWriting()
    guard writer.status == .completed else { throw writer.error ?? BenchError.writer("the file wasn't finished") }
}

/// A GIF of `frames` frames, `width` x `height`, each up for `delay` seconds.
func writeGIF(to url: URL, width: Int, height: Int, frames: Int, delay: Double) throws {
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, frames, nil) else {
        throw BenchError.writer("no GIF destination")
    }
    CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
    let field = PatchField(width: width, height: height)
    for index in 0..<frames {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &buffer)
        guard let buffer else { throw BenchError.writer("no pixel buffer") }
        field.draw(into: buffer, shift: index * 16)
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        let image = context?.makeImage()
        CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
        guard let image else { throw BenchError.writer("no frame") }
        let properties = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay, kCGImagePropertyGIFUnclampedDelayTime: delay]]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
    }
    guard CGImageDestinationFinalize(destination) else { throw BenchError.writer("the GIF wasn't finished") }
}

// MARK: - Cases

struct Case: Sendable {
    enum Kind: Sendable { case video, gif }
    let name: String
    let kind: Kind
    let make: @Sendable (URL) async throws -> Void
}

func cases() -> [Case] {
    [
        Case(name: "video  H.264 1080p 30 fps  8 Mbps", kind: .video) {
            try await writeVideo(to: $0, width: 1920, height: 1080, fps: 30, seconds: 4, codec: .h264, bitsPerSecond: 8_000_000)
        },
        Case(name: "video  H.264 1080p 60 fps 12 Mbps", kind: .video) {
            try await writeVideo(to: $0, width: 1920, height: 1080, fps: 60, seconds: 4, codec: .h264, bitsPerSecond: 12_000_000)
        },
        Case(name: "video  HEVC  4K    30 fps 20 Mbps", kind: .video) {
            try await writeVideo(to: $0, width: 3840, height: 2160, fps: 30, seconds: 4, codec: .hevc, bitsPerSecond: 20_000_000)
        },
        Case(name: "GIF    480 x 270, 24 frames, 15 fps  (fits the cache)", kind: .gif) {
            try writeGIF(to: $0, width: 480, height: 270, frames: 24, delay: 1.0 / 15)
        },
        Case(name: "GIF    1920 x 1080, 12 frames, 12 fps (fits the cache)", kind: .gif) {
            try writeGIF(to: $0, width: 1920, height: 1080, frames: 12, delay: 1.0 / 12)
        },
        Case(name: "GIF    1920 x 1080, 24 frames, 12 fps (too big for it)", kind: .gif) {
            try writeGIF(to: $0, width: 1920, height: 1080, frames: 24, delay: 1.0 / 12)
        },
    ]
}

/// `memoryBefore` is the footprint the case started from, so the line says how much the case holds on top of it.
func describe(_ measurement: Measurement, memoryBefore: Double = 0) -> String {
    let gpu = measurement.gpuAverage.map { String(format: "GPU busy %2.0f%% (up to %2.0f%%)", $0, measurement.gpuMax ?? $0) } ?? "GPU busy n/a"
    return String(format: "CPU %6.2f%% of a core   %@   memory %+5.0f MB", measurement.cpuPercent, gpu, measurement.footprintMB - memoryBefore)
}

func system() -> String {
    var size = 0
    sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
    var brand = [CChar](repeating: 0, count: size)
    sysctlbyname("machdep.cpu.brand_string", &brand, &size, nil, 0)
    var load = [Double](repeating: 0, count: 3)
    getloadavg(&load, 3)
    let name = String(decoding: brand.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    return "\(name), \(ProcessInfo.processInfo.operatingSystemVersionString), load average now \(String(format: "%.1f", load[0]))"
}

// MARK: - Main

@main
struct BackdropBench {
    static func main() {
        MainActor.assumeIsolated { run() }
    }

    @MainActor
    static func run() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        var seconds = 8.0
        var arguments = Array(CommandLine.arguments.dropFirst())
        if let index = arguments.firstIndex(of: "--seconds"), index + 1 < arguments.count {
            seconds = Double(arguments[index + 1]) ?? seconds
            arguments.removeSubrange(index...index + 1)
        }
        let offScreen = arguments.contains("--off-screen")
        arguments.removeAll { $0 == "--off-screen" }
        var only: String?
        if let index = arguments.firstIndex(of: "--only"), index + 1 < arguments.count {
            only = arguments[index + 1]
            arguments.removeSubrange(index...index + 1)
        }
        let wanted = arguments.first
        var chosen = cases()
        if wanted == "video" { chosen = chosen.filter { $0.kind == .video } }
        if wanted == "gif" { chosen = chosen.filter { $0.kind == .gif } }
        if let only { chosen = chosen.filter { $0.name.contains(only) } }

        let folder = FileManager.default.temporaryDirectory.appending(path: "sTools-backdrop-bench-\(UUID().uuidString)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        print("BackdropBench: \(system())")
        print("each case plays \(Int(seconds)) s after 2 s of warm-up, between two idle measurements; window \(offScreen ? "ordered in far off every display" : "never ordered in")\n")
        var idle: [Measurement] = []
        func measureIdle() -> Measurement { spin(seconds: 1); return measure(seconds: seconds) }
        let first = measureIdle()
        idle.append(first)
        print("idle                                                      " + describe(first, memoryBefore: first.footprintMB))

        for (index, item) in chosen.enumerated() {
            let url = folder.appending(path: "case-\(index).\(item.kind == .gif ? "gif" : "mp4")")
            do {
                try runToEnd { try await item.make(url) }
            } catch {
                print("\(item.name)\n    skipped: \(error)")
                continue
            }
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            let host = BackdropBenchHost(url: url, size: CGSize(width: 1920, height: 1080), orderedInFarOffScreen: offScreen)
            let deadline = ContinuousClock.now + .seconds(10)
            while host.pictureSize == nil, host.failure == nil, ContinuousClock.now < deadline { spin(seconds: 0.05) }
            guard host.failure == nil, let picture = host.pictureSize else {
                print("\(item.name)\n    skipped: \(host.failure ?? "the file didn't open")")
                host.stop()
                continue
            }
            let before = footprintMB()
            host.play()
            spin(seconds: 2)
            let playing = measure(seconds: seconds)
            host.pause()
            let paused = measureIdle()
            host.stop()
            let after = measureIdle()
            idle.append(paused)
            idle.append(after)
            print("\(item.name)   (\(Int(picture.width)) x \(Int(picture.height)), file \(String(format: "%.1f", Double(size) / 1_048_576)) MB)")
            print("    playing   " + describe(playing, memoryBefore: before))
            print("    paused    " + describe(paused, memoryBefore: before))
            print("    stopped   " + describe(after, memoryBefore: before))
        }
        let cpu = idle.map(\.cpuPercent)
        print(String(format: "\nidle CPU across the run: %.2f%% to %.2f%% of a core; subtract it from the figures above", cpu.min() ?? 0, cpu.max() ?? 0))
    }
}
