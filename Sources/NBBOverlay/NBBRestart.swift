import Darwin
import Foundation

/// Restarts copies for real: reads their launch from the process table and starts them again with `posix_spawn`.
struct LiveNBBCopiesRestarter {
    /// Whether `launch` can be started again: its program is still there and runnable, and so is its folder.
    static func canStart(_ launch: NBBLaunch) -> Bool {
        var isFolder: ObjCBool = false
        let files = FileManager.default
        return files.isExecutableFile(atPath: launch.executablePath)
            && files.fileExists(atPath: launch.executablePath, isDirectory: &isFolder) && !isFolder.boolValue
            && files.fileExists(atPath: launch.workingDirectory, isDirectory: &isFolder) && isFolder.boolValue
    }
}
