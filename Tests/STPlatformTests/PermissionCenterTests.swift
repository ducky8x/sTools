import AppKit
import Foundation
import Observation
import Synchronization
import Testing

@testable import STPlatform

/// A scriptable prober. Requests never show a system prompt; they apply `grantOnRequest`
/// to the stored status (after an optional delay) and return `requestResult`.
private final class FakeProber: PermissionProbing {
    private struct State {
        var statuses: [Permission: PermissionStatus]
        var statusCalls = 0
        var callsByPermission: [Permission: Int] = [:]
        var requested: [Permission] = []
        var requestResult: PermissionStatus?
        var statusAfterRequest: PermissionStatus?
        var requestDelay: Duration = .zero
    }

    private let state: Mutex<State>

    init(_ initial: PermissionStatus = .denied) {
        state = Mutex(State(statuses: Dictionary(uniqueKeysWithValues: Permission.allCases.map { ($0, initial) })))
    }

    var statusCalls: Int { state.withLock { $0.statusCalls } }
    func calls(for permission: Permission) -> Int { state.withLock { $0.callsByPermission[permission] ?? 0 } }
    var requested: [Permission] { state.withLock { $0.requested } }

    func set(_ permission: Permission, _ status: PermissionStatus) {
        state.withLock { $0.statuses[permission] = status }
    }

    /// What `request` returns and what `status(for:)` reports afterwards.
    func scriptRequest(result: PermissionStatus, statusAfter: PermissionStatus? = nil, delay: Duration = .zero) {
        state.withLock {
            $0.requestResult = result
            $0.statusAfterRequest = statusAfter ?? result
            $0.requestDelay = delay
        }
    }

    func status(for permission: Permission) -> PermissionStatus {
        state.withLock {
            $0.statusCalls += 1
            $0.callsByPermission[permission, default: 0] += 1
            return $0.statuses[permission] ?? .unknown
        }
    }

    func request(_ permission: Permission) async -> PermissionStatus {
        let (result, after, delay) = state.withLock { s -> (PermissionStatus, PermissionStatus, Duration) in
            s.requested.append(permission)
            return (s.requestResult ?? .granted, s.statusAfterRequest ?? .granted, s.requestDelay)
        }
        if delay > .zero { try? await Task.sleep(for: delay) }
        state.withLock { $0.statuses[permission] = after }
        return result
    }
}

/// Waits (without fixed sleeps in the assertion path) until `condition` holds or the timeout passes.
@MainActor
private func eventually(
    timeout: Duration = .seconds(3),
    _ condition: @MainActor () -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(2))
    }
    return condition()
}

@MainActor
private func makeCenter(
    _ prober: FakeProber,
    opened: OpenedURLs = OpenedURLs(),
    systemNotifications: NotificationCenter = NotificationCenter()
) -> PermissionCenter {
    PermissionCenter(prober: prober, openURL: { opened.urls.append($0) }, systemNotifications: systemNotifications)
}

@MainActor
private final class OpenedURLs {
    var urls: [URL] = []
}

// MARK: - Permission metadata

@Test func permissionReasonsMatchTheSpec() {
    #expect(Permission.accessibility.reason
        == "Lets sTools find the Minecraft window and follow it, and lets hotkeys recognize Minecraft in front.")
    #expect(Permission.screenRecording.reason == "Lets sTools record Minecraft and the sources you add.")
    #expect(Permission.appAudio.reason == "Lets sTools record the sound of Minecraft and other apps.")
    #expect(Permission.microphone.reason == "Lets sTools record your voice.")
    #expect(Permission.camera.reason == "Lets sTools put your camera on the recording.")
}

@Test func permissionTitles() {
    #expect(Permission.accessibility.title == "Accessibility")
    #expect(Permission.screenRecording.title == "Screen & System Audio Recording")
    #expect(Permission.appAudio.title == "App audio")
    #expect(Permission.microphone.title == "Microphone")
    #expect(Permission.camera.title == "Camera")
}

