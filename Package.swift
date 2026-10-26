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
        .binaryTarget(
            name: "whisper",
            url: "https://github.com/ggml-org/whisper.cpp/releases/download/b5454/whisper-b5454-xcframework.zip",
            checksum: "e57f8c48933000acabc13bb913fbe82805d483a2deff692cc6738836bd92393b"),
        .target(name: "AutoNoteCore", dependencies: ["whisper"]),
        .executableTarget(name: "AutoNoteApp", dependencies: ["AutoNoteCore"]),
        .target(name: "AutoNoteTestSupport", dependencies: ["AutoNoteCore"]),
        .executableTarget(name: "autonote", dependencies: ["AutoNoteCore", "AutoNoteTestSupport"]),
        .testTarget(name: "AutoNoteCoreTests", dependencies: ["AutoNoteCore", "AutoNoteTestSupport"]),
    ],
    swiftLanguageModes: [.v6]
)
