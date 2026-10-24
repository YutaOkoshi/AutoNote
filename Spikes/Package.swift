// swift-tools-version: 6.2
// 計画 00 のスパイク集。使い捨てのコードで、本体パッケージ（../Sources）からは import しない。
// 後続タスクは targets に .executableTarget を一つずつ足していく。
import PackageDescription

let package = Package(
    name: "Spikes",
    platforms: [.macOS("26.0")],
    targets: [
        // Task 3: Core Audio process tap でシステム音声を受信する
        .executableTarget(name: "TapCapture"),
    ],
    swiftLanguageModes: [.v6]
)
