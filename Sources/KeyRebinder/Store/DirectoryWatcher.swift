import Foundation

/// Calls `onChange` on the main queue whenever an entry in `directory` is written, renamed or removed: an
/// atomic save (write a temporary file, rename it over the old one) shows up as a change of its folder.
final class DirectoryWatcher {
    private let source: any DispatchSourceFileSystemObject

    init?(directory: URL, onChange: @escaping @Sendable () -> Void) {
        let descriptor = open(directory.path, O_EVTONLY)
        guard descriptor >= 0 else { return nil }
        source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .rename, .delete], queue: .main)
        source.setEventHandler(handler: onChange)
        source.setCancelHandler { close(descriptor) }
        source.resume()
    }

    deinit {
        source.cancel()
    }
}
