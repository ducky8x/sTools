import AudioToolbox
import CoreAudio
import CoreMedia
import Foundation
import os

/// One audio process as Core Audio lists it.
struct AudioProcessInfo: Sendable, Equatable {
    var object: AudioObjectID
    var pid: Int32
    var bundleID: String
}

/// A tap that is delivering sound until it is stopped.
protocol ProcessTapHandle: AnyObject, Sendable {
    func stop()
}

/// Brings up a tap on the audio processes `processes`, delivering their sound mixed down to stereo. Tests pass a fake,
/// so no Core Audio tap, and no permission prompt, ever comes up there.
typealias ProcessTapFactory = @Sendable (_ processes: [AudioObjectID], _ deliver: @escaping @Sendable (AudioChunk) -> Void) throws -> any ProcessTapHandle

/// The sound of one app, or of the web pages sTools shows, through a Core Audio process tap (macOS 14.2+, spec 5.4.2),
/// unmuted, stamped on the host clock. An app that hasn't made a sound yet has no audio process; the tap is attached
/// once it does.
public final class ProcessTapCapture: AudioCapture, @unchecked Sendable {
    public enum Target: Sendable, Equatable {
        case processID(Int32)
        /// Every audio process of the app, its helpers included (`com.google.Chrome.helper`…).
        case bundleID(String)
        /// The sound of the web pages sTools shows: the audio processes of the WebKit helpers (web content, graphics and
        /// media) that work for sTools. Never another app's: Safari's tabs have helpers of the same names, but they work
        /// for Safari (`ProcessResponsibility`). They come and go, so the tap follows them while it runs (see
        /// `followsProcesses`).
        case ownWebViews

        /// Whether the processes it names change while it is tapped, so the tap is kept in line with them until it is
        /// stopped, rather than attached once.
        var followsProcesses: Bool { self == .ownWebViews }
    }

    private let target: Target
    /// Whether this Mac can say whom a WebKit helper works for (`ProcessResponsibility`). Without that a web page's
    /// sound can't be told from another app's, so it is not recorded.
    private let canTellWhoseHelpersTheyAre: Bool
    /// The target's audio processes; Core Audio's list unless a test passes its own.
    private let findProcesses: @Sendable (Target) -> [AudioObjectID]
    /// Makes the tap; Core Audio's unless a test passes its own.
    private let makeTap: ProcessTapFactory
    /// How often a silent app is looked at again, or a following target's processes are looked at for a change.
    private let retryInterval: Duration
    private let state = OSAllocatedUnfairLock(initialState: State())
    /// A stop while the tap starts, or while it waits for the app's first sound, wins (`CaptureStartGate`).
    private let gate = CaptureStartGate()

    private struct State {
        var tap: (any ProcessTapHandle)?
        /// The audio processes `tap` listens to.
        var tapped: Set<AudioObjectID> = []
        /// Looks for the target's audio processes until it has one, or, for a following target, until the stop.
        var waiter: Task<Void, Never>?
    }

    public convenience init(target: Target) {
        self.init(target: target, findProcesses: { Self.processObjects(for: $0) }, retryInterval: target.followsProcesses ? .seconds(1) : .seconds(2))
    }

    init(target: Target, findProcesses: @escaping @Sendable (Target) -> [AudioObjectID], retryInterval: Duration,
         canTellWhoseHelpersTheyAre: Bool = ProcessResponsibility.isAvailable,
         makeTap: @escaping ProcessTapFactory = { try CoreAudioProcessTap(processes: $0, deliver: $1) }) {
        self.target = target
        self.canTellWhoseHelpersTheyAre = canTellWhoseHelpersTheyAre
        self.findProcesses = findProcesses
        self.makeTap = makeTap
        self.retryInterval = retryInterval
    }

    /// A stop that comes before or while this runs, or while it waits for the app's first sound, leaves no tap and
    /// no looking behind.
    public func start(deliver: @escaping @Sendable (AudioChunk) -> Void) async throws {
        try gate.check()
        if target == .ownWebViews, !canTellWhoseHelpersTheyAre {
            throw CaptureError.unavailable("this version of macOS doesn\u{2019}t say which sound is a web page\u{2019}s.")
        }
        let attached = (try? attach(deliver)) == true
        if !attached || target.followsProcesses {
            // Nothing to tap yet, or processes that come and go: keep looking while the recorder is armed.
            let interval = retryInterval
            let waiter = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: interval)
                    guard let self, !self.gate.isClosed else { return }
                    let attached = (try? self.attach(deliver)) == true
                    // A stop while it attached found the tap not yet stored.
                    if self.gate.isClosed {
                        await self.tearDown()
                        return
                    }
                    if attached, !self.target.followsProcesses { return }
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
        old.tap?.stop()
    }

