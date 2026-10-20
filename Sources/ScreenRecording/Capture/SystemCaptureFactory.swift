import AppKit
import AVFoundation
import Foundation
import ScreenCaptureKit

/// Builds the real capture objects (spec 5.4.2).
@MainActor
public struct SystemCaptureFactory: CaptureFactory {
    public var frameRate: Int

    public init(frameRate: Int) {
        self.frameRate = frameRate
    }

    public func base(minecraftWindowID: UInt32, showsCursor: Bool) -> (any VideoCapture)? {
        ScreenCapture(target: .base(minecraftWindowID: minecraftWindowID), showsCursor: showsCursor, frameRate: frameRate)
    }

    public func video(for source: VideoSource, showsCursor: Bool) -> (any VideoCapture)? {
        switch source.kind {
        case .window(let reference):
            ScreenCapture(target: .window(reference.windowID), showsCursor: showsCursor, frameRate: frameRate)
        case .display(let reference):
            ScreenCapture(target: .display(reference.displayID), showsCursor: showsCursor, frameRate: frameRate)
        case .camera(let reference):
            CameraCapture(uniqueID: reference.uniqueID)
        case .browser(let address):
            URL(string: address).map {
                BrowserCapture(url: $0, pixelSize: PixelSize(width: Int(source.frame.width), height: Int(source.frame.height)), frameRate: frameRate)
            }
        }
    }

    public func audio(for source: AudioSource) -> (any AudioCapture)? {
        switch source.kind {
        case .app(let bundleID): ProcessTapCapture(target: .bundleID(bundleID))
        case .microphone(let uniqueID): MicrophoneCapture(uniqueID: uniqueID)
        // Which WebKit helper process plays a page's sound can't be told with public API, so a browser
        // source's own audio isn't recorded in v1.
        case .browser: nil
        }
    }

    public func minecraftAudio(processID: Int32) -> (any AudioCapture)? {
        ProcessTapCapture(target: .processID(processID))
    }
}

/// Everything Add Source can offer right now (spec 5.4.3).
public struct AvailableSources: Sendable, Equatable {
    public struct App: Sendable, Equatable, Hashable {
        public var bundleID: String
        public var name: String
    }

    public struct Microphone: Sendable, Equatable, Hashable {
        public var uniqueID: String
        public var name: String
    }

    public var windows: [WindowReference] = []
    public var displays: [DisplayReference] = []
    /// Pixel sizes of the listed windows and displays, so a new source starts at the right shape.
    public var windowSizes: [UInt32: PixelSize] = [:]
    public var displaySizes: [UInt32: PixelSize] = [:]
    public var cameras: [CameraReference] = []
    public var microphones: [Microphone] = []
    public var apps: [App] = []
    /// False when Screen & System Audio Recording isn't granted, so no windows or displays can be listed.
    public var canListScreens = true

    public init() {}

    /// Reads what's there now. `excludingProcessIDs` leaves out sTools and Minecraft (the base layer has it).
    @MainActor
    public static func load(excludingProcessIDs: Set<Int32>) async -> AvailableSources {
        var sources = AvailableSources()
        if let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false) {
            sources.windows = content.windows
                .filter { window in
                    guard let app = window.owningApplication, !excludingProcessIDs.contains(app.processID) else { return false }
                    return window.windowLayer == 0 && window.frame.width >= 80 && window.frame.height >= 60
                }
                .map { window in
                    WindowReference(windowID: window.windowID, appName: window.owningApplication?.applicationName ?? "",
                                    bundleID: window.owningApplication?.bundleIdentifier, title: window.title ?? "")
                }
                .sorted { ($0.appName, $0.title) < ($1.appName, $1.title) }
            sources.displays = content.displays.map { display in
                DisplayReference(displayID: display.displayID, name: displayName(display.displayID))
            }
            let scale = NSScreen.main?.backingScaleFactor ?? 2
            for window in content.windows {
                sources.windowSizes[window.windowID] = PixelSize(width: Int(window.frame.width * scale), height: Int(window.frame.height * scale))
            }
            for display in content.displays {
                sources.displaySizes[display.displayID] = PixelSize(width: Int(CGFloat(display.width) * scale), height: Int(CGFloat(display.height) * scale))
            }
        } else {
            sources.canListScreens = false
        }
        let cameras = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera, .deskViewCamera], mediaType: .video, position: .unspecified)
        sources.cameras = cameras.devices.map { CameraReference(uniqueID: $0.uniqueID, name: $0.localizedName) }
        let microphones = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified)
        sources.microphones = microphones.devices.map { Microphone(uniqueID: $0.uniqueID, name: $0.localizedName) }
        sources.apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && !excludingProcessIDs.contains($0.processIdentifier) }
            .compactMap { app in app.bundleIdentifier.map { App(bundleID: $0, name: app.localizedName ?? $0) } }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return sources
    }

    /// A saved window source points at a window ID that only lives as long as that window; this finds the
    /// same app's window again by title, then by app.
    public func resolve(_ reference: WindowReference) -> WindowReference? {
        if windows.contains(where: { $0.windowID == reference.windowID }) { return reference }
        let sameApp = windows.filter { $0.bundleID != nil && $0.bundleID == reference.bundleID }
        return sameApp.first { $0.title == reference.title } ?? sameApp.first
    }

    @MainActor
    private static func displayName(_ id: UInt32) -> String {
        let screen = NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id }
        return screen?.localizedName ?? "Display \(id)"
    }
}
