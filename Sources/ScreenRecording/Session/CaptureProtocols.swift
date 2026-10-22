import Foundation

/// What a video source reports.
public enum VideoCaptureEvent: Sendable {
    case frame(VideoFrame)
    /// The window was minimized (true) or restored (false).
    case minimized(Bool)
    /// The source is gone for good (its window closed, its display or camera disconnected).
    case ended(String)
}

/// A screen, window, camera or browser source. Implementations deliver on their own queue.
public protocol VideoCapture: AnyObject, Sendable {
    func start(deliver: @escaping @Sendable (VideoCaptureEvent) -> Void) async throws
    func stop() async
}

/// An app's sound or a microphone. Chunks are stamped on the host clock.
public protocol AudioCapture: AnyObject, Sendable {
    func start(deliver: @escaping @Sendable (AudioChunk) -> Void) async throws
    func stop() async
}

/// Builds the capture objects for a layout. The real factory talks to ScreenCaptureKit, AVFoundation and Core
/// Audio; tests pass fakes.
@MainActor
public protocol CaptureFactory {
    /// Minecraft's window plus sTools' overlay and backdrop panels, on Minecraft's display.
    func base(minecraftWindowID: UInt32, showsCursor: Bool) -> (any VideoCapture)?
    /// `canvas` is the canvas's pixel size, for sources drawn at their size on it (a browser source's page).
    func video(for source: VideoSource, canvas: PixelSize, showsCursor: Bool) -> (any VideoCapture)?
    func audio(for source: AudioSource) -> (any AudioCapture)?
    /// Minecraft's own sound.
    func minecraftAudio(processID: Int32) -> (any AudioCapture)?
}
