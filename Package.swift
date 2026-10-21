// swift-tools-version: 6.0
import PackageDescription

let tools = ["Crosshair", "Backdrop", "NBBOverlay", "KeyRebinder", "ScreenRecording", "Prologue"]

let package = Package(
    name: "sTools",
    platforms: [.macOS(.v15)],
    products: [.executable(name: "sTools", targets: ["sTools"])],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", .upToNextMajor(from: "2.6.0")),
    ],
    targets: [
        .target(name: "STDesign", resources: [.copy("Resources")]),
        .target(name: "STPlatform"),
    ]
    + tools.map { name in
        .target(name: name, dependencies: ["STDesign", "STPlatform"],
                resources: name == "KeyRebinder" ? [.copy("Resources")] : [])
    }
    + [
        .executableTarget(
            name: "sTools",
            dependencies: ["STDesign", "STPlatform", .product(name: "Sparkle", package: "Sparkle")] + tools.map { .byName(name: $0) },
            // Sparkle.framework is embedded in the app's Contents/Frameworks by scripts/build-app.sh.
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
        .testTarget(name: "STDesignTests", dependencies: ["STDesign"]),
        .testTarget(name: "STPlatformTests", dependencies: ["STPlatform"]),
        .testTarget(name: "sToolsTests", dependencies: ["sTools"]),
    ]
    + tools.map { name in
        .testTarget(name: "\(name)Tests", dependencies: [.byName(name: name), "STDesign", "STPlatform"])
    }
)
