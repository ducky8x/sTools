import ServiceManagement
import Testing
@testable import STPlatform

@MainActor
private final class FakeBackend: LoginItemBackend {
    var status: SMAppService.Status
    var registerCalls = 0
    var unregisterCalls = 0
    var failure: (any Error)?

    init(status: SMAppService.Status) { self.status = status }

    func register() throws {
        registerCalls += 1
        if let failure { throw failure }
        status = .enabled
    }

    func unregister() throws {
        unregisterCalls += 1
        if let failure { throw failure }
        status = .notRegistered
    }
}

private struct Boom: Error {}

@MainActor
@Suite struct LoginItemTests {
    @Test func statusMapping() {
        #expect(LoginItemState(.enabled) == .enabled)
        #expect(LoginItemState(.notRegistered) == .notRegistered)
        #expect(LoginItemState(.requiresApproval) == .requiresApproval)
        #expect(LoginItemState(.notFound) == .notFound)
    }

    @Test func isEnabledMeansRegistered() {
        #expect(LoginItemState.enabled.isEnabled)
        #expect(LoginItemState.requiresApproval.isEnabled)
        #expect(!LoginItemState.notRegistered.isEnabled)
        #expect(!LoginItemState.notFound.isEnabled)
    }

    @Test func enablingRegistersOnlyWhenNeeded() throws {
        let backend = FakeBackend(status: .notRegistered)
        let item = SystemLoginItem(backend: backend)
        try item.setEnabled(true)
        #expect(backend.registerCalls == 1)
        #expect(item.state == .enabled)
        try item.setEnabled(true)
        #expect(backend.registerCalls == 1)
    }

    @Test func enablingWhileApprovalIsPendingDoesNotRegisterAgain() throws {
        let backend = FakeBackend(status: .requiresApproval)
        let item = SystemLoginItem(backend: backend)
        try item.setEnabled(true)
        #expect(backend.registerCalls == 0)
        #expect(item.state == .requiresApproval)
        #expect(item.isEnabled)
    }

    @Test func disablingUnregistersRegisteredStates() throws {
        for status in [SMAppService.Status.enabled, .requiresApproval] {
            let backend = FakeBackend(status: status)
            let item = SystemLoginItem(backend: backend)
            try item.setEnabled(false)
            #expect(backend.unregisterCalls == 1)
            #expect(!item.isEnabled)
        }
    }

    @Test func disablingWhenNotRegisteredIsANoOp() throws {
        for status in [SMAppService.Status.notRegistered, .notFound] {
            let backend = FakeBackend(status: status)
            let item = SystemLoginItem(backend: backend)
            try item.setEnabled(false)
            #expect(backend.unregisterCalls == 0)
        }
    }

    @Test func failuresPropagate() {
        let backend = FakeBackend(status: .notRegistered)
        backend.failure = Boom()
        let item = SystemLoginItem(backend: backend)
        #expect(throws: Boom.self) { try item.setEnabled(true) }
        #expect(!item.isEnabled)
    }

    @Test func fakeControllerFollowsTheProtocol() throws {
        let fake = FakeLoginItem()
        #expect(!fake.isEnabled)
        try fake.setEnabled(true)
        #expect(fake.isEnabled)
        #expect(fake.state == .enabled)
        fake.state = .requiresApproval
        #expect(fake.isEnabled)
        fake.failure = Boom()
        #expect(throws: Boom.self) { try fake.setEnabled(false) }
        #expect(fake.state == .requiresApproval)
        fake.openSystemSettings()
        #expect(fake.openSettingsCount == 1)
    }
}
