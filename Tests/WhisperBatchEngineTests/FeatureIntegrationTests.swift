import Foundation
import Testing
import WhisperBatchCore
@testable import WhisperBatchEngine

// 追加機能の結合テスト。次の環境変数を設定したときだけ実行する。
//   WHISPER_BATCH_TEST_AUDIO_DIR       : テスト音声のフォルダ（scripts/make-test-audio.sh で作成。ja1.wav を使う）
//   WHISPER_BATCH_TEST_MODEL           : ggml モデルファイルのパス
//   WHISPER_BATCH_TEST_REAZON_DIR      : ReazonSpeech k2 v2（int8 でない方）のファイルがあるフォルダ
//   （話者識別・AI の結合テストは Tests/SonaVantageAITests にある）

private let env = ProcessInfo.processInfo.environment
private let audioDir = env["WHISPER_BATCH_TEST_AUDIO_DIR"].map { URL(fileURLWithPath: $0) }
private let modelPath = env["WHISPER_BATCH_TEST_MODEL"].map { URL(fileURLWithPath: $0) }
private let reazonDir = env["WHISPER_BATCH_TEST_REAZON_DIR"].map { URL(fileURLWithPath: $0) }
//   WHISPER_BATCH_TEST_APPLE_CONFIDENCE : Apple の音声認識で試す英語の音声（言語データが入っていること）
private let appleAudio = env["WHISPER_BATCH_TEST_APPLE_CONFIDENCE"].map { URL(fileURLWithPath: $0) }

/// 語句の確からしさが区間の文字と対応していることを確かめる
private func checkWords(_ transcript: Transcript) {
    for segment in transcript.segments where !segment.text.isEmpty {
        guard let words = segment.words else { continue }
        #expect(words.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines) == segment.text)
        #expect(words.allSatisfy { $0.probability.map { (0 ... 1).contains($0) } ?? true })
        #expect(ReviewCandidateFinder.spans(in: segment).count == words.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }.count)
    }
}

@Suite("認識結果の確からしさ（実モデル）", .serialized)
struct ConfidenceIntegrationTests {
    init() { TestLocalization.setUp() }

    @Test(.enabled(if: audioDir != nil && modelPath != nil))
    func whisperReturnsTokenProbabilities() async throws {
        let url = try #require(modelPath)
        let model = ModelCatalog.all.first { $0.files.first?.name == url.lastPathComponent } ?? ModelCatalog.all[0]
        let ctx = try await WhisperContext.load(model: model, fileURL: url)
        let transcript = try await ctx.transcribe(fileURL: audioDir!.appendingPathComponent("ja1.wav"),
                                                  options: .init(language: .japanese)) { _ in }
        #expect(!transcript.segments.isEmpty)
        for segment in transcript.segments {
            print("whisper:", segment.text, segment.confidence.map { String(format: "%.2f", $0) } ?? "nil",
                  segment.words?.map { "\($0.text)=\(String(format: "%.2f", $0.probability ?? -1))" }.joined(separator: " ") ?? "")
            let confidence = try #require(segment.confidence)
            #expect(confidence > 0 && confidence <= 1)
            #expect(segment.words?.isEmpty == false)
        }
        checkWords(transcript)
        // 日本語の文字が壊れていない（複数のトークンに分かれた文字をつなげている）
        #expect(!transcript.segments.contains { $0.text.contains("\u{FFFD}") })
    }

    @Test(.enabled(if: audioDir != nil && reazonDir != nil))
    func reazonSpeechConfidenceWhenProvided() async throws {
        let model = try #require(ModelCatalog.model(id: "reazonspeech-k2-v2"))
        let ctx = try await ReazonSpeechContext.load(model: model, directory: reazonDir!)
        let transcript = try await ctx.transcribe(fileURL: audioDir!.appendingPathComponent("ja1.wav"),
                                                  options: .init(language: .japanese)) { _ in }
        #expect(!transcript.segments.isEmpty)
        for segment in transcript.segments {
            print("reazon:", segment.text, segment.confidence.map { String(format: "%.2f", $0) } ?? "nil")
            if let c = segment.confidence { #expect(c >= 0 && c <= 1) }
        }
        checkWords(transcript)
    }

    @Test(.enabled(if: appleAudio != nil))
    func appleSpeechConfidenceWhenProvided() async throws {
        let model = try #require(ModelCatalog.model(id: "apple-speech"))
        let transcriber = try await AppleSpeechTranscriber.make(model: model, language: .english)
        let transcript = try await transcriber.transcribe(fileURL: appleAudio!, options: .init(language: .english)) { _ in }
        #expect(!transcript.segments.isEmpty)
        for segment in transcript.segments {
            print("apple:", segment.text, segment.confidence.map { String(format: "%.2f", $0) } ?? "nil",
                  segment.words?.map { "\($0.text)=\($0.probability.map { String(format: "%.2f", $0) } ?? "-")" } ?? [])
            if let c = segment.confidence { #expect(c >= 0 && c <= 1) }
        }
        checkWords(transcript)
    }
}
