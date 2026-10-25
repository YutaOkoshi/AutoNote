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
        // Task 4: 音声機器の識別子・接続イベントの記録と、抜き差し中のマイク復帰
        .executableTarget(name: "DeviceProbe"),
        .executableTarget(name: "MicHotSwap"),
    ],
    swiftLanguageModes: [.v6]
)
