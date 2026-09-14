import AVFoundation
import Foundation

/// 16 kHz mono float samples for one chunk, with the real presentation time of
/// the first sample so results map back to the original timeline even when the
/// reader starts slightly off the requested position.
struct DecodedAudio: Sendable {
    static let sampleRate: Double = 16000
    let samples: [Float]
    let startTime: TimeInterval

    var duration: TimeInterval {
        Double(samples.count) / Self.sampleRate
    }
}

enum AudioDecodingError: LocalizedError {
    case noAudioTrack
    case readerFailed(String)
    case emptyOutput

    var errorDescription: String? {
        switch self {
        case .noAudioTrack: "The recording does not contain a readable audio track."
        case let .readerFailed(reason): "Audio could not be decoded: \(reason)"
        case .emptyOutput: "The requested audio range produced no samples."
        }
    }
}

/// Wraps AVFoundation objects that are created in one context and then used
/// exclusively on the inference queue.
final class PreparedAudioSource: @unchecked Sendable {
    let asset: AVURLAsset
    let track: AVAssetTrack

    init(asset: AVURLAsset, track: AVAssetTrack) {
        self.asset = asset
        self.track = track
    }
}

enum AudioChunkDecoder {
    static func outputSettings() -> [String: Any] {
        [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: DecodedAudio.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
    }

    /// Loads track metadata asynchronously; nothing is decoded yet.
    static func prepare(url: URL) async throws -> PreparedAudioSource {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw AudioDecodingError.noAudioTrack
        }
        return PreparedAudioSource(asset: asset, track: track)
    }

    /// Blocking decode of [start, end). Call from a dedicated background queue.
    /// Peak memory is bounded by the chunk length: 16 kHz × 4 bytes × seconds.
    static func decode(_ source: PreparedAudioSource, start: TimeInterval, end: TimeInterval,
                       isCancelled: () -> Bool = { false }) throws -> DecodedAudio
    {
        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: source.asset)
        } catch {
            throw AudioDecodingError.readerFailed(error.localizedDescription)
        }
        let output = AVAssetReaderTrackOutput(track: source.track, outputSettings: outputSettings())
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw AudioDecodingError.readerFailed("unsupported output format") }
        reader.add(output)
        let timescale: CMTimeScale = 48000
        reader.timeRange = CMTimeRange(
            start: CMTime(seconds: start, preferredTimescale: timescale),
            end: CMTime(seconds: end, preferredTimescale: timescale),
        )
        guard reader.startReading() else {
            throw AudioDecodingError.readerFailed(reader.error?.localizedDescription ?? "reader did not start")
        }
        defer { reader.cancelReading() }

        let expected = Int((end - start) * DecodedAudio.sampleRate) + 4096
        var samples: [Float] = []
        samples.reserveCapacity(expected)
        var firstTimestamp: TimeInterval?

        while let buffer = output.copyNextSampleBuffer() {
            if isCancelled() {
                throw CancellationError()
            }
            if firstTimestamp == nil {
                let presentation = CMSampleBufferGetOutputPresentationTimeStamp(buffer)
                firstTimestamp = presentation.isNumeric ? presentation.seconds : start
            }
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            guard length > 0 else { continue }
            let count = length / MemoryLayout<Float>.size
            let previous = samples.count
            samples.append(contentsOf: repeatElement(0, count: count))
            let status = samples.withUnsafeMutableBufferPointer { pointer in
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: count * MemoryLayout<Float>.size,
                                           destination: pointer.baseAddress!.advanced(by: previous))
            }
            guard status == kCMBlockBufferNoErr else {
                throw AudioDecodingError.readerFailed("block copy failed (\(status))")
            }
        }
        if reader.status == .failed {
            throw AudioDecodingError.readerFailed(reader.error?.localizedDescription ?? "unknown")
        }
        guard !samples.isEmpty, let firstTimestamp else { throw AudioDecodingError.emptyOutput }
        return DecodedAudio(samples: samples, startTime: max(0, firstTimestamp))
    }
}
