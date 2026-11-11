import Foundation
import Testing
import WhisperBatchCore
import WhisperBatchEngine
@testable import SonaVantageAI

// Vantage の AI 機能の結合テスト（話者識別・Apple Intelligence）。次の環境変数を設定したときだけ実行する。
//   WHISPER_BATCH_TEST_DIARIZATION_DIR : 話者識別のモデル（ModelCatalog.speakerDiarization のファイル名）があるフォルダ
//   WHISPER_BATCH_TEST_DIALOGUE        : 2 人が交互に話す音声（6 発話、各発話の後に 0.8 秒の無音）
//   WHISPER_BATCH_TEST_ONDEVICE_AI=1   : Apple Intelligence の端末内のモデルで要約などを試す

private let env = ProcessInfo.processInfo.environment
private let diarizationDir = env["WHISPER_BATCH_TEST_DIARIZATION_DIR"].map { URL(fileURLWithPath: $0) }
private let dialogue = env["WHISPER_BATCH_TEST_DIALOGUE"].map { URL(fileURLWithPath: $0) }
private let onDeviceAI = env["WHISPER_BATCH_TEST_ONDEVICE_AI"] == "1"

@Suite("話者識別（実モデル）", .enabled(if: diarizationDir != nil && dialogue != nil), .serialized)
struct DiarizationIntegrationTests {
    init() { TestLocalization.setUp() }

    /// 各発話の中央の時刻（秒）。dialogue.wav の作り方に合わせる
    static let utteranceMidpoints: [TimeInterval] = [2.9, 9.9, 17.2, 23.7, 29.8, 35.7]

    private func turns(speakerCount: Int?) async throws -> [SpeakerTurn] {
        let diarizer = try await SpeakerDiarizer.load(model: ModelCatalog.speakerDiarization, directory: diarizationDir!,
                                                      speakerCount: speakerCount)
        let samples = try await SpeakerDiarizer.readSamples(from: dialogue!)
        let clock = ContinuousClock()
        let start = clock.now
        let result = try await diarizer.diarize(samples) { _ in }
        print("diarization:", clock.now - start, result.map { "\(String(format: "%.1f-%.1f", $0.start, $0.end)):\($0.speaker)" })
        return result
    }

    private func speakers(at times: [TimeInterval], in turns: [SpeakerTurn]) -> [Int?] {
        let points = times.map { TranscriptSegment(start: $0 - 0.5, end: $0 + 0.5, text: "x") }
        return SpeakerAssigner.assign(points, turns: turns)
    }

    @Test func separatesTwoAlternatingVoices() async throws {
        let result = try await turns(speakerCount: nil)
        #expect(Set(result.map(\.speaker)).count == 2)
        #expect(speakers(at: Self.utteranceMidpoints, in: result) == [0, 1, 0, 1, 0, 1])
    }

    @Test func knownSpeakerCount() async throws {
        let result = try await turns(speakerCount: 2)
        #expect(speakers(at: Self.utteranceMidpoints, in: result) == [0, 1, 0, 1, 0, 1])
    }
}

@Suite("オンデバイスの AI（Apple Intelligence）", .enabled(if: onDeviceAI), .serialized)
struct OnDeviceAIIntegrationTests {
    init() { TestLocalization.setUp() }

    let transcript = Transcript(segments: [
        .init(start: 0, end: 4, text: "えー、本日は新製品の発売日について話し合います。", speaker: 0),
        .init(start: 4, end: 9, text: "発売日は来月の十五日に決定しました。", speaker: 0),
        .init(start: 9, end: 13, text: "資料は田中さんが金曜日までに用意してください。", speaker: 1),
        .init(start: 13, end: 17, text: "広告の予算は三百万円を予定しています。", speaker: 0),
        .init(start: 17, end: 21, text: "在庫の不足が課題として残っています", speaker: 1),
        .init(start: 21, end: 23, text: "ありがとうございました。", speaker: 0),
    ], language: "ja")

    private var lines: [LocalAIText.Line] {
        LocalAIText.lines(original: transcript, edits: TranscriptEdits(), speakerNames: [:])
    }

    private let generator = AppleIntelligenceGenerator()

    @Test func availability() {
        #expect(AppleIntelligenceGenerator.availability(languageCode: "ja") == .available)
    }

    @Test func summarizes() async throws {
        let summary = try await AITaskRunner.summarize(lines, generator: generator, languageCode: "ja")
        print("summary:", summary)
        #expect(!summary.isEmpty)
        #expect(summary.contains { $0.contains("十五日") || $0.contains("15日") || $0.contains("発売") })
    }

    @Test func picksKeyPointsFromTheTranscriptOnly() async throws {
        let points = try await AITaskRunner.keyPoints(lines, segments: transcript.segments, generator: generator, languageCode: "ja")
        print("keyPoints:", points.map { "\($0.text) \($0.reasons)" })
        #expect(!points.isEmpty)
        // 文は文字起こしのものだけ
        #expect(points.allSatisfy { p in transcript.segments.contains { $0.text == p.text } })
    }

    @Test func polishKeepsMeaning() async throws {
        let result = try await AITaskRunner.rewrite(.polish, lines: lines, generator: generator, languageCode: "ja")
        print("polish:", result.candidates.map { "\($0.index): \($0.rewritten)" }, "rejected:", result.rejected.count)
        for c in result.candidates {
            #expect(transcript.segments.indices.contains(c.index))
            #expect(RewriteGuard.check(original: c.original, rewritten: c.rewritten, task: .polish).isEmpty)
        }
    }

    @Test func suggestsCorrection() async throws {
        let suggestion = try await AITaskRunner.suggestCorrection(
            target: "発売日は来月の十五日に決定しま下。", before: ["本日は新製品の発売日について話し合います。"],
            after: ["資料は金曜日までに用意してください。"], suspicious: ["下"], generator: generator, languageCode: "ja")
        print("correction:", suggestion ?? "nil")
        if let suggestion { #expect(suggestion.contains("十五日")) }
    }
}