    /// Puts the tap on the target's audio processes as they are now: brings it up when it has none and the target has
    /// some, takes it down and brings it up again when the processes changed, and leaves it alone when they didn't. True
    /// when a tap listens to something afterwards. False when the target has no audio process yet.
    private func attach(_ deliver: @escaping @Sendable (AudioChunk) -> Void) throws -> Bool {
        guard !gate.isClosed else { return false }
        let processes = findProcesses(target)
        guard !gate.isClosed else { return false }
        let wanted = Set(processes)
        let (tap, tapped) = state.withLock { ($0.tap, $0.tapped) }
        if wanted == tapped { return tap != nil }
        // The processes changed (only a following target gets here with a tap up): the old tap goes before the new
        // one comes, so a process in both is never heard twice.
        tap?.stop()
        state.withLock {
            $0.tap = nil
            $0.tapped = []
        }
        guard !wanted.isEmpty else { return false }
        let made = try makeTap(processes.sorted(), deliver)
        state.withLock {
            $0.tap = made
            $0.tapped = wanted
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
        case .ownWebViews:
            return ownWebViewProcesses(among: audioProcesses(), ownPID: getpid(), responsiblePID: { ProcessResponsibility.responsiblePID(of: $0) })
        }
    }

    /// The audio processes that are WebKit helpers working for this app: a helper's bundle ID starts with
    /// `com.apple.WebKit.`, and the app it works for (`responsiblePID`) is `ownPID`, or the process `ownPID` itself works
    /// for (an app started from a terminal or a debugger works for that). Another app's helpers carry the same bundle IDs
    /// and are left out, and so is anything that isn't WebKit's, this app's own process included (its interface sounds
    /// and Timer Overlay's alarm are not web pages). When the system can't say whom a helper works for, it is left out
    /// too: no sound is better than another app's.
    static func ownWebViewProcesses(
        among processes: [AudioProcessInfo], ownPID: Int32, responsiblePID: (Int32) -> Int32?
    ) -> [AudioObjectID] {
        let owners = Set([ownPID] + [responsiblePID(ownPID)].compactMap { $0 })
        return processes
            .filter { process in
                guard process.pid != ownPID, process.bundleID.hasPrefix(webKitHelperPrefix),
                      let worksFor = responsiblePID(process.pid) else { return false }
                return owners.contains(worksFor)
            }
            .map(\.object)
    }

    /// The bundle ID every WebKit helper (web content, graphics and media, networking) starts with.
    static let webKitHelperPrefix = "com.apple.WebKit."

    /// The audio processes that could be this app's WebKit helpers, with their bundle IDs. Core Audio is asked for each
    /// process's pid first, and for a bundle ID only where the process works for this app, which keeps a look to a few
    /// calls.
    private static func audioProcesses() -> [AudioProcessInfo] {
        let me = getpid()
        let owners = Set([me] + [ProcessResponsibility.responsiblePID(of: me)].compactMap { $0 })
        return allProcessObjects().compactMap { object in
            guard let pid = pid(of: object), pid != me, let worksFor = ProcessResponsibility.responsiblePID(of: pid),
                  owners.contains(worksFor) else { return nil }
            return AudioProcessInfo(object: object, pid: pid, bundleID: bundleID(of: object) ?? "")
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

    private static func pid(of object: AudioObjectID) -> Int32? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyPID,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: Int32 = 0
        var size = UInt32(MemoryLayout<Int32>.size)
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr ? value : nil
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
}

/// A Core Audio process tap on some audio processes, the private aggregate device that holds it, and the IO callback
/// that hands the sound on.
final class CoreAudioProcessTap: ProcessTapHandle, @unchecked Sendable {
    private let queue = DispatchQueue(label: "sTools.capture.tap", qos: .userInteractive)
    private let state = OSAllocatedUnfairLock(initialState: State())

    private struct State {
        var tapID = AudioObjectID(kAudioObjectUnknown)
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var procID: AudioDeviceIOProcID?
    }

    /// Creates the tap, its device and the callback, and starts listening. Throws when macOS refuses (the permission,
    /// say); nothing is left behind then.
    init(processes: [AudioObjectID], deliver: @escaping @Sendable (AudioChunk) -> Void) throws {
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
            guard let chunk = ProcessTapCapture.chunk(buffers, interleaved: interleaved, sampleRate: rate, hostTime: inputTime.pointee.mHostTime) else { return }
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
    }

    /// Takes down the callback, the device and the tap. Stopping again finds nothing.
    func stop() {
        let old = state.withLock { state -> State in
            defer { state = State() }
            return state
        }
        if let procID = old.procID {
            AudioDeviceStop(old.deviceID, procID)
            AudioDeviceDestroyIOProcID(old.deviceID, procID)
        }
        if old.deviceID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(old.deviceID) }
        if old.tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(old.tapID) }
    }

    private static func format(of tap: AudioObjectID) -> AudioStreamBasicDescription? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        return AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &format) == noErr ? format : nil
    }
}
