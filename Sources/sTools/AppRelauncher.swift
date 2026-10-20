import AppKit
import STPlatform

/// Quits sTools and opens it again once this process has gone: for permissions macOS applies only to a fresh
/// launch (spec 4.2, J3) and after Reset sTools.
@MainActor
enum AppRelauncher {
    static func relaunch() {
        let pid = ProcessInfo.processInfo.processIdentifier
        let bundle = Bundle.main.bundleURL
        let reopen = bundle.pathExtension == "app"
            ? "/usr/bin/open \(quoted(bundle.path))"
            : "\(quoted(Bundle.main.executablePath ?? "")) >/dev/null 2>&1 &"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "while /bin/kill -0 \(pid) 2>/dev/null; do /bin/sleep 0.2; done; \(reopen)"]
        do {
            try process.run()
        } catch {
            STLog.logger("Relaunch").error("Could not schedule the relaunch: \(error.localizedDescription, privacy: .public)")
            return
        }
        NSApp.terminate(nil)
    }

    private static func quoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
