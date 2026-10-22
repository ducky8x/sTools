@preconcurrency import AVFoundation
import CoreMedia
import Foundation
import os

/// A camera (Continuity Camera included), as a video source (spec 5.4.1).
public final class CameraCapture: NSObject, VideoCapture, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let uniqueID: String
    private let queue = DispatchQueue(label: "sTools.capture.camera", qos: .userInteractive)
    private let session = AVCaptureSession()
    private let deliver = OSAllocatedUnfairLock<(@Sendable (VideoCaptureEvent) -> Void)?>(initialState: nil)
    private let observer = OSAllocatedUnfairLock<NSObjectProtocol?>(uncheckedState: nil)
    /// A stop while the camera starts wins (`CaptureStartGate`).
    private let gate = CaptureStartGate()

    public init(uniqueID: String) {
        self.uniqueID = uniqueID
    }

    /// A stop that comes before or while this runs leaves the camera off: the session starts on its queue only while
    /// no stop has come, and the stop's `stopRunning` is queued behind it.
    public func start(deliver: @escaping @Sendable (VideoCaptureEvent) -> Void) async throws {
        try gate.check()
        guard let device = AVCaptureDevice(uniqueID: uniqueID) else { throw CaptureError.notFound("The camera") }
        let input = try AVCaptureDeviceInput(device: device)
        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        session.beginConfiguration()
        guard session.canAddInput(input), session.canAddOutput(output) else {
            session.commitConfiguration()
            throw CaptureError.unavailable("The camera is in use or can\u{2019}t be opened.")
        }
        session.addInput(input)
        session.addOutput(output)
        session.commitConfiguration()
        self.deliver.withLock { $0 = deliver }
        let token = NotificationCenter.default.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification, object: device, queue: nil) { _ in
            deliver(.ended("The camera was disconnected."))
        }
        observer.withLockUnchecked { $0 = token }
        queue.async { [session, gate] in
            if !gate.isClosed { session.startRunning() }
        }
        try await gate.finish { await tearDown() }
    }

    public func stop() async {
        gate.close()
        await tearDown()
    }

    /// Lets go of the output and the disconnect observer, and stops the session behind any start queued before it.
    private func tearDown() async {
        deliver.withLock { $0 = nil }
        if let token = observer.withLockUnchecked({ observer in defer { observer = nil }; return observer }) {
            NotificationCenter.default.removeObserver(token)
        }
        let session = session
        await withCheckedContinuation { continuation in
            queue.async {
                session.stopRunning()
                continuation.resume()
            }
        }
    }

    public func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let frame = VideoFrame(pixelBuffer: pixelBuffer, hostTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        deliver.withLock { $0 }?(.frame(frame))
    }
}

/// A microphone, as an audio source. Opened by its unique ID; buffers arrive as 48 kHz stereo Float32 stamped on
/// the host clock, which is what the audio timeline lines up.
public final class MicrophoneCapture: NSObject, AudioCapture, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let uniqueID: String
    private let queue = DispatchQueue(label: "sTools.capture.microphone", qos: .userInteractive)
    private let session = AVCaptureSession()
    private let deliver = OSAllocatedUnfairLock<(@Sendable (AudioChunk) -> Void)?>(initialState: nil)
    /// A stop while the microphone starts wins (`CaptureStartGate`).
    private let gate = CaptureStartGate()

    public init(uniqueID: String) {
        self.uniqueID = uniqueID
    }

    /// A stop that comes before or while this runs leaves the microphone off, as the camera's does.
    public func start(deliver: @escaping @Sendable (AudioChunk) -> Void) async throws {
        try gate.check()
        guard let device = AVCaptureDevice(uniqueID: uniqueID) else { throw CaptureError.notFound("The microphone") }
        let input = try AVCaptureDeviceInput(device: device)
        let output = AVCaptureAudioDataOutput()
        output.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: AudioFormat.sampleRate,
            AVNumberOfChannelsKey: AudioFormat.channelCount,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
        ]
        output.setSampleBufferDelegate(self, queue: queue)
        session.beginConfiguration()
        guard session.canAddInput(input), session.canAddOutput(output) else {
            session.commitConfiguration()
            throw CaptureError.unavailable("The microphone is in use or can\u{2019}t be opened.")
        }
        session.addInput(input)
        session.addOutput(output)
        session.commitConfiguration()
        self.deliver.withLock { $0 = deliver }
        queue.async { [session, gate] in
            if !gate.isClosed { session.startRunning() }
        }
        try await gate.finish { await tearDown() }
    }

    public func stop() async {
        gate.close()
        await tearDown()
    }

    /// Lets go of the output and stops the session behind any start queued before it.
    private func tearDown() async {
        deliver.withLock { $0 = nil }
        let session = session
        await withCheckedContinuation { continuation in
            queue.async {
                session.stopRunning()
                continuation.resume()
            }
        }
    }

    public func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let chunk = Self.chunk(from: sampleBuffer) else { return }
        deliver.withLock { $0 }?(chunk)
    }

    /// Interleaved Float32 samples out of a PCM sample buffer.
    static func chunk(from sampleBuffer: CMSampleBuffer) -> AudioChunk? {
        guard let format = CMSampleBufferGetFormatDescription(sampleBuffer),
              let description = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
              description.mFormatFlags & kAudioFormatFlagIsFloat != 0, description.mBitsPerChannel == 32 else { return nil }
        var list = AudioBufferList()
        var block: CMBlockBuffer?
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer, bufferListSizeNeededOut: nil, bufferListOut: &list, bufferListSize: MemoryLayout<AudioBufferList>.size,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: &block) == noErr,
              let data = list.mBuffers.mData else { return nil }
        let count = Int(list.mBuffers.mDataByteSize) / MemoryLayout<Float>.size
        let samples = Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: Float.self), count: count))
        return AudioChunk(
            samples: samples, sampleRate: description.mSampleRate, channelCount: Int(description.mChannelsPerFrame),
            hostTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
    }
}