@Test func settingsURLsAreWellFormedAndDistinctPerPane() {
    let prefix = "x-apple.systempreferences:com.apple.preference.security?"
    for permission in Permission.allCases {
        let url = permission.settingsURL
        #expect(url.scheme == "x-apple.systempreferences", "\(permission)")
        #expect(url.absoluteString.hasPrefix(prefix), "\(permission)")
        #expect(!url.absoluteString.dropFirst(prefix.count).isEmpty, "\(permission)")
    }
    #expect(Permission.accessibility.settingsURL.absoluteString == prefix + "Privacy_Accessibility")
    #expect(Permission.screenRecording.settingsURL.absoluteString == prefix + "Privacy_ScreenCapture")
    #expect(Permission.microphone.settingsURL.absoluteString == prefix + "Privacy_Microphone")
    #expect(Permission.camera.settingsURL.absoluteString == prefix + "Privacy_Camera")
    // App audio shares the Screen & System Audio Recording pane on macOS 15 and later.
    #expect(Permission.appAudio.settingsURL == Permission.screenRecording.settingsURL)
    #expect(Set(Permission.allCases.map(\.settingsURL)).count == 4)
}

@Test func onlyScreenRecordingMayNeedRelaunch() {
    for permission in Permission.allCases {
        #expect(permission.mayNeedRelaunch == (permission == .screenRecording), "\(permission)")
    }
}

// MARK: - Refresh

@MainActor
@Test func initialStatusesComeFromTheProber() {
    let prober = FakeProber(.denied)
    prober.set(.accessibility, .granted)
    prober.set(.camera, .notDetermined)
    prober.set(.appAudio, .unknown)
    let center = makeCenter(prober)
    #expect(center.statuses.count == Permission.allCases.count)
    #expect(center.status(.accessibility) == .granted)
    #expect(center.status(.camera) == .notDetermined)
    #expect(center.status(.appAudio) == .unknown)
    #expect(center.status(.microphone) == .denied)
}

@MainActor
@Test func refreshPicksUpChanges() {
    let prober = FakeProber(.denied)
    let center = makeCenter(prober)
    prober.set(.microphone, .granted)
    #expect(center.status(.microphone) == .denied)
    center.refresh()
    #expect(center.status(.microphone) == .granted)
}

@MainActor
@Test func noBackgroundWorkUnlessPollingBegan() async {
    let prober = FakeProber()
    let center = makeCenter(prober)
    let baseline = prober.statusCalls
    try? await Task.sleep(for: .milliseconds(60))
    NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
    try? await Task.sleep(for: .milliseconds(20))
    #expect(prober.statusCalls == baseline)
    _ = center
}

// MARK: - Polling

@MainActor
@Test func pollingPicksUpStatusChanges() async {
    let prober = FakeProber(.denied)
    let center = makeCenter(prober)
    center.beginPolling(interval: .milliseconds(5))
    defer { center.endPolling() }
    prober.set(.accessibility, .granted)
    #expect(await eventually { center.status(.accessibility) == .granted })
}

@MainActor
@Test func proberReturningDeniedThenGrantedOverTime() async {
    let prober = FakeProber(.denied)
    let center = makeCenter(prober)
    center.beginPolling(interval: .milliseconds(5))
    defer { center.endPolling() }

    let before = prober.statusCalls
    #expect(await eventually { prober.statusCalls > before + Permission.allCases.count * 3 })
    #expect(center.status(.screenRecording) == .denied)

    prober.set(.screenRecording, .granted)
    #expect(await eventually { center.status(.screenRecording) == .granted })
    #expect(center.status(.camera) == .denied)

    prober.set(.screenRecording, .denied)
    #expect(await eventually { center.status(.screenRecording) == .denied })
}

@MainActor
@Test func pollingStopsAfterEndPolling() async {
    let prober = FakeProber()
    let center = makeCenter(prober)
    center.beginPolling(interval: .milliseconds(5))
    let started = prober.statusCalls
    #expect(await eventually { prober.statusCalls > started })

    center.endPolling()
    let afterEnd = prober.statusCalls
    try? await Task.sleep(for: .milliseconds(80))
    #expect(prober.statusCalls == afterEnd)

    NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
    try? await Task.sleep(for: .milliseconds(20))
    #expect(prober.statusCalls == afterEnd)
}

