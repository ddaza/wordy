import Foundation

/// Machine-readable benchmark output shared by `wordy-bench` and the app.
/// Hardware, OS, engine, model, policy, and conditions travel with the numbers
/// so results are never quoted without them.
public struct BenchmarkRecord: Codable, Sendable {
    public struct Chunk: Codable, Sendable {
        public let index: Int
        public let audioSeconds: Double
        public let decodeMilliseconds: Double
        public let inferenceMilliseconds: Double
        public let committedSegments: Int
        public let footprintBytes: UInt64

        public init(index: Int, audioSeconds: Double, decodeMilliseconds: Double, inferenceMilliseconds: Double,
                    committedSegments: Int, footprintBytes: UInt64)
        {
            self.index = index
            self.audioSeconds = audioSeconds
            self.decodeMilliseconds = decodeMilliseconds
            self.inferenceMilliseconds = inferenceMilliseconds
            self.committedSegments = committedSegments
            self.footprintBytes = footprintBytes
        }
    }

    public let recordedAt: Date
    public let source: String
    public let hardware: String
    public let operatingSystem: String
    public let buildConfiguration: String
    public let engineName: String
    public let engineVersion: String
    public let systemInfo: String
    public let gpuRequested: Bool
    public let threads: Int
    public let modelID: String
    public let policy: String
    public let language: String
    public let audioSHA256: String
    public let sourceDuration: Double
    public let processedSeconds: Double
    public let modelLoadMilliseconds: Double
    public let firstResultMilliseconds: Double
    public let wallMilliseconds: Double
    public let realTimeFactor: Double
    public let peakFootprintBytes: UInt64
    public let segmentCount: Int
    /// App-only: worst and 95th-percentile main-thread scheduling delay observed
    /// while the job ran, in milliseconds.
    public let mainThreadMaxDelayMilliseconds: Double?
    public let mainThreadP95DelayMilliseconds: Double?
    public let notes: String?
    public let chunks: [Chunk]

    public init(recordedAt: Date, source: String, hardware: String, operatingSystem: String, buildConfiguration: String,
                engineName: String, engineVersion: String, systemInfo: String, gpuRequested: Bool, threads: Int,
                modelID: String, policy: String, language: String, audioSHA256: String, sourceDuration: Double,
                processedSeconds: Double, modelLoadMilliseconds: Double, firstResultMilliseconds: Double,
                wallMilliseconds: Double, realTimeFactor: Double, peakFootprintBytes: UInt64, segmentCount: Int,
                mainThreadMaxDelayMilliseconds: Double? = nil, mainThreadP95DelayMilliseconds: Double? = nil,
                notes: String? = nil, chunks: [Chunk])
    {
        self.recordedAt = recordedAt
        self.source = source
        self.hardware = hardware
        self.operatingSystem = operatingSystem
        self.buildConfiguration = buildConfiguration
        self.engineName = engineName
        self.engineVersion = engineVersion
        self.systemInfo = systemInfo
        self.gpuRequested = gpuRequested
        self.threads = threads
        self.modelID = modelID
        self.policy = policy
        self.language = language
        self.audioSHA256 = audioSHA256
        self.sourceDuration = sourceDuration
        self.processedSeconds = processedSeconds
        self.modelLoadMilliseconds = modelLoadMilliseconds
        self.firstResultMilliseconds = firstResultMilliseconds
        self.wallMilliseconds = wallMilliseconds
        self.realTimeFactor = realTimeFactor
        self.peakFootprintBytes = peakFootprintBytes
        self.segmentCount = segmentCount
        self.mainThreadMaxDelayMilliseconds = mainThreadMaxDelayMilliseconds
        self.mainThreadP95DelayMilliseconds = mainThreadP95DelayMilliseconds
        self.notes = notes
        self.chunks = chunks
    }

    public static func write(_ record: BenchmarkRecord, to directory: URL, baseName: String) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let url = directory.appendingPathComponent("\(baseName).json")
        try encoder.encode(record).write(to: url, options: .atomic)
        return url
    }

    public static func fileStamp(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date).replacingOccurrences(of: ":", with: "-")
    }
}

public enum HostDescription {
    public static func hardware() -> String {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        var brand = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("machdep.cpu.brand_string", &brand, &size, nil, 0)
        let cpu = brand.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        let memory = ByteCountFormatter.string(fromByteCount: Int64(ProcessInfo.processInfo.physicalMemory),
                                               countStyle: .memory)
        #if arch(arm64)
            let arch = "arm64"
        #else
            let arch = "x86_64"
        #endif
        return "\(cpu.isEmpty ? "Unknown CPU" : cpu) · \(arch) · \(ProcessInfo.processInfo.activeProcessorCount) cores · \(memory)"
    }

    public static func operatingSystem() -> String {
        "macOS \(ProcessInfo.processInfo.operatingSystemVersionString)"
    }

    public static var isAppleSilicon: Bool {
        #if arch(arm64)
            true
        #else
            false
        #endif
    }
}
