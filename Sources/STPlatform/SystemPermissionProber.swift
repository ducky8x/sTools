import ApplicationServices
import AVFoundation
import CoreAudio
import CoreGraphics
import os

/// Reads and requests the real macOS permissions through public API only.
public struct SystemPermissionProber: PermissionProbing {
    /// There is no public preflight for app audio, so the last request outcome is remembered here.
    private let appAudioResult = OSAllocatedUnfairLock(initialState: PermissionStatus.unknown)

    public init() {}

    public func status(for permission: Permission) -> PermissionStatus {
        switch permission {
        case .accessibility:
            return AXIsProcessTrusted() ? .granted : .denied
        case .screenRecording:
            return CGPreflightScreenCaptureAccess() ? .granted : .denied
        case .appAudio:
            return appAudioResult.withLock { $0 }
        case .microphone:
            return Self.map(AVCaptureDevice.authorizationStatus(for: .audio))
        case .camera:
            return Self.map(AVCaptureDevice.authorizationStatus(for: .video))
        }
    }

    public func request(_ permission: Permission) async -> PermissionStatus {
        switch permission {
        case .accessibility:
            // The key is the value of kAXTrustedCheckOptionPrompt, spelled out because the global is not concurrency-safe.
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            return AXIsProcessTrustedWithOptions(options) ? .granted : .denied
        case .screenRecording:
            return CGRequestScreenCaptureAccess() ? .granted : .denied
        case .appAudio:
            let result = await Task.detached { Self.probeSystemAudioCapture() }.value
            appAudioResult.withLock { $0 = result }
            return result
        case .microphone:
            return await AVCaptureDevice.requestAccess(for: .audio) ? .granted : .denied
        case .camera:
            return await AVCaptureDevice.requestAccess(for: .video) ? .granted : .denied
        }
    }

    private static func map(_ status: AVAuthorizationStatus) -> PermissionStatus {
        switch status {
        case .authorized: .granted
        case .notDetermined: .notDetermined
        case .denied, .restricted: .denied
        @unknown default: .unknown
        }
    }

    /// Triggers the system-audio-capture consent by starting a global Core Audio process tap
    /// inside a private aggregate device, then tears everything down at once.
    /// Requires `NSAudioCaptureUsageDescription` in the app's Info.plist.
    private static func probeSystemAudioCapture() -> PermissionStatus {
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.name = "sTools permission probe"
        description.isPrivate = true
        description.muteBehavior = .unmuted

        var tapID = AudioObjectID(kAudioObjectUnknown)
        guard AudioHardwareCreateProcessTap(description, &tapID) == noErr else { return .denied }
        defer { AudioHardwareDestroyProcessTap(tapID) }

        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "sTools permission probe",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: false,
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: description.uuid.uuidString,
                    kAudioSubTapDriftCompensationKey: true,
                ]
            ],
        ]
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        guard AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &deviceID) == noErr else { return .denied }
        defer { AudioHardwareDestroyAggregateDevice(deviceID) }

        var procID: AudioDeviceIOProcID?
        guard AudioDeviceCreateIOProcIDWithBlock(&procID, deviceID, nil, { _, _, _, _, _ in }) == noErr,
            let procID
        else { return .denied }
        defer { AudioDeviceDestroyIOProcID(deviceID, procID) }

        guard AudioDeviceStart(deviceID, procID) == noErr else { return .denied }
        AudioDeviceStop(deviceID, procID)
        return .granted
    }
}
