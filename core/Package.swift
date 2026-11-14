// swift-tools-version:5.9
import PackageDescription
import Foundation

// whisper.cpp is linked as a system library (pkg-config "whisper").
// Set EARSHOT_NO_WHISPER=1 to build without it; earshot-eval then only
// accepts --transcript input (pre-made transcripts) instead of audio.
let noWhisper = ProcessInfo.processInfo.environment["EARSHOT_NO_WHISPER"] == "1"

var targets: [Target] = [
    .target(
        name: "EarshotCore",
        path: "Sources/EarshotCore"
    ),
    .testTarget(
        name: "EarshotCoreTests",
        dependencies: ["EarshotCore"],
        path: "Tests/EarshotCoreTests",
        resources: [.copy("Fixtures")]
    ),
]
var evalDeps: [Target.Dependency] = ["EarshotCore"]

if !noWhisper {
    targets.append(.systemLibrary(
        name: "CWhisper",
        path: "Sources/CWhisper",
        pkgConfig: "whisper",
        providers: [.brew(["whisper-cpp"])]
    ))
    targets.append(.target(
        name: "EarshotWhisper",
        dependencies: ["EarshotCore", "CWhisper"],
        path: "Sources/EarshotWhisper"
    ))
    evalDeps.append("EarshotWhisper")
}

targets.append(.executableTarget(
    name: "earshot-eval",
    dependencies: evalDeps,
    path: "Sources/earshot-eval"
))

let package = Package(
    name: "EarshotCore",
    platforms: [.macOS(.v13), .iOS(.v17)],
    products: [
        .library(name: "EarshotCore", targets: ["EarshotCore"]),
        .executable(name: "earshot-eval", targets: ["earshot-eval"]),
    ] + (noWhisper ? [] : [.library(name: "EarshotWhisper", targets: ["EarshotWhisper"])]),
    targets: targets
)
