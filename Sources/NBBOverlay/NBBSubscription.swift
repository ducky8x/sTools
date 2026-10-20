import Foundation

/// Keeps one SSE subscription alive: connects, parses and dispatches events, and reconnects with
/// backoff on any failure or clean close — until cancelled (spec 5.1.2). Any dispatched event resets
/// the backoff, since it proves the connection is good again.
actor NBBSubscription {
    private let url: URL
    private let source: any NBBEventSource
    private(set) var isConnected = false

    init(url: URL, source: any NBBEventSource) {
        self.url = url
        self.source = source
    }

    /// Runs until the calling `Task` is cancelled. `onEvent` fires for each dispatched payload;
    /// `onConnectionChange` (if given) fires whenever connect/disconnect state changes.
    func run(onEvent: @escaping @Sendable (String) -> Void, onConnectionChange: (@Sendable (Bool) -> Void)? = nil) async {
        var backoffSeconds = NBBBackoff.initialSeconds
        while !Task.isCancelled {
            do {
                let stream = try await source.connect(to: url)
                isConnected = true
                onConnectionChange?(true)
                var parser = SSEParser()
                for try await byte in stream {
                    for event in parser.feed([byte]) {
                        onEvent(event)
                        backoffSeconds = NBBBackoff.initialSeconds
                    }
                }
            } catch is CancellationError {
                break
            } catch {
                // Falls through to the backoff/retry below.
            }
            isConnected = false
            onConnectionChange?(false)
            guard !Task.isCancelled else { break }
            try? await Task.sleep(for: .seconds(backoffSeconds))
            backoffSeconds = NBBBackoff.next(afterSeconds: backoffSeconds)
        }
        isConnected = false
    }
}
