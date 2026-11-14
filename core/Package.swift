// swift-tools-version:5.9
import PackageDescription
import Foundation

// whisper.cpp is linked as a system library (pkg-config "whisper").
// Set EARSHOT_NO_WHISPER=1 to build without it; earshot-eval then only
// accepts --transcript input (pre-made transcripts) instead of audio.
let noWhisper = ProcessInfo.processInfo.environment["EARSHOT_NO_WHISPER"] == "1"
// libopus (pkg-config "opus") decodes the clip's Opus frames for the eval tool. The iPad app uses
// AVAudioConverter instead. Set EARSHOT_NO_OPUS=1 to build without it.
let noOpus = ProcessInfo.processInfo.environment["EARSHOT_NO_OPUS"] == "1"

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

if !noOpus {
    targets.append(.systemLibrary(
        name: "COpus",
        path: "Sources/COpus",
        pkgConfig: "opus",
        providers: [.brew(["opus"]), .apt(["libopus-dev"])]
    ))
    targets.append(.target(
        name: "EarshotOpus",
        dependencies: ["EarshotCore", "COpus"],
        path: "Sources/EarshotOpus"
    ))
    targets.append(.testTarget(
        name: "EarshotOpusTests",
        dependencies: ["EarshotOpus"],
        path: "Tests/EarshotOpusTests"
    ))
    evalDeps.append("EarshotOpus")
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
    ] + (noWhisper ? [] : [.library(name: "EarshotWhisper", targets: ["EarshotWhisper"])])
      + (noOpus ? [] : [.library(name: "EarshotOpus", targets: ["EarshotOpus"])]),
    targets: targets
)
