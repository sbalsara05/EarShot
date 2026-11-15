// swift-tools-version:5.9
import PackageDescription

// Transcript in, NEMSIS answers out, each with the line it came from. A language model proposes; code decides.
// llama.xcframework and the model are not in the repo: run ./fetch.sh once.
let package = Package(
    name: "Fill",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "Fill", targets: ["Fill"])],
    targets: [
        .binaryTarget(name: "llama", path: "Frameworks/llama.xcframework"),
        .target(name: "Fill", dependencies: ["llama"], resources: [.copy("Resources/drugs.txt")]),
        // Mac only: fills a report from a transcript file and scores it against the right answers.
        .executableTarget(name: "fill-transcript", dependencies: ["Fill"]),
        .testTarget(name: "FillTests", dependencies: ["Fill"]),
    ]
)
