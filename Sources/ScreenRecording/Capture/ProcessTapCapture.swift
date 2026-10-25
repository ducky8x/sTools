import AudioToolbox
import CoreAudio
import CoreMedia
import Foundation
import os

/// The sound of one app through a Core Audio process tap (macOS 14.2+, spec 5.4.2), unmuted, stamped on the
/// host clock. An app that hasn't made a sound yet has no audio process; the tap is attached once it does.
public final class ProcessTapCapture: AudioCapture, @unchecked Sendable {
    public enum Target: Sendable, Equatable {
        case processID(Int32)
        /// Every audio process of the app, its helpers included (`com.google.Chrome.helper`…).
        case bundleID(String)
    }

    private let target: Target
    /// The app's audio processes; Core Audio's list unless a test passes its own.
    private let findProcesses: @Sendable (Target) -> [AudioObjectID]
    /// How often a silent app is looked at again.
    private let retryInterval: Duration
    private let queue = DispatchQueue(label: "sTools.capture.tap", qos: .userInteractive)
    private let state = OSAllocatedUnfairLock(initialState: State())
    /// A stop while the tap starts, or while it waits for the app's first sound, wins (`CaptureStartGate`).
    private let gate = CaptureStartGate()

    private struct State {
        var tapID = AudioObjectID(kAudioObjectUnknown)
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var procID: AudioDeviceIOProcID?
        /// Looks for the app's audio process until it has one.
        var waiter: Task<Void, Never>?
    }

    public convenience init(target: Target) {
        self.init(target: target, findProcesses: { Self.processObjects(for: $0) }, retryInterval: .seconds(2))
    }

    init(target: Target, findProcesses: @escaping @Sendable (Target) -> [AudioObjectID], retryInterval: Duration) {
        self.target = target
        self.findProcesses = findProcesses
        self.retryInterval = retryInterval
    }

    /// A stop that comes before or while this runs, or while it waits for the app's first sound, leaves no tap and
    /// no looking behind.
    public func start(deliver: @escaping @Sendable (AudioChunk) -> Void) async throws {
        try gate.check()
        if (try? attach(deliver)) != true {
            // Nothing to tap yet: keep looking while the recorder is armed.
            let interval = retryInterval
            let waiter = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: interval)
                    guard let self, !self.gate.isClosed else { return }
                    if (try? self.attach(deliver)) == true {
                        // A stop while it attached found the tap not yet stored.
                        if self.gate.isClosed { await self.tearDown() }
                        return
                    }
                }
            }
            state.withLock { $0.waiter = waiter }
        }
        try await gate.finish { await tearDown() }
    }

    public func stop() async {
        gate.close()
        await tearDown()
    }

    /// Stops the looking and takes down the tap, its device and its callback, whatever of them is there. Running it
    /// again finds nothing.
    private func tearDown() async {
        let old = state.withLock { state -> State in
            defer { state = State() }
            return state
        }
        old.waiter?.cancel()
        if let procID = old.procID {
            AudioDeviceStop(old.deviceID, procID)
            AudioDeviceDestroyIOProcID(old.deviceID, procID)
        }
        if old.deviceID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(old.deviceID) }
        if old.tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(old.tapID) }
    }

    /// Creates the tap, its private aggregate device and the IO callback. False when the app has no audio
    /// process yet.
    private func attach(_ deliver: @escaping @Sendable (AudioChunk) -> Void) throws -> Bool {
        guard !gate.isClosed else { return false }
        let processes = findProcesses(target)
        guard !processes.isEmpty, !gate.isClosed else { return false }

        let description = CATapDescription(stereoMixdownOfProcesses: processes)
        description.name = "sTools recording"
        description.isPrivate = true
        description.muteBehavior = .unmuted
        var tapID = AudioObjectID(kAudioObjectUnknown)
        guard AudioHardwareCreateProcessTap(description, &tapID) == noErr else {
            throw CaptureError.unavailable("sTools isn\u{2019}t allowed to record app audio.")
        }
        guard let format = Self.format(of: tapID) else {
            AudioHardwareDestroyProcessTap(tapID)
            throw CaptureError.unavailable("The app\u{2019}s sound has an unknown format.")
        }
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "sTools recording",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: description.uuid.uuidString, kAudioSubTapDriftCompensationKey: true]],
        ]
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        guard AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &deviceID) == noErr else {
            AudioHardwareDestroyProcessTap(tapID)
            throw CaptureError.unavailable("sTools couldn\u{2019}t set up app audio.")
        }
        let interleaved = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
        let rate = format.mSampleRate
        var procID: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(&procID, deviceID, queue) { _, input, inputTime, _, _ in
            let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            guard let chunk = Self.chunk(buffers, interleaved: interleaved, sampleRate: rate, hostTime: inputTime.pointee.mHostTime) else { return }
            deliver(chunk)
        }
        guard status == noErr, let procID, AudioDeviceStart(deviceID, procID) == noErr else {
            if let procID { AudioDeviceDestroyIOProcID(deviceID, procID) }
            AudioHardwareDestroyAggregateDevice(deviceID)
            AudioHardwareDestroyProcessTap(tapID)
            throw CaptureError.unavailable("sTools couldn\u{2019}t start recording app audio.")
        }
        let created = (tap: tapID, device: deviceID)
        state.withLock {
            $0.tapID = created.tap
            $0.deviceID = created.device
            $0.procID = procID
        }
        return true
    }

    /// Float32 buffers (one interleaved, or one per channel) as an interleaved chunk.
    static func chunk(_ buffers: UnsafeMutableAudioBufferListPointer, interleaved: Bool, sampleRate: Double, hostTime: UInt64) -> AudioChunk? {
        let time = CMClockMakeHostTimeFromSystemUnits(hostTime)
        if interleaved {
            guard let buffer = buffers.first, let data = buffer.mData else { return nil }
            let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
            let samples = Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: Float.self), count: count))
            return AudioChunk(samples: samples, sampleRate: sampleRate, channelCount: Int(max(1, buffer.mNumberChannels)), hostTime: time)
        }
        let channels: [[Float]] = buffers.compactMap { buffer in
            guard let data = buffer.mData else { return nil }
            let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
            return Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: Float.self), count: count))
        }
        guard !channels.isEmpty else { return nil }
        return AudioChunk(planar: channels, sampleRate: sampleRate, hostTime: time)
    }

    // MARK: Finding processes

    static func processObjects(for target: Target) -> [AudioObjectID] {
        switch target {
        case .processID(let pid):
            var pid = pid
            var object = AudioObjectID(kAudioObjectUnknown)
            var size = UInt32(MemoryLayout<AudioObjectID>.size)
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
                mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            let status = AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address, UInt32(MemoryLayout<Int32>.size), &pid, &size, &object)
            return status == noErr && object != kAudioObjectUnknown ? [object] : []
        case .bundleID(let wanted):
            return allProcessObjects().filter { object in
                guard let id = bundleID(of: object) else { return false }
                return id == wanted || id.hasPrefix(wanted + ".")
            }
        }
    }

    private static func allProcessObjects() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &objects) == noErr else { return [] }
        return objects
    }

    private static func bundleID(of object: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyBundleID,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    private static func format(of tap: AudioObjectID) -> AudioStreamBasicDescription? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        return AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &format) == noErr ? format : nil
    }
}
