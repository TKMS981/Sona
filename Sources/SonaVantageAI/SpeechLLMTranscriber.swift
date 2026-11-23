import Foundation
import NaturalLanguage
import SonaLLM
import WhisperBatchCore
import WhisperBatchEngine

/// 音声を直接読む言語モデル（Qwen3-ASR・Granite Speech。llama.cpp で動かす）で、ファイルを文字起こしする。
///
/// これらのモデルは 1 回に短い音声（数十秒まで）を受け取り、時刻のない文章を返す。そのため、
/// 音声を少しずつ読みながら、文の間の無音で発話ごとに区切り（`UtteranceSplitter`）、
/// 発話ごとに認識して、その発話の範囲を区間の時刻にする。
public final class SpeechLLMTranscriber: Transcriber {
    public let model: SpeechModel
    let recognizer: LlamaSpeechRecognizer
    let splitter: UtteranceSplitter

    /// 一度に読み込む音声の長さ（秒）。発話の区切りはこの中で探す。
    static let blockDuration: TimeInterval = 120

    init(model: SpeechModel, recognizer: LlamaSpeechRecognizer, splitter: UtteranceSplitter = SpeechLLMTranscriber.defaultSplitter) {
        self.model = model
        self.recognizer = recognizer
        self.splitter = splitter
    }

    /// 発話の区切り方。字幕の 1 区間として読みやすく、モデルが前後の文脈を使える長さにする。
    /// - 0.5 秒以上の無音で区切る（文の途中の短い間では区切らない）
    /// - 1 区間は最大 25 秒（超える場合は最も静かな位置で区切る）
    static let defaultSplitter = UtteranceSplitter(minPause: 0.5, maxUtterance: 25)

    // 手放すと認識器も解放される（認識器は実行中の認識が終わるまで自分を保持し、終わってから同期的に解放する）

    /// モデルを読み込む（ファイルは呼び出し側が照合済み）
    static func load(model: SpeechModel, storage: ModelStorage) async throws -> SpeechLLMTranscriber {
        guard model.files.count == 2 else { throw WhisperBatchError.modelLoadFailed(modelName: model.displayName) }
        let family: LlamaSpeechRecognizer.Family = switch model.engine {
        case .qwen3ASR: .qwen3ASR
        case .graniteSpeech: .graniteSpeech
        default: throw WhisperBatchError.modelLoadFailed(modelName: model.displayName)
        }
        let recognizer = try await LlamaSpeechRecognizer.load(
            family: family,
            modelURL: storage.fileURL(for: model.files[0], of: model),
            projectorURL: storage.fileURL(for: model.files[1], of: model),
            displayName: model.displayName)
        return SpeechLLMTranscriber(model: model, recognizer: recognizer)
    }

    @concurrent
    public func transcribe(fileURL: URL, options: TranscriptionOptions,
                           progress: @escaping @Sendable (Double) -> Void) async throws -> Transcript {
        let reader = try await AudioSampleReader(url: fileURL)
        return try await transcribe(source: reader, duration: reader.duration, options: options, progress: progress)
    }

    /// 音声（16 kHz モノラル）を順に読み出して文字起こしする（テストでは配列で代用する）
    func transcribe<Source: AudioSampleSource>(source: Source, duration total: TimeInterval, options: TranscriptionOptions,
                                               progress: @escaping @Sendable (Double) -> Void) async throws -> Transcript {
        let rate = AudioSampleReader.sampleRate
        var window = AudioStreamBuffer(source: source, sampleRate: rate, capacity: Int(Self.blockDuration * rate))
        // 言語を指定しなければモデルが判定する。最初に判定できた言語を、以降の発話にも使う（途中で言語が揺れないように）
        var language = options.language.code
        var segments: [TranscriptSegment] = []

        progress(0)
        while true {
            try Task.checkCancellation()
            try await window.fill()
            let result = splitter.split(window.samples, sampleRate: rate, isFinal: window.isExhausted)
            for range in result.utterances {
                try Task.checkCancellation()
                // ごく短い音（0.3 秒未満）は認識しない（無音から文章を作ってしまう誤認識を避ける）
                guard range.count >= Int(0.3 * rate) else { continue }
                let output = try await recognizer.transcribe(samples: Array(window.samples[range]), languageCode: language)
                if language == nil, let detected = output.languageCode, !output.text.isEmpty { language = detected }
                let start = window.time(atFrame: range.lowerBound)
                let end = window.time(atFrame: range.upperBound)
                if !output.text.isEmpty {
                    segments.append(TranscriptSegment(start: start, end: end, text: output.text))
                }
                if total > 0 { progress(min(end / total, 0.999)) }
            }
            window.consume(result.consumed)
            if window.isExhausted && (window.isEmpty || result.consumed == 0) { break }
        }
        progress(1)
        // Granite は言語を返さないので、自動判定のときは書き起こした文から言語を推定する（要約・修正などで使う）
        let resolved = language ?? Self.dominantLanguage(of: segments, among: model.engine.languageOptions.compactMap(\.code))
        return Transcript(segments: segments, language: resolved ?? options.language.code)
    }

    /// 書き起こした文の言語（この方式が扱う言語の中で、最も確からしいもの）
    static func dominantLanguage(of segments: [TranscriptSegment], among codes: [String]) -> String? {
        let text = segments.prefix(40).map(\.text).joined(separator: " ")
        guard !text.isEmpty else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.languageConstraints = codes.map { NLLanguage(rawValue: $0) }
        recognizer.processString(text)
        return recognizer.dominantLanguage?.rawValue
    }
}
