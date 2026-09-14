import Foundation

/// Versioned, bounded messages exchanged with the XPC worker as JSON `Data`.
/// The worker never receives whole recordings or model bytes, only validated
/// file paths and a source time range.
public enum TranscriptionProtocol {
    public static let version = 1
    public static let maximumChunkSeconds: TimeInterval = 600
    /// Failure string the worker returns when a job was cancelled on request.
    public static let cancelledMessage = "Transcription was cancelled."

    public enum MessageError: Error, Equatable {
        case unsupportedVersion(Int)
        case invalidRange
        case chunkTooLong
        case notFileURL
    }
}

public struct ChunkTranscriptionRequest: Codable, Sendable, Equatable {
    public let protocolVersion: Int
    public let jobID: UUID
    public let chunkIndex: Int
    public let audioPath: String
    public let audioStart: TimeInterval
    public let audioEnd: TimeInterval
    public let modelPath: String
    public let modelID: String
    /// ISO 639-1 code or "auto".
    public let language: String
    /// 0 lets the engine pick a bounded default.
    public let threads: Int
    public let useGPU: Bool

    public init(jobID: UUID, chunk: AudioChunk, audioURL: URL, modelURL: URL, modelID: String,
                language: String = "auto", threads: Int = 0, useGPU: Bool = true) throws
    {
        guard audioURL.isFileURL, modelURL.isFileURL else { throw TranscriptionProtocol.MessageError.notFileURL }
        guard chunk.audioStart.isFinite, chunk.audioEnd.isFinite, chunk.audioStart >= 0,
              chunk.audioEnd > chunk.audioStart
        else { throw TranscriptionProtocol.MessageError.invalidRange }
        guard chunk.audioDuration <= TranscriptionProtocol.maximumChunkSeconds else {
            throw TranscriptionProtocol.MessageError.chunkTooLong
        }
        protocolVersion = TranscriptionProtocol.version
        self.jobID = jobID
        chunkIndex = chunk.index
        audioPath = audioURL.path
        audioStart = chunk.audioStart
        audioEnd = chunk.audioEnd
        modelPath = modelURL.path
        self.modelID = modelID
        self.language = language
        self.threads = threads
        self.useGPU = useGPU
    }

    public func validate() throws {
        guard protocolVersion == TranscriptionProtocol.version else {
            throw TranscriptionProtocol.MessageError.unsupportedVersion(protocolVersion)
        }
        guard audioStart.isFinite, audioEnd.isFinite, audioStart >= 0, audioEnd > audioStart else {
            throw TranscriptionProtocol.MessageError.invalidRange
        }
        guard audioEnd - audioStart <= TranscriptionProtocol.maximumChunkSeconds else {
            throw TranscriptionProtocol.MessageError.chunkTooLong
        }
    }
}

public struct ChunkMetrics: Codable, Sendable, Equatable {
    public var audioSeconds: TimeInterval
    public var decodeMilliseconds: Double
    public var modelLoadMilliseconds: Double
    public var inferenceMilliseconds: Double
    /// Worker process physical footprint after the chunk, in bytes.
    public var workerFootprintBytes: UInt64

    public init(audioSeconds: TimeInterval, decodeMilliseconds: Double, modelLoadMilliseconds: Double,
                inferenceMilliseconds: Double, workerFootprintBytes: UInt64)
    {
        self.audioSeconds = audioSeconds
        self.decodeMilliseconds = decodeMilliseconds
        self.modelLoadMilliseconds = modelLoadMilliseconds
        self.inferenceMilliseconds = inferenceMilliseconds
        self.workerFootprintBytes = workerFootprintBytes
    }

    public var realTimeFactor: Double {
        audioSeconds > 0 ? (decodeMilliseconds + inferenceMilliseconds) / 1000 / audioSeconds : 0
    }
}

public struct ChunkTranscriptionResult: Codable, Sendable, Equatable {
    public let protocolVersion: Int
    public let jobID: UUID
    public let chunkIndex: Int
    public let segments: [RawSegment]
    public let detectedLanguage: String?
    public let engineVersion: String
    public let modelID: String
    public let metrics: ChunkMetrics

    public init(jobID: UUID, chunkIndex: Int, segments: [RawSegment], detectedLanguage: String?,
                engineVersion: String, modelID: String, metrics: ChunkMetrics)
    {
        protocolVersion = TranscriptionProtocol.version
        self.jobID = jobID
        self.chunkIndex = chunkIndex
        self.segments = segments
        self.detectedLanguage = detectedLanguage
        self.engineVersion = engineVersion
        self.modelID = modelID
        self.metrics = metrics
    }
}

public struct EngineDescription: Codable, Sendable, Equatable {
    public let protocolVersion: Int
    public let engineName: String
    public let engineVersion: String
    public let systemInfo: String
    public let gpuAvailable: Bool

    public init(engineName: String, engineVersion: String, systemInfo: String, gpuAvailable: Bool) {
        protocolVersion = TranscriptionProtocol.version
        self.engineName = engineName
        self.engineVersion = engineVersion
        self.systemInfo = systemInfo
        self.gpuAvailable = gpuAvailable
    }
}

public extension Duration {
    var milliseconds: Double {
        Double(components.seconds) * 1000 + Double(components.attoseconds) / 1e15
    }
}

public enum MessageCoding {
    public static func encode(_ value: some Encodable) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try JSONDecoder().decode(type, from: data)
    }
}

/// Bootstrap plus versioned inference messages. Replies carry either encoded
/// results or a user-presentable failure string; never audio or model bytes.
@objc public protocol TranscriptionWorkerProtocol {
    func checkReadiness(reply: @escaping @Sendable (Bool, String) -> Void)
    func describeEngine(reply: @escaping @Sendable (Data?, String?) -> Void)
    func transcribeChunk(_ request: Data, reply: @escaping @Sendable (Data?, String?) -> Void)
    func cancel(jobID: String)
    func unloadModel(reply: @escaping @Sendable () -> Void)
}

public enum WorkerIdentity {
    public static let serviceName = "com.wordy.app.TranscriptionService"
}
