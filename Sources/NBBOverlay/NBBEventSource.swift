import Foundation

/// Where an SSE subscription reads its byte stream. The real implementation wraps
/// `URLSession.bytes(for:)`; tests use a fake that can simulate connects, drops and failures on command.
public protocol NBBEventSource: Sendable {
    /// Opens a connection to `url`, throwing immediately if it can't be opened (refused, non-2xx).
    /// The returned stream throws if the connection drops, and finishes normally only if the server
    /// closes it cleanly.
    func connect(to url: URL) async throws -> AsyncThrowingStream<UInt8, Error>
}

public enum NBBConnectionError: Error, Equatable {
    case badStatus(Int?)
}

/// The real event source: an SSE `GET` over `URLSession.bytes(for:)`.
public struct URLSessionEventSource: NBBEventSource {
    public init() {}

    public func connect(to url: URL) async throws -> AsyncThrowingStream<UInt8, Error> {
        var request = URLRequest(url: url)
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw NBBConnectionError.badStatus((response as? HTTPURLResponse)?.statusCode)
        }
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await byte in bytes {
                        continuation.yield(byte)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
