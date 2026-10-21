import Foundation
import STPlatform
import Synchronization
import SwiftUI
@testable import Prologue

/// Permission answers set by the test; requests never show a system prompt.
final class FakeProber: PermissionProbing {
    private let statuses = Mutex<[Permission: PermissionStatus]>([:])
    private let grantsOnRequest = Mutex<Set<Permission>>([])
    private let requests = Mutex<[Permission]>([])

    var requested: [Permission] { requests.withLock { $0 } }

    func set(_ permission: Permission, _ status: PermissionStatus) {
        statuses.withLock { $0[permission] = status }
    }

    /// The next request for `permission` grants it, as if the user pressed Allow.
    func grantOnRequest(_ permission: Permission) {
        _ = grantsOnRequest.withLock { $0.insert(permission) }
    }

    func status(for permission: Permission) -> PermissionStatus {
        statuses.withLock { $0[permission] ?? .notDetermined }
    }

    func request(_ permission: Permission) async -> PermissionStatus {
        requests.withLock { $0.append(permission) }
        if grantsOnRequest.withLock({ $0.contains(permission) }) { set(permission, .granted) }
        return status(for: permission)
    }
}

/// Records what the Prologue asked of the app.
@MainActor
final class FakeHost: PrologueHost {
    let prober = FakeProber()
    var openedURLs: [URL] = []
    lazy var permissions = PermissionCenter(prober: prober, openURL: { [weak self] in self?.openedURLs.append($0) })

    var companionStatuses: [PrologueCompanion: CompanionStatus] = [:]
    var performedActions: [PrologueCompanion] = []
    var toolsOn: [PrologueTrial] = []
    var switchedOff: [PrologueTrial] = []
    var relaunches = 0
    var outcomes: [PrologueFlow.Outcome] = []

    func check(_ companion: PrologueCompanion) async -> CompanionStatus {
        companionStatuses[companion] ?? CompanionStatus(isReady: false, detail: "Missing")
    }

    func performAction(for companion: PrologueCompanion) { performedActions.append(companion) }

    func trial(_ trial: PrologueTrial) -> TrialContent {
        TrialContent(items: { [] }, completed: { [] }, controls: { AnyView(EmptyView()) })
    }

    func toolsToSwitchOff() -> [PrologueTrial] { toolsOn }

    func switchOff(_ tool: PrologueTrial) {
        switchedOff.append(tool)
        toolsOn.removeAll { $0 == tool }
    }

    func relaunch() { relaunches += 1 }

    func prologueDidEnd(_ outcome: PrologueFlow.Outcome) { outcomes.append(outcome) }
}

/// A settings store in a fresh temporary directory, removed when the box goes away.
@MainActor
final class StoreBox {
    let directory = FileManager.default.temporaryDirectory.appending(path: "sTools-prologue-\(UUID().uuidString)")
    lazy var store = SettingsStore(directory: directory, debounce: .milliseconds(5))

    /// A second store on the same directory, as a relaunched app would open it.
    func reopened() -> SettingsStore { SettingsStore(directory: directory, debounce: .milliseconds(5)) }

    deinit { try? FileManager.default.removeItem(at: directory) }
}