@MainActor
@Test func beginPollingIsReferenceCounted() async {
    let prober = FakeProber()
    let center = makeCenter(prober)
    center.beginPolling(interval: .milliseconds(5))
    center.beginPolling(interval: .milliseconds(5))
    center.endPolling()

    // One holder remains, so polling continues.
    prober.set(.camera, .granted)
    #expect(await eventually { center.status(.camera) == .granted })

    center.endPolling()
    let afterEnd = prober.statusCalls
    try? await Task.sleep(for: .milliseconds(60))
    #expect(prober.statusCalls == afterEnd)
}

@MainActor
@Test func overlappingBeginsDoNotMultiplyTheTimer() async {
    let prober = FakeProber()
    let center = makeCenter(prober)
    let single = FakeProber()
    let singleCenter = makeCenter(single)

    singleCenter.beginPolling(interval: .milliseconds(20))
    for _ in 0..<5 { center.beginPolling(interval: .milliseconds(20)) }
    let baseSingle = single.statusCalls
    let baseMany = prober.statusCalls
    try? await Task.sleep(for: .milliseconds(400))
    singleCenter.endPolling()
    for _ in 0..<5 { center.endPolling() }

    let singleTicks = single.statusCalls - baseSingle
    let manyTicks = prober.statusCalls - baseMany
    // Five overlapping begins must not poll five times as often as one.
    #expect(manyTicks <= singleTicks * 2 + Permission.allCases.count)
}

@MainActor
@Test func extraEndPollingIsHarmlessAndPollingCanRestart() async {
    let prober = FakeProber()
    let center = makeCenter(prober)
    center.endPolling()
    center.endPolling()
    center.beginPolling(interval: .milliseconds(5))
    prober.set(.microphone, .granted)
    #expect(await eventually { center.status(.microphone) == .granted })
    center.endPolling()
}

@MainActor
@Test func becomingActiveRefreshesWithoutWaitingForTheTimer() async {
    let prober = FakeProber()
    let center = makeCenter(prober)
    center.beginPolling(interval: .seconds(60))
    defer { center.endPolling() }
    prober.set(.accessibility, .granted)
    NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
    #expect(await eventually { center.status(.accessibility) == .granted })
}

@MainActor
@Test func beginPollingRefreshesImmediately() {
    let prober = FakeProber()
    let center = makeCenter(prober)
    prober.set(.camera, .granted)
    center.beginPolling(interval: .seconds(60))
    defer { center.endPolling() }
    #expect(center.status(.camera) == .granted)
}

// MARK: - Polling only what's asked for

@MainActor
@Test func aPollReadsOnlyThePermissionsItAskedFor() async {
    let prober = FakeProber(.denied)
    let center = makeCenter(prober)
    let token = center.beginPolling([.accessibility], interval: .milliseconds(5))
    let before = prober.calls(for: .accessibility)
    #expect(await eventually { prober.calls(for: .accessibility) > before + 3 })
    center.endPolling(token)
    // Only the start-up read touched the others.
    for permission in Permission.allCases where permission != .accessibility {
        #expect(prober.calls(for: permission) == 1, "\(permission)")
    }
    #expect(!center.isPolling)
}

@MainActor
@Test func refreshingSomePermissionsKeepsTheOthers() {
    let prober = FakeProber(.denied)
    let center = makeCenter(prober)
    prober.set(.camera, .granted)
    prober.set(.accessibility, .granted)
    center.refresh([.accessibility])
    #expect(center.status(.accessibility) == .granted)
    #expect(center.status(.camera) == .denied)
    #expect(center.statuses.count == Permission.allCases.count)
}

@MainActor
@Test func pollsShareOneTimerAtTheShortestInterval() async {
    let prober = FakeProber(.denied)
    let center = makeCenter(prober)
    let slow = center.beginPolling([.accessibility], interval: .seconds(60))
    let fast = center.beginPolling([.camera], interval: .milliseconds(5))
    prober.set(.accessibility, .granted)
    prober.set(.camera, .granted)
    // The fast poll's timer reads both polls' permissions.
    #expect(await eventually { center.status(.accessibility) == .granted && center.status(.camera) == .granted })
    #expect(prober.calls(for: .microphone) == 1)

    center.endPolling(fast)
    #expect(center.isPolling)
    let afterFast = prober.calls(for: .camera)
    try? await Task.sleep(for: .milliseconds(60))
    // Back on the slow poll alone: nothing more within its minute, and never the camera again.
    #expect(prober.calls(for: .camera) == afterFast)
    center.endPolling(slow)
    #expect(!center.isPolling)
}

