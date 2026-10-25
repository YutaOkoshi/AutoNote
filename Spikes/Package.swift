// swift-tools-version: 6.2
// 計画 00 のスパイク集。使い捨てのコードで、本体パッケージ（../Sources）からは import しない。
// 後続タスクは targets に .executableTarget を一つずつ足していく。
import PackageDescription

/// このファイルのあるディレクトリ（末尾 / 付き）。リンカーに渡すパスを作業ディレクトリに依存させないため。
let packageDir = String(#filePath.dropLast("Package.swift".count))

let package = Package(
    name: "Spikes",
    platforms: [.macOS("26.0")],
    targets: [
        // Task 3: Core Audio process tap でシステム音声を受信する
        .executableTarget(name: "TapCapture"),
        // Task 4: 音声機器の識別子・接続イベントの記録と、抜き差し中のマイク復帰
        .executableTarget(name: "DeviceProbe"),
        .executableTarget(name: "MicHotSwap"),
        // Task 6: Apple Speech（DictationTranscriber / SFSpeechRecognizer / SpeechTranscriber）の日本語
        //   SFSpeechRecognizer.requestAuthorization は Info.plist に NSSpeechRecognitionUsageDescription が無いと
        //   TCC が SIGABRT で落とす（実測）。コマンドラインツールなので __TEXT,__info_plist に埋め込む。
        .executableTarget(
            name: "AppleSpeechProbe",
            exclude: ["Info.plist"],
            linkerSettings: [.unsafeFlags([
                "-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist",
                "-Xlinker", packageDir + "Sources/AppleSpeechProbe/Info.plist",
            ])]
        ),
    ],
    swiftLanguageModes: [.v6]
)
