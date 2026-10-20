/// One keyboard or mouse Karabiner sees, as `karabiner_cli --list-connected-devices` reports it.
public struct ConnectedDevice: Hashable, Sendable, Identifiable {
    public let identifiers: DeviceIdentifiers
    public let manufacturer: String
    public let product: String
    public let isBuiltInKeyboard: Bool

    public var id: DeviceIdentifiers { identifiers }
    public var isKeyboard: Bool { identifiers.isKeyboard == true }
    public var isPointingDevice: Bool { identifiers.isPointingDevice == true }

    public init(identifiers: DeviceIdentifiers, manufacturer: String = "", product: String = "", isBuiltInKeyboard: Bool = false) {
        self.identifiers = identifiers
        self.manufacturer = manufacturer
        self.product = product
        self.isBuiltInKeyboard = isBuiltInKeyboard
    }

    /// "Magic Keyboard (keyboard)", "G Pro (mouse)".
    public var displayName: String {
        let name = !product.isEmpty ? product : !manufacturer.isEmpty ? manufacturer : "Unnamed device"
        let kind = isKeyboard ? (isPointingDevice ? "keyboard and mouse" : "keyboard") : "mouse"
        return "\(name) (\(kind))"
    }

    /// Reads the JSON array the CLI prints. Keeps keyboards and mice only, skips Karabiner's own virtual
    /// devices, and lists each set of identifiers once (one device can have several HID interfaces).
    public static func parseList(_ text: String) throws -> [ConnectedDevice] {
        guard let items = try JSONValue.parse(text).arrayValue else {
            throw KarabinerCLIError.unexpectedOutput(text)
        }
        var seen = Set<DeviceIdentifiers>()
        return items.compactMap { item in
            guard let raw = item["device_identifiers"], raw["is_virtual_device"]?.boolValue != true else { return nil }
            let identifiers = DeviceIdentifiers(
                vendorID: raw["vendor_id"]?.intValue,
                productID: raw["product_id"]?.intValue,
                // Absent and false mean the same to Karabiner; nil keeps a created `devices` entry as terse as its own.
                isKeyboard: raw["is_keyboard"]?.boolValue == true ? true : nil,
                isPointingDevice: raw["is_pointing_device"]?.boolValue == true ? true : nil)
            guard identifiers.isKeyboard == true || identifiers.isPointingDevice == true,
                  seen.insert(identifiers).inserted else { return nil }
            return ConnectedDevice(
                identifiers: identifiers,
                manufacturer: item["manufacturer"]?.stringValue ?? "",
                product: item["product"]?.stringValue ?? "",
                isBuiltInKeyboard: item["is_built_in_keyboard"]?.boolValue ?? false)
        }
    }
}

extension KarabinerCLI {
    /// The keyboards and mice Karabiner sees right now (`--list-connected-devices`).
    public func listConnectedDevices() async throws -> [ConnectedDevice] {
        let result = try await succeed(["--list-connected-devices"])
        return try ConnectedDevice.parseList(result.stdout)
    }
}
