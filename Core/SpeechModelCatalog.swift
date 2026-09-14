import Foundation

/// Trusted manifest of downloadable local speech models. Every entry pins the
/// exact bytes the app accepts; a download whose SHA-256 differs is discarded.
public struct SpeechModel: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let displayName: String
    public let fileName: String
    public let downloadURL: URL
    public let sizeBytes: Int64
    /// Lowercase hex SHA-256 of the model file. Empty means the catalog entry is
    /// not yet pinned and the model manager must refuse to activate it.
    public let sha256: String
    public let summary: String

    public var isPinned: Bool { !sha256.isEmpty }
    public var sizeDescription: String {
        ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
    }
}

public enum SpeechModelCatalog {
    static let base = URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/")!

    /// Multilingual Whisper models converted to ggml format by the whisper.cpp project.
    /// Digests are recorded in docs/inference.md alongside the benchmark record.
    public static let models: [SpeechModel] = [
        SpeechModel(
            id: "whisper-base",
            displayName: "Whisper Base (multilingual)",
            fileName: "ggml-base.bin",
            downloadURL: base.appendingPathComponent("ggml-base.bin"),
            sizeBytes: 147_951_465,
            sha256: "60ed5bc3dd14eea856493d334349b405782ddcaf0028d4b5df4088345fba2efe",
            summary: "Fastest candidate; intended for older Intel Macs.",
        ),
        SpeechModel(
            id: "whisper-small",
            displayName: "Whisper Small (multilingual)",
            fileName: "ggml-small.bin",
            downloadURL: base.appendingPathComponent("ggml-small.bin"),
            sizeBytes: 487_601_967,
            sha256: "1be3a9b2063867b937e64e2ec7483364a79917e157fa98c5d94b5c1fffea987b",
            summary: "Balanced accuracy and speed candidate.",
        ),
        SpeechModel(
            id: "whisper-small-q5_1",
            displayName: "Whisper Small (quantized)",
            fileName: "ggml-small-q5_1.bin",
            downloadURL: base.appendingPathComponent("ggml-small-q5_1.bin"),
            sizeBytes: 190_085_487,
            sha256: "ae85e4a935d7a567bd102fe55afc16bb595bdb618e11b2fc7591bc08120411bb",
            summary: "Smaller download of Small; quality must be verified before use.",
        ),
    ]

    public static func model(id: String) -> SpeechModel? {
        models.first { $0.id == id }
    }

    /// Provisional recommendation pending physical-hardware benchmarks.
    public static func recommendedModelID(isAppleSilicon: Bool) -> String {
        isAppleSilicon ? "whisper-small" : "whisper-base"
    }
}
