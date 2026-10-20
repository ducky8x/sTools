/// The shared services every tool controller receives.
@MainActor
public struct ToolServices {
    public let settings: SettingsStore
    public let displays: DisplayDirectory
    public let minecraft: MinecraftLocator
    public let permissions: PermissionCenter

    public init(settings: SettingsStore, displays: DisplayDirectory, minecraft: MinecraftLocator, permissions: PermissionCenter) {
        self.settings = settings
        self.displays = displays
        self.minecraft = minecraft
        self.permissions = permissions
    }
}
