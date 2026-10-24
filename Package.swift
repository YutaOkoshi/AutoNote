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
        .target(name: "AutoNoteCore"),
        .executableTarget(name: "AutoNoteApp", dependencies: ["AutoNoteCore"]),
        .executableTarget(name: "autonote", dependencies: ["AutoNoteCore"]),
        .testTarget(name: "AutoNoteCoreTests", dependencies: ["AutoNoteCore"]),
    ],
    swiftLanguageModes: [.v6]
)
