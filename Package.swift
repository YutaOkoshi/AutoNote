// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "AutoNote",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "AutoNoteCore", targets: ["AutoNoteCore"]),
        .executable(name: "AutoNoteApp", targets: ["AutoNoteApp"]),
        .executable(name: "autonote", targets: ["autonote"]),
    ],
    targets: [
        // scripts/build-whisper-xcframework.sh が tools/whisper.cpp（v1.9.5）から作る（x86_64 は AVX2/FMA/F16C 付き）
        .binaryTarget(name: "whisper", path: "tools/whisper.xcframework"),
        .target(name: "AutoNoteCore", dependencies: ["whisper"]),
        .executableTarget(name: "AutoNoteApp", dependencies: ["AutoNoteCore"]),
        .target(name: "AutoNoteTestSupport", dependencies: ["AutoNoteCore"]),
        .executableTarget(name: "autonote", dependencies: ["AutoNoteCore", "AutoNoteTestSupport"]),
        .testTarget(name: "AutoNoteCoreTests", dependencies: ["AutoNoteCore", "AutoNoteTestSupport"]),
    ],
    swiftLanguageModes: [.v6]
)