@MainActor
@Test func endingOnePollLeavesTheOthersRunning() async {
    let prober = FakeProber(.denied)
    let center = makeCenter(prober)
    let first = center.beginPolling([.accessibility], interval: .milliseconds(5))
    let second = center.beginPolling([.accessibility], interval: .milliseconds(5))
    center.endPolling(first)
    center.endPolling(first)
    prober.set(.accessibility, .granted)
    #expect(await eventually { center.status(.accessibility) == .granted })
    center.endPolling(second)
    let afterEnd = prober.statusCalls
    try? await Task.sleep(for: .milliseconds(60))
    #expect(prober.statusCalls == afterEnd)
}

@MainActor
@Test func theOlderEndPollingNeverEndsAPollThatWasHandedAToken() async {
    let prober = FakeProber(.denied)
    let center = makeCenter(prober)
    let token = center.beginPolling([.accessibility], interval: .milliseconds(5))
    center.endPolling()
    #expect(center.isPolling)
    prober.set(.accessibility, .granted)
    #expect(await eventually { center.status(.accessibility) == .granted })
    center.endPolling(token)
    #expect(!center.isPolling)
}

@MainActor
@Test func theSystemsAccessibilityNoticeRefreshesAtOnce() async {
    let prober = FakeProber(.granted)
    let notices = NotificationCenter()
    let center = makeCenter(prober, systemNotifications: notices)
    let token = center.beginPolling([.accessibility], interval: .seconds(60))
    prober.set(.accessibility, .denied)
    notices.post(name: PermissionCenter.accessibilityChangedNotification, object: nil)
    #expect(center.status(.accessibility) == .denied)
    center.endPolling(token)
}

@MainActor
@Test func theAccessibilityNoticeIsIgnoredWithoutAPollThatNeedsIt() {
    let prober = FakeProber(.granted)
    let notices = NotificationCenter()
    let center = makeCenter(prober, systemNotifications: notices)
    prober.set(.accessibility, .denied)
    notices.post(name: PermissionCenter.accessibilityChangedNotification, object: nil)
    #expect(center.status(.accessibility) == .granted)

    let token = center.beginPolling([.camera], interval: .seconds(60))
    notices.post(name: PermissionCenter.accessibilityChangedNotification, object: nil)
    #expect(center.status(.accessibility) == .granted)
    center.endPolling(token)

    let accessibility = center.beginPolling([.accessibility], interval: .seconds(60))
    center.endPolling(accessibility)
    prober.set(.accessibility, .granted)
    notices.post(name: PermissionCenter.accessibilityChangedNotification, object: nil)
    // The poll began with a fresh read (denied), and the notice after it ended changed nothing.
    #expect(center.status(.accessibility) == .denied)
}

@MainActor
@Test func becomingActiveRefreshesOnlyWhatIsPolled() async {
    let prober = FakeProber(.denied)
    let center = makeCenter(prober)
    let token = center.beginPolling([.accessibility], interval: .seconds(60))
    let microphoneCalls = prober.calls(for: .microphone)
    prober.set(.accessibility, .granted)
    NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
    #expect(await eventually { center.status(.accessibility) == .granted })
    #expect(prober.calls(for: .microphone) == microphoneCalls)
    center.endPolling(token)
}

// MARK: - Requests

@MainActor
@Test func requestUpdatesStatus() async {
    let prober = FakeProber(.notDetermined)
    let center = makeCenter(prober)
    prober.scriptRequest(result: .granted)
    await center.request(.microphone)
    #expect(prober.requested == [.microphone])
    #expect(center.status(.microphone) == .granted)
    #expect(center.status(.camera) == .notDetermined)
}

@MainActor
@Test func requestReportingDeniedIsRecorded() async {
    let prober = FakeProber(.notDetermined)
    let center = makeCenter(prober)
    prober.scriptRequest(result: .denied)
    await center.request(.camera)
    #expect(center.status(.camera) == .denied)
}

