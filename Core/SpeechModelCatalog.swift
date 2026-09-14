import Foundation

/// Trusted manifest of downloadable local speech models. Every entry pins the
/// exact bytes the app accepts; a download whose SHA-256 differs is discarded.
///
/// Edit `SpeechModels.json` to change the download host, filenames, or digests.
/// An optional absolute `downloadURL` on a model overrides `downloadBaseURL`.
public struct SpeechModel: Hashable, Sendable, Identifiable {
    public let id: String
    public let displayName: String
    public let fileName: String
    public let downloadURL: URL
    public let sizeBytes: Int64
    /// Lowercase hex SHA-256 of the model file. Empty means the catalog entry is
    /// not yet pinned and the model manager must refuse to activate it.
    public let sha256: String
    public let summary: String

    public var isPinned: Bool {
        !sha256.isEmpty
    }

    public var sizeDescription: String {
        ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
    }
}

public enum SpeechModelCatalog {
    public static let downloadBaseURL: URL = document.downloadBaseURL
    public static let models: [SpeechModel] = document.models

    public static func model(id: String) -> SpeechModel? {
        models.first { $0.id == id }
    }

    /// Provisional recommendation pending physical-hardware benchmarks.
    public static func recommendedModelID(isAppleSilicon: Bool) -> String {
        isAppleSilicon ? document.recommendedAppleSilicon : document.recommendedIntel
    }

    private static let document: Document = {
        guard let url = catalogURL() else {
            preconditionFailure("SpeechModels.json is missing from the application bundle.")
        }
        do {
            return try Document(data: Data(contentsOf: url))
        } catch {
            preconditionFailure("SpeechModels.json is invalid: \(error)")
        }
    }()

    private static func catalogURL() -> URL? {
        #if SWIFT_PACKAGE
            if let url = Bundle.module.url(forResource: "SpeechModels", withExtension: "json") {
                return url
            }
        #endif
        if let url = Bundle.main.url(forResource: "SpeechModels", withExtension: "json") {
            return url
        }
        for bundle in Bundle.allBundles {
            if let url = bundle.url(forResource: "SpeechModels", withExtension: "json") {
                return url
            }
        }
        return nil
    }
}

private struct Document {
    let downloadBaseURL: URL
    let recommendedAppleSilicon: String
    let recommendedIntel: String
    let models: [SpeechModel]

    init(data: Data) throws {
        let raw = try JSONDecoder().decode(RawDocument.self, from: data)
        guard raw.schemaVersion == 1 else {
            throw CatalogError.unsupportedSchema(raw.schemaVersion)
        }
        guard let base = URL(string: raw.downloadBaseURL), base.scheme == "https" else {
            throw CatalogError.invalidDownloadBaseURL
        }
        downloadBaseURL = base
        recommendedAppleSilicon = raw.recommendedAppleSilicon
        recommendedIntel = raw.recommendedIntel
        models = try raw.models.map { try SpeechModel(raw: $0, baseURL: base) }
        for id in [recommendedAppleSilicon, recommendedIntel] where model(id: id) == nil {
            throw CatalogError.unknownRecommendedID(id)
        }
    }

    private func model(id: String) -> SpeechModel? {
        models.first { $0.id == id }
    }
}

private struct RawDocument: Decodable {
    let schemaVersion: Int
    let downloadBaseURL: String
    let recommendedAppleSilicon: String
    let recommendedIntel: String
    let models: [RawModel]
}

private struct RawModel: Decodable {
    let id: String
    let displayName: String
    let fileName: String
    let downloadURL: String?
    let sizeBytes: Int64
    let sha256: String
    let summary: String
}

private enum CatalogError: Error, CustomStringConvertible {
    case unsupportedSchema(Int)
    case invalidDownloadBaseURL
    case invalidModelURL(String)
    case unknownRecommendedID(String)

    var description: String {
        switch self {
        case let .unsupportedSchema(version): "unsupported schemaVersion \(version)"
        case .invalidDownloadBaseURL: "downloadBaseURL must be an https URL"
        case let .invalidModelURL(id): "model \(id) has an invalid downloadURL"
        case let .unknownRecommendedID(id): "recommended model \(id) is not in the catalog"
        }
    }
}

private extension SpeechModel {
    init(raw: RawModel, baseURL: URL) throws {
        let url: URL
        if let override = raw.downloadURL {
            guard let parsed = URL(string: override), parsed.scheme == "https" else {
                throw CatalogError.invalidModelURL(raw.id)
            }
            url = parsed
        } else {
            url = baseURL.appendingPathComponent(raw.fileName)
        }
        id = raw.id
        displayName = raw.displayName
        fileName = raw.fileName
        downloadURL = url
        sizeBytes = raw.sizeBytes
        sha256 = raw.sha256
        summary = raw.summary
    }
}
