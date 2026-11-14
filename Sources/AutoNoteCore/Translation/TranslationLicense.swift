import Foundation

/// The PLaMo Community License as AutoNote presents it before the first model download (spec 2). The person
/// accepts `version`; a later license revision (a new `version`) asks again.
public enum TranslationLicense {
    /// The revision shown and accepted (the 2026-11-09 revision read by the research spike).
    public static let version = "2026-11-09"
    public static let licenseURL = URL(string: "https://plamo.preferredai.jp/info/plamo-community-license-ja")!
    public static let registrationURL = URL(string: "https://forms.gle/mTL8tBLrMYXKNZD56")!
    public static let builtWith = "Built with PLaMo"

    public static let title = "PLaMo Community License への同意"

    /// The lines of the consent sheet, in order.
    public static let summary: [String] = [
        "翻訳には Preferred Networks（PFN）の PLaMo 3 Translate を使います。モデルは PFN が Hugging Face で公開しているファイルをそのままダウンロードし、翻訳はこの Mac の中だけで行います（文字起こしも訳文も外に送りません）。",
        "モデルの利用には PLaMo Community License が適用されます。個人・非商用（学術を含む）の利用は無料で、登録は要りません。",
        "業務（社内利用を含む）で使う場合は、PFN への事前登録が必要です。直近の事業年度の売上が 10 億円以下なら登録だけで無料、超える場合は PFN との別途の契約が必要です。",
        "訳文を法律・医療・金融・人物評価などの重要な判断の唯一の根拠にしないでください。",
    ]

    /// Whether the saved acceptance covers the current license.
    public static func isAccepted(_ settings: Settings) -> Bool {
        settings.translationLicenseVersion == version
    }
}
