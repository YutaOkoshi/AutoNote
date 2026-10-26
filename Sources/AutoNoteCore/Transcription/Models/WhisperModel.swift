import Foundation

/// A downloadable ggml Whisper model.
public struct WhisperModel: Codable, Equatable, Sendable {
    public var name: String
    public var url: URL
    public var sizeBytes: Int64
    public var sha256: String
    public var fileName: String { "ggml-\(name).bin" }

    public init(name: String, url: URL, sizeBytes: Int64, sha256: String) {
        self.name = name
        self.url = url
        self.sizeBytes = sizeBytes
        self.sha256 = sha256
    }

    private enum CodingKeys: String, CodingKey {
        case name, url, sha256
        case sizeBytes = "size_bytes"
    }
}

public enum WhisperModelCatalog {
    private static func entry(_ name: String, _ size: Int64, _ sha256: String) -> WhisperModel {
        WhisperModel(
            name: name,
            url: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-\(name).bin")!,
            sizeBytes: size, sha256: sha256)
    }

    public static let all: [WhisperModel] = [
        entry("base", 147_951_465, "60ed5bc3dd14eea856493d334349b405782ddcaf0028d4b5df4088345fba2efe"),
        entry("small", 487_601_967, "1be3a9b2063867b937e64e2ec7483364a79917e157fa98c5d94b5c1fffea987b"),
        entry("large-v3-turbo", 1_624_555_275, "1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69"),
        entry("large-v3-turbo-q5_0", 574_041_195, "394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2"),
    ]
}
