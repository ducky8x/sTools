import Darwin
import Foundation

/// Finds the folder a running Minecraft keeps its `options.txt` in (spec 5.5.2): the `--gameDir` the launcher
/// passed (the official launcher does), else the Java process's working directory (Prism and MultiMC start
/// the game inside the instance folder and hand the arguments over another way).
public enum MinecraftGameDirectory {
    public static func find(processID: Int32) -> URL? {
        if let arguments = arguments(processID: processID), let directory = fromArguments(arguments) { return directory }
        return workingDirectory(processID: processID)
    }

    /// The value of `--gameDir <path>` or `--gameDir=<path>`; the last one wins, as in Minecraft's own parser.
    public static func fromArguments(_ arguments: [String]) -> URL? {
        var found: String?
        var index = arguments.startIndex
        while index < arguments.endIndex {
            let argument = arguments[index]
            if argument == "--gameDir", index + 1 < arguments.endIndex {
                found = arguments[index + 1]
                index += 2
                continue
            }
            if argument.hasPrefix("--gameDir=") { found = String(argument.dropFirst("--gameDir=".count)) }
            index += 1
        }
        guard let found, !found.isEmpty else { return nil }
        return URL(fileURLWithPath: (found as NSString).expandingTildeInPath, isDirectory: true)
    }

    /// The process's command line, from the kernel (`KERN_PROCARGS2`). Works for processes of the same user.
    public static func arguments(processID: Int32) -> [String]? {
        var argumentMax: Int32 = 0
        var argumentMaxSize = MemoryLayout<Int32>.size
        var maxQuery: [Int32] = [CTL_KERN, KERN_ARGMAX]
        guard sysctl(&maxQuery, 2, &argumentMax, &argumentMaxSize, nil, 0) == 0, argumentMax > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: Int(argumentMax))
        var size = buffer.count
        var query: [Int32] = [CTL_KERN, KERN_PROCARGS2, processID]
        guard sysctl(&query, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        return parseProcessArguments(Array(buffer.prefix(size)))
    }

    /// Reads a `KERN_PROCARGS2` buffer: `argc` as a 32-bit integer, the executable path, padding, then `argc`
    /// NUL-terminated arguments (the environment follows and is ignored).
    static func parseProcessArguments(_ bytes: [UInt8]) -> [String]? {
        guard bytes.count >= 4 else { return nil }
        let count = Int(bytes[0..<4].withUnsafeBytes { $0.loadUnaligned(as: Int32.self) })
        guard count >= 0 else { return nil }
        var index = 4
        while index < bytes.count, bytes[index] != 0 { index += 1 }
        while index < bytes.count, bytes[index] == 0 { index += 1 }
        var arguments: [String] = []
        while arguments.count < count, index < bytes.count {
            let start = index
            while index < bytes.count, bytes[index] != 0 { index += 1 }
            arguments.append(String(decoding: bytes[start..<index], as: UTF8.self))
            index += 1
        }
        return arguments.count == count ? arguments : nil
    }

    /// The process's current directory (`proc_pidinfo`, `PROC_PIDVNODEPATHINFO`).
    public static func workingDirectory(processID: Int32) -> URL? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(processID, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: info.pvi_cdir.vip_path) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        guard !path.isEmpty, path != "/" else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }
}
