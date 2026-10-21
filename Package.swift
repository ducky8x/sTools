// swift-tools-version: 6.0
import PackageDescription

let tools = ["Crosshair", "Backdrop", "NBBOverlay", "KeyRebinder", "ScreenRecording", "Prologue", "TimerOverlay"]

let package = Package(
    name: "sTools",
    platforms: [.macOS(.v15)],
    products: [.executable(name: "sTools", targets: ["sTools"])],
    targets: [
        .target(name: "STDesign", resources: [.copy("Resources")]),
        .target(name: "STPlatform"),
    ]
    + tools.map { name in
        .target(name: name, dependencies: ["STDesign", "STPlatform"],
                resources: name == "KeyRebinder" ? [.copy("Resources")] : [])
    }
    + [
        .executableTarget(name: "sTools", dependencies: ["STDesign", "STPlatform"] + tools.map { .byName(name: $0) }),
        .testTarget(name: "STDesignTests", dependencies: ["STDesign"]),
        .testTarget(name: "STPlatformTests", dependencies: ["STPlatform"]),
        .testTarget(name: "sToolsTests", dependencies: ["sTools"]),
    ]
    + tools.map { name in
        .testTarget(name: "\(name)Tests", dependencies: [.byName(name: name), "STDesign", "STPlatform"])
    }
)
