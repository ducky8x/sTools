import Darwin
import Dispatch
import Foundation
import Synchronization

/// A tiny HTTP server on 127.0.0.1 that answers like Ninjabrain Bot's API (spec 5.1.2), for tests that go through the
/// real `URLSession` path: `…/events` paths get a chunked `text/event-stream` with the path's current value sent on
/// subscribe and again on every `send`, as Ninjabrain Bot's `EventSender` does; `…/version` gets a JSON body. Loopback
/// only, on a port the system picks, so it never meets the person's own Ninjabrain Bot (port 52533) and asks for no
/// permission. Everything runs on its own queue; nothing waits on the main actor.
final class LocalSSEServer: @unchecked Sendable {
    private struct State {
        var values: [String: String] = [:]
        var subscribers: [String: [Int32]] = [:]
        var connects: [String: Int] = [:]
        var clients: [Int32: DispatchSourceRead] = [:]
        var listener: (fd: Int32, source: DispatchSourceRead)?
    }

    private let queue = DispatchQueue(label: "LocalSSEServer")
    private let state = Mutex(State())
    private(set) var port: UInt16 = 0

    var baseURL: URL { URL(string: "http://127.0.0.1:\(port)")! }

    /// Starts listening on a free port, with `values` as each path's state.
    init(values: [String: String] = [:]) throws {
        state.withLock { $0.values = values }
        try bindAndListen(on: 0)
    }

    /// Listens again on `requested` after `stop()`, as Ninjabrain Bot reopening on its port. The old socket closes on the
    /// server's queue, so a bind that comes before it is tried again until it goes through or 10 s of awake time (not a
    /// count of tries, which a busy Mac stretches or squeezes) have passed.
    func listen(on requested: UInt16) async throws {
        let deadline = SuspendingClock.now.advanced(by: .seconds(10))
        while true {
            do {
                try bindAndListen(on: requested)
                return
            } catch POSIXError.EADDRINUSE where SuspendingClock.now < deadline {
                try await Task.sleep(for: .milliseconds(5))
            }
        }
    }

    private func bindAndListen(on requested: UInt16) throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = requested.bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, Darwin.listen(fd, 32) == 0 else {
            close(fd)
            throw POSIXError(.EADDRINUSE)
        }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        port = UInt16(bigEndian: address.sin_port)
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.accept(on: fd) }
        source.setCancelHandler { close(fd) }
        state.withLock { $0.listener = (fd, source) }
        source.resume()
    }

    /// The path's new value, sent at once to everyone subscribed to it. Returns when the bytes are written.
    func send(_ path: String, _ json: String) {
        let subscribers = state.withLock { state -> [Int32] in
            state.values[path] = json
            return state.subscribers[path] ?? []
        }
        for fd in subscribers { Self.writeEvent(json, to: fd) }
    }

    /// How many times `path` was asked for.
    func connects(_ path: String) -> Int { state.withLock { $0.connects[path] ?? 0 } }
    /// How many streams of `path` are open now.
    func subscribers(_ path: String) -> Int { state.withLock { $0.subscribers[path]?.count ?? 0 } }

    /// Drops every open connection (Ninjabrain Bot quitting), and with `listening: false` stops answering too.
    func dropAll(listening: Bool = true) {
        let (clients, listener) = state.withLock { state -> ([DispatchSourceRead], DispatchSourceRead?) in
            let clients = Array(state.clients.values)
            state.clients.removeAll()
            state.subscribers.removeAll()
            let listener = listening ? nil : state.listener?.source
            if !listening { state.listener = nil }
            return (clients, listener)
        }
        for client in clients { client.cancel() }
        listener?.cancel()
    }

    func stop() { dropAll(listening: false) }

    deinit { stop() }

    // MARK: - Connections

    private func accept(on listener: Int32) {
        while true {
            let fd = Darwin.accept(listener, nil, nil)
            guard fd >= 0 else { return }
            var yes: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
            setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &yes, socklen_t(MemoryLayout<Int32>.size))
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK)
            let request = RequestBuffer()
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [weak self] in
                var buffer = [UInt8](repeating: 0, count: 4096)
                let count = read(fd, &buffer, buffer.count)
                guard count > 0 else {
                    self?.forget(fd)
                    return
                }
                guard !request.isAnswered else { return }
                request.bytes.append(contentsOf: buffer[..<count])
                if let path = Self.path(ofCompleteRequest: request.bytes) {
                    request.isAnswered = true
                    self?.answer(path, on: fd)
                }
            }
            source.setCancelHandler { close(fd) }
            state.withLock { $0.clients[fd] = source }
            source.resume()
        }
    }

    /// What a connection has sent so far; touched only on the server's queue.
    private final class RequestBuffer: @unchecked Sendable {
        var bytes: [UInt8] = []
        var isAnswered = false
    }

    private func forget(_ fd: Int32) {
        let source = state.withLock { state -> DispatchSourceRead? in
            for key in state.subscribers.keys { state.subscribers[key]?.removeAll { $0 == fd } }
            return state.clients.removeValue(forKey: fd)
        }
        source?.cancel()
    }

    private func answer(_ path: String, on fd: Int32) {
        let value = state.withLock { state -> String? in
            state.connects[path, default: 0] += 1
            return state.values[path]
        }
        if path.hasSuffix("/events") {
            Self.write("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nConnection: keep-alive\r\nTransfer-Encoding: chunked\r\n\r\n", to: fd)
            state.withLock { $0.subscribers[path, default: []].append(fd) }
            if let value { Self.writeEvent(value, to: fd) }
        } else if let value {
            Self.write("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(value.utf8.count)\r\nConnection: close\r\n\r\n\(value)", to: fd)
            forget(fd)
        } else {
            Self.write("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", to: fd)
            forget(fd)
        }
    }

    private static func path(ofCompleteRequest bytes: [UInt8]) -> String? {
        guard let text = String(bytes: bytes, encoding: .utf8), text.contains("\r\n\r\n") else { return nil }
        let parts = text.prefix { $0 != "\r" }.split(separator: " ")
        return parts.count >= 2 ? String(parts[1]) : nil
    }

    /// One SSE event in one HTTP chunk, as Ninjabrain Bot's chunked stream sends it.
    private static func writeEvent(_ json: String, to fd: Int32) {
        let event = "data: \(json)\n\n"
        write(String(event.utf8.count, radix: 16) + "\r\n" + event + "\r\n", to: fd)
    }

    private static func write(_ text: String, to fd: Int32) {
        let bytes = Array(text.utf8)
        var offset = 0
        while offset < bytes.count {
            let written = bytes[offset...].withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
            guard written > 0 else { return }
            offset += written
        }
    }
}
