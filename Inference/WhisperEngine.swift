import Foundation
import os

/// Shared cancellation flag readable from the ggml abort callback.
final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}

enum WhisperEngineError: LocalizedError {
    case modelLoadFailed
    case inferenceFailed(Int32)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .modelLoadFailed: "The speech model could not be loaded. Reinstall the model and try again."
        case let .inferenceFailed(code): "Speech recognition failed (engine code \(code))."
        case .cancelled: TranscriptionProtocol.cancelledMessage
        }
    }
}

struct EngineSegment {
    let start: TimeInterval
    let end: TimeInterval
    let text: String
    let noSpeechProbability: Float
}

/// Thin wrapper around one loaded `whisper_context`. Not thread-safe: every
/// call must come from the owner's dedicated inference queue.
final class WhisperEngine {
    static let engineName = "whisper.cpp"
    static var engineVersion: String {
        String(cString: whisper_version())
    }

    static var systemInfo: String {
        String(cString: whisper_print_system_info())
    }

    static var gpuCompiledIn: Bool {
        #if arch(arm64)
            true
        #else
            false
        #endif
    }

    static let quietLogging: Void = {
        whisper_log_set({ level, text, _ in
            guard level == GGML_LOG_LEVEL_ERROR, let text else { return }
            Logger(subsystem: "com.wordy.app", category: "whisper").error("\(String(cString: text), privacy: .public)")
        }, nil)
    }()

    let modelPath: String
    let useGPU: Bool
    let loadMilliseconds: Double
    private let context: OpaquePointer

    init(modelPath: String, useGPU: Bool) throws {
        _ = Self.quietLogging
        var params = whisper_context_default_params()
        params.use_gpu = useGPU && Self.gpuCompiledIn
        params.flash_attn = params.use_gpu
        let started = ContinuousClock.now
        guard let context = whisper_init_from_file_with_params(modelPath, params) else {
            throw WhisperEngineError.modelLoadFailed
        }
        self.context = context
        self.modelPath = modelPath
        self.useGPU = params.use_gpu
        loadMilliseconds = (ContinuousClock.now - started).milliseconds
    }

    deinit {
        whisper_free(context)
    }

    var isMultilingual: Bool {
        whisper_is_multilingual(context) != 0
    }

    /// Runs the full pipeline on `samples` (16 kHz mono). Times are relative to
    /// the first sample; callers add the chunk's absolute start.
    func transcribe(samples: [Float], language: String, threads: Int,
                    cancellation: CancellationFlag) throws -> (segments: [EngineSegment], language: String?)
    {
        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.n_threads = Int32(threads)
        params.no_context = true
        params.single_segment = false
        params.print_special = false
        params.print_progress = false
        params.print_realtime = false
        params.print_timestamps = false
        params.token_timestamps = false
        params.suppress_blank = true
        params.suppress_nst = true
        params.translate = false
        params.abort_callback = { userData in
            guard let userData else { return false }
            return Unmanaged<CancellationFlag>.fromOpaque(userData).takeUnretainedValue().isCancelled
        }
        params.abort_callback_user_data = Unmanaged.passUnretained(cancellation).toOpaque()

        let requestedLanguage = isMultilingual ? language : "en"
        let status: Int32 = requestedLanguage.withCString { languagePointer in
            params.language = languagePointer
            params.detect_language = false
            return samples.withUnsafeBufferPointer { buffer in
                whisper_full(context, params, buffer.baseAddress, Int32(buffer.count))
            }
        }
        if cancellation.isCancelled {
            throw WhisperEngineError.cancelled
        }
        guard status == 0 else { throw WhisperEngineError.inferenceFailed(status) }

        let count = whisper_full_n_segments(context)
        var segments: [EngineSegment] = []
        segments.reserveCapacity(Int(count))
        for index in 0 ..< count {
            let t0 = whisper_full_get_segment_t0(context, index)
            let t1 = whisper_full_get_segment_t1(context, index)
            let text = whisper_full_get_segment_text(context, index).map { String(cString: $0) } ?? ""
            segments.append(EngineSegment(
                start: Double(t0) / 100,
                end: Double(t1) / 100,
                text: text,
                noSpeechProbability: whisper_full_get_segment_no_speech_prob(context, index),
            ))
        }
        let detected: String? = if requestedLanguage == "auto" {
            whisper_lang_str(whisper_full_lang_id(context)).map { String(cString: $0) }
        } else {
            requestedLanguage
        }
        return (segments, detected)
    }
}

enum ProcessFootprint {
    /// Physical memory footprint of the current process in bytes (same basis as Activity Monitor).
    static func current() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), rebound, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }
}
