import Foundation
import WhisperBatchCore

public struct TranscriptionOptions: Sendable {
    public var language: LanguageOption
    /// Whisper の探索方式（ほかの方式では使わない）
    public var decoding: WhisperDecoding
    public var planner: ChunkPlanner
    /// 長い無音を飛ばすときの発話区間の検出（Whisper だけ。nil なら飛ばさない＝従来どおり）
    public var voiceActivity: (any SpeechRegionDetecting)?
    /// 残す間の長さ（計測で値を比べるときだけ変える。発話とみなす最短の長さは検出器を読み込むときに決める）
    package var voiceActivitySettings: VoiceActivitySettings = .standard

    public init(language: LanguageOption, decoding: WhisperDecoding = .default, planner: ChunkPlanner = ChunkPlanner(),
                voiceActivity: (any SpeechRegionDetecting)? = nil) {
        self.language = language
        self.decoding = decoding
        self.planner = planner
        self.voiceActivity = voiceActivity
    }
}

/// 1 ファイル分の文字起こし。音声をチャンクに分けて順に認識し、境界をつなぎ合わせる。
///
/// 前のチャンクの文章を次のチャンクの文脈（initial prompt）として渡すことはしない。
/// 試験では、渡すと境界付近で文の重複や読み飛ばしが増えたため。
public enum TranscriptionEngine {
    /// - Parameter progress: 0...1。任意のスレッドから呼ばれる。
    @concurrent
    public static func transcribe(
        fileURL: URL,
        context: WhisperContext,
        options: TranscriptionOptions,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> Transcript {
        let reader = try await AudioSampleReader(url: fileURL)
        let rate = AudioSampleReader.sampleRate
        let planner = options.planner
        let total = reader.duration
        var window = AudioStreamBuffer(source: reader, sampleRate: rate, capacity: Int(planner.chunkDuration * rate))

        var language = options.language.code
        var segments: [TranscriptSegment] = []

        progress(0)
        while true {
            try Task.checkCancellation()
            try await window.fill()
            // 末尾に残ったごく短い断片は認識しない（無音から文章を作ってしまう誤認識を避ける）
            if window.isEmpty || (window.isExhausted && window.duration < 0.3 && !segments.isEmpty) { break }

            // 最後以外のチャンクは、発話の切れ目（末尾付近の最も静かな位置）までを認識する
            let length = planner.cutLength(samples: window.samples, sampleRate: rate, isFinal: window.isExhausted)
            let samples = length == window.count ? window.samples : Array(window.samples[..<length])
            let chunkDuration = Double(length) / rate
            let chunkStart = window.startTime
            let report: @Sendable (Double) -> Void = { p in
                guard total > 0 else { return }
                progress(min((chunkStart + p * chunkDuration) / total, 0.999))
            }
            let result = try await recognize(samples, context: context, language: language, options: options,
                                             sampleRate: rate, progress: report)
            // 自動判定は最初に発話があったチャンクで確定し、以降のチャンクも同じ言語で認識する
            if language == nil, !result.segments.isEmpty, let detected = result.language {
                language = detected
            }

            let decision = planner.decide(segments: result.segments, bufferDuration: chunkDuration, isFinal: window.isExhausted)
            segments += decision.accepted
                .filter { !$0.text.isEmpty }
                .map { $0.shifted(by: chunkStart) }

            if window.isExhausted { break }
            window.consume(min(max(Int(decision.resumeAt * rate), 1), length))
        }
        progress(1)
        return Transcript(segments: segments, language: language ?? options.language.code)
    }

    /// 1 チャンクを認識する。発話区間の検出を使うときは、長い無音だけを短くした音声を認識し、
    /// 区間の時刻を元の音声の時刻に戻す（時刻はどちらの場合もチャンク先頭からの相対秒）。
    /// 発話区間の検出に失敗したチャンクは、従来どおり音声をそのまま認識する。
    static func recognize(
        _ samples: [Float],
        context: WhisperContext,
        language: String?,
        options: TranscriptionOptions,
        sampleRate: Double,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> ChunkResult {
        var plan: SpeechGapPlan?
        if let detector = options.voiceActivity {
            do {
                let speech = try await detector.speechRanges(in: samples)
                let settings = options.voiceActivitySettings
                plan = SpeechGapPlan(speech: speech, originalCount: samples.count,
                                     keptGap: Int(settings.keptGap * sampleRate),
                                     minSkippedGap: Int(settings.minSkippedSilence * sampleRate))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                plan = nil
            }
        }
        guard let plan else {
            return try await context.transcribe(samples: samples, language: language, decoding: options.decoding, progress: progress)
        }
        // 発話がない（無音・雑音だけ）チャンクは認識しない
        guard !plan.isEmpty else {
            progress(1)
            return ChunkResult(segments: [], language: nil)
        }
        let compressed = plan.extract(from: samples)
        let compressedDuration = Double(compressed.count) / sampleRate
        let originalDuration = Double(samples.count) / sampleRate
        let result = try await context.transcribe(
            samples: compressed, language: language, decoding: options.decoding,
            progress: { p in
                guard originalDuration > 0 else { return }
                let t = plan.originalTime(ofCompressed: p * compressedDuration, sampleRate: sampleRate, isEnd: true)
                progress(min(max(t / originalDuration, 0), 1))
            }
        )
        return ChunkResult(segments: plan.mapToOriginal(result.segments, sampleRate: sampleRate), language: result.language)
    }
}
