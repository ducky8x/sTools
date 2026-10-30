import Darwin

/// Which app a helper process works for.
///
/// A web page in a `WKWebView` is played by WebKit's own helper processes (web content, graphics and media,
/// networking). They are XPC services that launchd starts, so their parent is launchd (process 1) and there is nothing
/// to follow up the tree, and Core Audio lists them by bundle ID alone (`com.apple.WebKit.GPU`), the same for Safari's
/// tabs as for sTools'. macOS does keep, for every process, the app that asked for it: its *responsible process*. On
/// macOS 27, an app with a web view in an off-screen window had that app named for each of its helpers, and every
/// other app's helpers named their own app.
///
/// No public call reads that. `responsibility_get_pid_responsible_for_pid` is exported by libSystem (libquarantine) and
/// has no header in the SDK, so it is looked up by name when first needed and never linked: a Mac without it says
/// "unknown" for every process, and sTools then records no web sound, never the wrong app's.
enum ProcessResponsibility {
    private typealias Lookup = @convention(c) (pid_t) -> pid_t

    private static let lookup: Lookup? = {
        // RTLD_DEFAULT: look in every image the process has loaded.
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else { return nil }
        return unsafeBitCast(symbol, to: Lookup.self)
    }()

    /// Whether this Mac has the call at all.
    static var isAvailable: Bool { lookup != nil }

    /// The process `pid` works for (itself, for an app), or nil when the system can't say: no such process, or no such
    /// call.
    static func responsiblePID(of pid: pid_t) -> pid_t? {
        guard let lookup else { return nil }
        let responsible = lookup(pid)
        return responsible > 0 ? responsible : nil
    }
}
