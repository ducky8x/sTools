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
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []

    public init(baseURL: URL = NBBConnection.defaultBaseURL, source: any NBBEventSource = URLSessionEventSource()) {
        self.baseURL = baseURL
        self.source = source
    }

    public static let defaultBaseURL = URL(string: "http://localhost:52533")!

    public var isRunning: Bool { !tasks.isEmpty }

    /// One `GET /api/v1/ping`: whether Ninjabrain Bot's API answers right now (the Prologue's live check).
    public static func ping(baseURL: URL = defaultBaseURL, timeout: TimeInterval = 1) async -> Bool {
        let request = URLRequest(url: baseURL.appending(path: "api/v1/ping"), timeoutInterval: timeout)
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let status = (response as? HTTPURLResponse)?.statusCode else { return false }
        return (200..<300).contains(status)
    }

    public func start() {
        guard tasks.isEmpty else { return }
        tasks.append(subscribeStronghold())
        tasks.append(subscribe(path: "blind") { [weak self] in self?.blind = $0 })
        tasks.append(subscribe(path: "divine") { [weak self] in self?.divine = $0 })
        tasks.append(subscribe(path: "boat") { [weak self] in self?.boat = $0 })
        tasks.append(subscribe(path: "information-messages") { [weak self] (value: NBBEvents.InformationMessages) in self?.informationMessages = value })
        tasks.append(subscribe(path: "all-advancements") { [weak self] in self?.allAdvancements = $0 })
        tasks.append(Task { [weak self] in await self?.fetchVersion() })
    }

    public func stop() {
        for task in tasks { task.cancel() }
        tasks.removeAll()
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
                    Task { @MainActor in self?.stronghold = value }
                },
                onConnectionChange: { connected in
                    Task { @MainActor in self?.isReachable = connected }
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

    private static func collect(_ stream: AsyncThrowingStream<UInt8, Error>) async throws -> [UInt8] {
        var bytes: [UInt8] = []
        for try await byte in stream { bytes.append(byte) }
        return bytes
    }

    private nonisolated static func decode<T: Decodable>(_ type: T.Type, from json: String) -> T? {
        try? JSONDecoder().decode(T.self, from: Data(json.utf8))
    }
}