@MainActor
@Test func requestKeepsTheResultWhenTheProberCannotReportStatus() async {
    let prober = FakeProber(.unknown)
    let center = makeCenter(prober)
    prober.scriptRequest(result: .granted, statusAfter: .unknown)
    await center.request(.appAudio)
    #expect(center.status(.appAudio) == .granted)
}

@MainActor
@Test func requestDoesNotLeaveAStaleResultWhenStatusMovedOnDuringTheRequest() async {
    let prober = FakeProber(.notDetermined)
    let center = makeCenter(prober)
    // The request resolves as .denied, but by the time it returns the system already says granted.
    prober.scriptRequest(result: .denied, statusAfter: .granted)
    await center.request(.screenRecording)
    #expect(center.status(.screenRecording) == .granted)
}

@MainActor
@Test func requestRacingWithPollingEndsConsistent() async {
    let prober = FakeProber(.notDetermined)
    let center = makeCenter(prober)
    // The request must still be pending when we look; a wide margin keeps this stable on a busy machine.
    prober.scriptRequest(result: .granted, delay: .milliseconds(600))
    center.beginPolling(interval: .milliseconds(2))
    defer { center.endPolling() }

    let pending = Task { await center.request(.microphone) }
    try? await Task.sleep(for: .milliseconds(20))
    #expect(center.status(.microphone) == .notDetermined)

    await pending.value
    #expect(center.status(.microphone) == .granted)
    try? await Task.sleep(for: .milliseconds(40))
    #expect(center.status(.microphone) == .granted)
    #expect(center.status(.camera) == .notDetermined)
}

@MainActor
@Test func concurrentRequestsForDifferentPermissionsDoNotInterfere() async {
    let prober = FakeProber(.notDetermined)
    let center = makeCenter(prober)
    prober.scriptRequest(result: .granted, delay: .milliseconds(10))
    async let a: Void = center.request(.microphone)
    async let b: Void = center.request(.camera)
    _ = await (a, b)
    #expect(center.status(.microphone) == .granted)
    #expect(center.status(.camera) == .granted)
    #expect(center.status(.accessibility) == .notDetermined)
}

// MARK: - Rapid refresh and observation

@MainActor
@Test func rapidRefreshStaysConsistent() {
    let prober = FakeProber(.denied)
    let center = makeCenter(prober)
    for i in 0..<2_000 {
        prober.set(.accessibility, i.isMultiple(of: 2) ? .granted : .denied)
        center.refresh()
        #expect(center.status(.accessibility) == (i.isMultiple(of: 2) ? .granted : .denied))
    }
    #expect(center.statuses.count == Permission.allCases.count)
}

@MainActor
@Test func refreshWithoutChangesDoesNotNotifyObservers() {
    let prober = FakeProber(.granted)
    let center = makeCenter(prober)
    let fired = Mutex(false)
    withObservationTracking {
        _ = center.statuses
    } onChange: {
        fired.withLock { $0 = true }
    }
    center.refresh()
    center.refresh()
    #expect(!fired.withLock { $0 })

    prober.set(.camera, .denied)
    center.refresh()
    #expect(fired.withLock { $0 })
}

// MARK: - Settings links

@MainActor
@Test func openSettingsUsesTheRightURLForEveryPermission() {
    let opened = OpenedURLs()
    let center = makeCenter(FakeProber(), opened: opened)
    for permission in Permission.allCases {
        center.openSettings(for: permission)
    }
    #expect(opened.urls == Permission.allCases.map(\.settingsURL))
}

@MainActor
@Test func creatingTheCenterNeverOpensSettingsOrRequests() {
    let opened = OpenedURLs()
    let prober = FakeProber()
    let center = makeCenter(prober, opened: opened)
    center.refresh()
    center.beginPolling(interval: .seconds(60))
    center.endPolling()
    #expect(opened.urls.isEmpty)
    #expect(prober.requested.isEmpty)
}

// MARK: - System prober (read-only calls; requests are manual checks)

@Test func systemProberReadsStatusWithoutPrompting() {
    let prober = SystemPermissionProber()
    for permission in Permission.allCases {
        _ = prober.status(for: permission)
    }
    #expect(prober.status(for: .appAudio) == .unknown)
}
