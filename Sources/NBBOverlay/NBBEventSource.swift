import Foundation

/// Where an SSE subscription reads its byte stream. The real implementation wraps
/// `URLSession.bytes(for:)`; tests use a fake that can simulate connects, drops and failures on command.
public protocol NBBEventSource: Sendable {
    /// Opens a connection to `url`, throwing immediately if it can't be opened (refused, non-2xx).
    /// The returned stream yields the bytes in pieces as they come (the real one, a line at a time), throws if the
    /// connection drops, and finishes normally only if the server closes it cleanly.
    func connect(to url: URL) async throws -> AsyncThrowingStream<[UInt8], Error>
}

public enum NBBConnectionError: Error, Equatable {
    case badStatus(Int?)
}

/// The real event source: an SSE `GET` over `URLSession.bytes(for:)`, passed on a line at a time.
///
/// It has a session of its own: Ninjabrain Bot's six streams stay open, and the shared session allows six connections
/// to a host, so the version check (or a stream, when the check got in first) waited until a stream closed, which
/// could be never. And each line goes on whole: an SSE event ends with a blank line, so nothing waits for more bytes,
/// and a stronghold result of about 1.5 KB no longer crosses the stream one byte at a time (about 15 ms).
public struct URLSessionEventSource: NBBEventSource {
    /// How long a stream may go without a byte before URLSession gives up on it. Ninjabrain Bot sends nothing between
    /// changes, so the default 60 s dropped every stream once a minute during a quiet stretch of a run, and each
    /// reconnect re-sent its whole state and redrew the overlay. A stopped Ninjabrain Bot closes its sockets, so
    /// waiting long here never hides a real disconnect on localhost.
    static let idleTimeout: TimeInterval = 24 * 60 * 60

    /// Room for the six streams, the version check and a reconnect overlapping a stream that hasn't closed yet.
    static let maximumConnections = 16

    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpMaximumConnectionsPerHost = maximumConnections
        configuration.timeoutIntervalForRequest = idleTimeout
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    public init() {}

    public func connect(to url: URL) async throws -> AsyncThrowingStream<[UInt8], Error> {
        var request = URLRequest(url: url, timeoutInterval: Self.idleTimeout)
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        let (bytes, response) = try await Self.session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw NBBConnectionError.badStatus((response as? HTTPURLResponse)?.statusCode)
        }
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var line: [UInt8] = []
                    line.reserveCapacity(2048)
                    for try await byte in bytes {
                        line.append(byte)
                        if byte == 0x0A {
                            continuation.yield(line)
                            line.removeAll(keepingCapacity: true)
                        }
                    }
                    if !line.isEmpty { continuation.yield(line) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
