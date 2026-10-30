// swift-tools-version: 6.0
import PackageDescription

let tools = ["Crosshair", "Backdrop", "NBBOverlay", "KeyRebinder", "ScreenRecording", "Prologue", "TimerOverlay"]

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
        // Measures a recording's CPU cost with fake sources (`swift run -c release RecordingBench`); never shipped.
        .executableTarget(name: "RecordingBench", dependencies: ["ScreenRecording", "STPlatform"], path: "Benchmarks/RecordingBench"),
        // Measures what watching Ninjabrain Bot costs: the copies scan and a window read (`swift run -c release NBBBench`);
        // reads only, never shipped.
        .executableTarget(name: "NBBBench", dependencies: ["NBBOverlay"], path: "Benchmarks/NBBBench"),
        // Measures what an animated Window Backdrop fill costs while it plays: CPU, GPU and memory, for videos and GIFs
        // it makes itself, in a window that never shows (`swift run -c release BackdropBench`); never shipped.
        .executableTarget(name: "BackdropBench", dependencies: ["Backdrop", "STPlatform"], path: "Benchmarks/BackdropBench"),
        .testTarget(name: "STDesignTests", dependencies: ["STDesign"]),
        .testTarget(name: "STPlatformTests", dependencies: ["STPlatform"]),
        // The test bundle finds Sparkle.framework next to it in the build folder.
        .testTarget(name: "sToolsTests", dependencies: ["sTools"],
                    linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@loader_path/../../.."])]),
    ]
    + tools.map { name in
        .testTarget(name: "\(name)Tests", dependencies: [.byName(name: name), "STDesign", "STPlatform"])
    }
)
