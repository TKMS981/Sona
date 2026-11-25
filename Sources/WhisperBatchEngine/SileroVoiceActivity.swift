import Foundation
import WhisperBatchCore
import whisper

/// 音声の中の発話区間を見つける（バッチ文字起こしで長い無音を飛ばすのに使う）
public protocol SpeechRegionDetecting: Sendable {
    /// - Parameter samples: 16kHz モノラル PCM
    /// - Returns: 発話区間（サンプル番号、昇順）
    func speechRanges(in samples: [Float]) async throws -> [Range<Int>]
}

/// Silero VAD（whisper.framework に含まれる whisper.cpp の VAD を単体で使う）。
///
/// whisper.cpp の `whisper_full_params.vad`（内蔵の VAD）は使わない。内蔵の VAD は発話だけを約 0.1 秒の間で
/// つなぐため、間で分かれていた複数の発話が 1 つの区間にまとまり、字幕や話者識別の区間が変わる。
/// ここでは発話区間を見つけるだけで、無音の短くし方は `SpeechGapPlan` が決める。
/// VAD は CPU で動く（whisper.cpp の既定。Metal を使わない）。
public final class SileroVoiceActivityDetector: SpeechRegionDetecting, @unchecked Sendable {
    /// whisper_vad_context は 1 度に 1 つの処理だけで使う。すべてこのキューの上で扱う。
    private let queue = DispatchQueue(label: "WhisperBatch.vad", qos: .userInitiated)
    private let ctx: OpaquePointer
    let params: whisper_vad_params

    private init(ctx: OpaquePointer, params: whisper_vad_params) {
        self.ctx = ctx
        self.params = params
    }

    deinit {
        whisper_vad_free(ctx)
    }

    /// 区間の判定に使う値。指定しないものは whisper.cpp の既定値（しきい値 0.5、最短の発話 250ms、
    /// 発話の終わりとみなす無音 100ms、前後の余白 30ms）。アプリはしきい値と最短の発話を
    /// `VoiceActivitySettings.standard`（しきい値 0.1、最短の発話 100ms）にする。
    /// 語頭・語尾は `SpeechGapPlan` が前後 0.5 秒ずつ元の音声を残すので、余白は広げなくてよい。
    package struct Tuning: Sendable, Equatable {
        package var threshold: Float?
        package var minSpeechMilliseconds: Int?
        package var minSilenceMilliseconds: Int?
        package init(threshold: Float? = nil, minSpeechMilliseconds: Int? = nil, minSilenceMilliseconds: Int? = nil) {
            self.threshold = threshold
            self.minSpeechMilliseconds = minSpeechMilliseconds
            self.minSilenceMilliseconds = minSilenceMilliseconds
        }
    }

    /// モデルファイルを読み込む。読み込めないときは `modelLoadFailed` を投げる。
    public static func load(fileURL: URL, modelName: String) async throws -> SileroVoiceActivityDetector {
        let standard = VoiceActivitySettings.standard
        return try await load(fileURL: fileURL, modelName: modelName,
                              tuning: Tuning(threshold: standard.threshold, minSpeechMilliseconds: standard.minSpeechMilliseconds))
    }

    package static func load(fileURL: URL, modelName: String, tuning: Tuning) async throws -> SileroVoiceActivityDetector {
        WhisperLogging.configure()
        let path = fileURL.path
        let ctx: OpaquePointer? = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var contextParams = whisper_vad_default_context_params()
                contextParams.use_gpu = false
                continuation.resume(returning: whisper_vad_init_from_file_with_params(path, contextParams))
            }
        }
        guard let ctx else { throw WhisperBatchError.modelLoadFailed(modelName: modelName) }
        var params = whisper_vad_default_params()
        if let t = tuning.threshold { params.threshold = t }
        if let ms = tuning.minSpeechMilliseconds { params.min_speech_duration_ms = Int32(ms) }
        if let ms = tuning.minSilenceMilliseconds { params.min_silence_duration_ms = Int32(ms) }
        return SileroVoiceActivityDetector(ctx: ctx, params: params)
    }

    public func speechRanges(in samples: [Float]) async throws -> [Range<Int>] {
        guard !samples.isEmpty else { return [] }
        let flag = CancellationFlag()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[Range<Int>], any Error>) in
                queue.async { [self] in
                    if flag.isCancelled {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    continuation.resume(with: Self.detect(ctx: ctx, params: params, samples: samples))
                }
            }
        } onCancel: {
            flag.cancel()
        }
    }

    private static func detect(ctx: OpaquePointer, params: whisper_vad_params, samples: [Float]) -> Result<[Range<Int>], any Error> {
        let segments = samples.withUnsafeBufferPointer { buf in
            whisper_vad_segments_from_samples(ctx, params, buf.baseAddress, Int32(buf.count))
        }
        guard let segments else { return .failure(WhisperBatchError.transcriptionFailed(code: -1)) }
        defer { whisper_vad_free_segments(segments) }
        let rate = Double(WHISPER_SAMPLE_RATE)
        var ranges: [Range<Int>] = []
        for i in 0 ..< whisper_vad_segments_n_segments(segments) {
            // 時刻は 10ms 単位
            let t0 = Double(whisper_vad_segments_get_segment_t0(segments, i)) / 100
            let t1 = Double(whisper_vad_segments_get_segment_t1(segments, i)) / 100
            let lower = min(max(Int((t0 * rate).rounded(.down)), 0), samples.count)
            let upper = min(max(Int((t1 * rate).rounded(.up)), lower), samples.count)
            if upper > lower { ranges.append(lower ..< upper) }
        }
        return .success(ranges)
    }
}

public enum VoiceActivityLoader {
    /// 保存先の Silero VAD のモデルを確かめて（取得済み・SHA-256 が一致）読み込む
    public static func load(storage: ModelStorage) async throws -> SileroVoiceActivityDetector {
        let model = ModelCatalog.voiceActivity
        guard let file = model.files.first, storage.isInstalled(model) else {
            throw WhisperBatchError.modelNotInstalled(modelName: model.displayName)
        }
        try await storage.verifyContents(of: model)
        return try await SileroVoiceActivityDetector.load(fileURL: storage.fileURL(for: file, of: model), modelName: model.displayName)
    }
}
