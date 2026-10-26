import Foundation
import Observation

/// Owns the six SSE subscriptions (spec 5.1.2) and the one-shot version check, and publishes their
/// latest decoded state. A bad or missing JSON payload is dropped silently — the previous value (or
/// nil, before the first good one) stays current rather than flashing to an error state.
@MainActor
@Observable
public final class NBBConnection {
    public private(set) var stronghold: NBBEvents.Stronghold?
    public private(set) var blind: NBBEvents.Blind?
    public private(set) var divine: NBBEvents.Divine?
    public private(set) var boat: NBBEvents.Boat?
    public private(set) var informationMessages: NBBEvents.InformationMessages?
    public private(set) var allAdvancements: NBBEvents.AllAdvancements?
    public private(set) var version: String?
    /// Whether the primary (stronghold) subscription is currently connected.
    public private(set) var isReachable = false

    @ObservationIgnored private let baseURL: URL
    @ObservationIgnored private let source: any NBBEventSource
    /// The stronghold subscription, which runs whenever the connection does.
    @ObservationIgnored private var primary: Task<Void, Never>?
    /// The other five subscriptions and the version check, which run only while the stronghold one is connected:
    /// while Ninjabrain Bot isn't running, one refused connection every 5 s instead of seven.
    @ObservationIgnored private var secondaries: [Task<Void, Never>] = []

    public init(baseURL: URL = NBBConnection.defaultBaseURL, source: any NBBEventSource = URLSessionEventSource()) {
        self.baseURL = baseURL
        self.source = source
    }

    public static let defaultBaseURL = URL(string: "http://localhost:52533")!

    public var isRunning: Bool { primary != nil }

    /// How many subscriptions (and the version check) are running, for tests.
    var runningTaskCount: Int { (primary == nil ? 0 : 1) + secondaries.count }

    /// One `GET /api/v1/ping`: whether Ninjabrain Bot's API answers right now (the Prologue's live check).
    public static func ping(baseURL: URL = defaultBaseURL, timeout: TimeInterval = 1) async -> Bool {
        let request = URLRequest(url: baseURL.appending(path: "api/v1/ping"), timeoutInterval: timeout)
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let status = (response as? HTTPURLResponse)?.statusCode else { return false }
        return (200..<300).contains(status)
    }

    public func start() {
        guard primary == nil else { return }
        primary = subscribeStronghold()
    }

    /// Ninjabrain Bot answers every endpoint or none, so the others follow the stronghold stream: they start when it
    /// connects and stop when it drops, keeping what they last received.
    private func strongholdConnectionChanged(_ connected: Bool) {
        if isReachable != connected { isReachable = connected }
        guard primary != nil else { return }
        if connected {
            guard secondaries.isEmpty else { return }
            // A reconnect re-sends the whole state; only a value that differs may redraw the overlay.
            secondaries.append(subscribe(path: "blind") { [weak self] in if self?.blind != $0 { self?.blind = $0 } })
            secondaries.append(subscribe(path: "divine") { [weak self] in if self?.divine != $0 { self?.divine = $0 } })
            secondaries.append(subscribe(path: "boat") { [weak self] in if self?.boat != $0 { self?.boat = $0 } })
            secondaries.append(subscribe(path: "information-messages") { [weak self] (value: NBBEvents.InformationMessages) in
                if self?.informationMessages != value { self?.informationMessages = value }
            })
            secondaries.append(subscribe(path: "all-advancements") { [weak self] in if self?.allAdvancements != $0 { self?.allAdvancements = $0 } })
            if version == nil { secondaries.append(Task { [weak self] in await self?.fetchVersion() }) }
        } else {
            for task in secondaries { task.cancel() }
            secondaries.removeAll()
        }
    }

    public func stop() {
        primary?.cancel()
        primary = nil
        for task in secondaries { task.cancel() }
        secondaries.removeAll()
        stronghold = nil
        blind = nil
        divine = nil
        boat = nil
        informationMessages = nil
        allAdvancements = nil
        version = nil
        isReachable = false
    }

    private func subscribeStronghold() -> Task<Void, Never> {
        let url = baseURL.appending(path: "api/v1/stronghold/events")
        let subscription = NBBSubscription(url: url, source: source)
        return Task { [weak self] in
            await subscription.run(
                onEvent: { data in
                    guard let value = Self.decode(NBBEvents.Stronghold.self, from: data) else { return }
                    Task { @MainActor in if self?.stronghold != value { self?.stronghold = value } }
                },
                onConnectionChange: { connected in
                    Task { @MainActor in self?.strongholdConnectionChanged(connected) }
                })
        }
    }

    private func subscribe<T: Decodable & Sendable>(path: String, assign: @escaping @MainActor (T) -> Void) -> Task<Void, Never> {
        let url = baseURL.appending(path: "api/v1/\(path)/events")
        let subscription = NBBSubscription(url: url, source: source)
        return Task {
            await subscription.run(onEvent: { data in
                guard let value = Self.decode(T.self, from: data) else { return }
                Task { @MainActor in assign(value) }
            })
        }
    }

    private func fetchVersion() async {
        let url = baseURL.appending(path: "api/v1/version")
        while !Task.isCancelled {
            if let stream = try? await source.connect(to: url) {
                var bytes: [UInt8] = []
                if let collected = try? await Self.collect(stream) {
                    bytes = collected
                }
                if let value = Self.decode(NBBEvents.Version.self, from: String(decoding: bytes, as: UTF8.self)) {
                    version = value.version
                    return
                }
            }
            try? await Task.sleep(for: .seconds(NBBBackoff.maximumSeconds))
        }
    }

    private static func collect(_ stream: AsyncThrowingStream<[UInt8], Error>) async throws -> [UInt8] {
        var bytes: [UInt8] = []
        for try await chunk in stream { bytes.append(contentsOf: chunk) }
        return bytes
    }

    private nonisolated static func decode<T: Decodable>(_ type: T.Type, from json: String) -> T? {
        try? JSONDecoder().decode(T.self, from: Data(json.utf8))
    }
}
