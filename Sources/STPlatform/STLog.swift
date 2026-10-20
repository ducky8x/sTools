import OSLog

public enum STLog {
    public static let subsystem = "com.ducky8x.sTools"
    public static func logger(_ category: String) -> Logger { Logger(subsystem: subsystem, category: category) }
}
