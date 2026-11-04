import Darwin
import Foundation

/// What a `KERN_PROCARGS2` buffer holds: the executable path as it was started, argv, and the environment (empty when
/// macOS hides it, as it does for its own programs).
struct NBBProcArgs: Equatable {
    var executablePath: String
    var arguments: [String]
    var environment: [String]
}

/// How a Ninjabrain Bot copy was started, read from the process table when a restart begins: its executable
/// (`proc_pidpath`), argv with argv[0], its environment and its folder. A restart starts exactly this again.
///
/// The environment holds whatever the person's shell had, so a launch is never logged, never kept after its restart
/// and never in Copy Diagnostics. Its description and mirror leave the environment out.
struct NBBLaunch: Equatable, Sendable {
    var executablePath: String
    var arguments: [String]
    /// `NAME=value` entries, in the order the process got them.
    var environment: [String]
    var workingDirectory: String
}

extension NBBLaunch: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    var description: String {
        "NBBLaunch(executablePath: \(executablePath), arguments: \(arguments.count), workingDirectory: \(workingDirectory))"
    }

    var debugDescription: String { description }

    var customMirror: Mirror {
        Mirror(self, children: ["executablePath": executablePath, "arguments": arguments, "workingDirectory": workingDirectory])
    }
}
