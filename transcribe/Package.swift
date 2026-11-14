// swift-tools-version:5.9
import PackageDescription

// Audio in, transcript lines with confidence out. Nothing else: no clean-up, no rules, no reports.
// whisper.xcframework is not in the repo: run ./fetch.sh once to build it and download the model.
let package = Package(
    name: "Transcribe",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "Transcribe", targets: ["Transcribe"])],
    targets: [
        .binaryTarget(name: "whisper", path: "Frameworks/whisper.xcframework"),
        .target(name: "Transcribe", dependencies: ["whisper"], resources: [.copy("Resources/drugs.txt")]),
        // Mac only: transcribes a WAV file and prints the lines, to check and time the module without an iPad.
        .executableTarget(name: "transcribe-wav", dependencies: ["Transcribe"]),
        .testTarget(name: "TranscribeTests", dependencies: ["Transcribe"]),
    ]
)
