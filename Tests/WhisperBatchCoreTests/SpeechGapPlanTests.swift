import Foundation
import Testing
@testable import WhisperBatchCore

@Suite("長い無音を短くする計画（SpeechGapPlan）")
struct SpeechGapPlanTests {
    private let rate = 16_000.0
    private func s(_ seconds: Double) -> Int { Int(seconds * rate) }

    @Test func keepsShortGapsAndShortensLongOnes() {
        // 発話 3–4 秒、4.8–5 秒（間 0.8 秒はそのまま）、12–13 秒（間 7 秒は 1 秒に）。全体 16 秒（先頭 3 秒・末尾 3 秒は 0.5 秒に）
        let plan = SpeechGapPlan(speech: [s(3) ..< s(4), s(4.8) ..< s(5), s(12) ..< s(13)],
                                 originalCount: s(16), keptGap: s(1))
        #expect(plan.pieces.map(\.originalStart) == [s(2.5), s(11.5)])
        #expect(plan.pieces.map(\.length) == [s(3.0), s(2.0)])
        #expect(plan.compressedCount == s(5.0))
        #expect(!plan.isEmpty)
    }

    @Test func keepsSilencesShorterThanTheMinimumUntouched() {
        // 間 3 秒は最短 5 秒より短いのでそのまま、間 8 秒は 1 秒に。先頭 1 秒・末尾 1 秒も短いのでそのまま
        let plan = SpeechGapPlan(speech: [s(1) ..< s(2), s(5) ..< s(6), s(14) ..< s(15)],
                                 originalCount: s(16), keptGap: s(1), minSkippedGap: s(5))
        #expect(plan.pieces.map(\.originalStart) == [0, s(13.5)])
        #expect(plan.pieces.map(\.length) == [s(6.5), s(2.5)])
        #expect(plan.compressedCount == s(9))
    }

    @Test func noSpeechMeansNothingToRecognize() {
        let plan = SpeechGapPlan(speech: [], originalCount: s(30), keptGap: s(1))
        #expect(plan.isEmpty)
        #expect(plan.compressedCount == 0)
        #expect(plan.extract(from: [Float](repeating: 0, count: s(30))).isEmpty)
    }

    @Test func clampsAtTheEdgesAndMergesOverlaps() {
        let plan = SpeechGapPlan(speech: [s(5.8) ..< s(6.5), s(0.1) ..< s(0.3), s(6) ..< s(7)],
                                 originalCount: s(7), keptGap: s(1))
        #expect(plan.pieces.count == 2)
        #expect(plan.pieces[0].originalStart == 0)
        #expect(plan.pieces[0].length == s(0.8))
        #expect(plan.pieces[1].originalStart == s(5.3))
        #expect(plan.pieces[1].originalStart + plan.pieces[1].length == s(7))
    }

    @Test func extractCopiesOriginalSamplesOnly() {
        let samples = (0 ..< s(16)).map { Float($0) }
        let plan = SpeechGapPlan(speech: [s(3) ..< s(4), s(12) ..< s(13)], originalCount: samples.count, keptGap: s(1))
        let out = plan.extract(from: samples)
        #expect(out.count == plan.compressedCount)
        #expect(out.first == Float(s(2.5)))
        #expect(out[s(2) - 1] == Float(s(4.5) - 1))
        #expect(out[s(2)] == Float(s(11.5)))
        #expect(out.last == Float(s(13.5) - 1))
    }

    @Test func mapsTimesBackExactlyInsideEachPiece() {
        // 残す範囲: 2.5–4.5 秒 → 0–2 秒、11.5–13.5 秒 → 2–4 秒
        let plan = SpeechGapPlan(speech: [s(3) ..< s(4), s(12) ..< s(13)], originalCount: s(16), keptGap: s(1))
        #expect(abs(plan.originalTime(ofCompressed: 0.5, sampleRate: rate, isEnd: false) - 3.0) < 1e-9)
        #expect(abs(plan.originalTime(ofCompressed: 3.0, sampleRate: rate, isEnd: false) - 12.5) < 1e-9)
        // つなぎ目ちょうど: 始まりは次の範囲の先頭、終わりは前の範囲の末尾
        #expect(abs(plan.originalTime(ofCompressed: 2.0, sampleRate: rate, isEnd: false) - 11.5) < 1e-9)
        #expect(abs(plan.originalTime(ofCompressed: 2.0, sampleRate: rate, isEnd: true) - 4.5) < 1e-9)
        // 範囲の外
        #expect(abs(plan.originalTime(ofCompressed: 0, sampleRate: rate, isEnd: false) - 2.5) < 1e-9)
        #expect(abs(plan.originalTime(ofCompressed: 9, sampleRate: rate, isEnd: true) - 13.5) < 1e-9)
    }

    @Test func mapsSegmentsAndKeepsTheirContents() {
        let plan = SpeechGapPlan(speech: [s(3) ..< s(4), s(12) ..< s(13)], originalCount: s(16), keptGap: s(1))
        let segments = [TranscriptSegment(start: 0.4, end: 1.6, text: "a", confidence: 0.9),
                        TranscriptSegment(start: 2.0, end: 3.6, text: "b")]
        let mapped = plan.mapToOriginal(segments, sampleRate: rate)
        #expect(mapped.map(\.text) == ["a", "b"])
        #expect(mapped[0].confidence == 0.9)
        #expect(abs(mapped[0].start - 2.9) < 1e-9 && abs(mapped[0].end - 4.1) < 1e-9)
        #expect(abs(mapped[1].start - 11.5) < 1e-9 && abs(mapped[1].end - 13.1) < 1e-9)
    }
}

@Suite("長い無音を飛ばす設定とモデル")
@MainActor
struct SkipSilenceSettingTests {
    @Test func defaultsToOffAndPersists() {
        let suite = "WhisperBatchTests.skipSilence.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SettingsStore(defaults: defaults)
        #expect(!store.skipsLongSilence)
        #expect(store.makeSnapshot(appearance: nil).general?.skipsLongSilence == false)
        store.skipsLongSilence = true
        #expect(SettingsStore(defaults: defaults).skipsLongSilence)
    }

    @Test func modelIsPinnedAndNotATranscriptionModel() {
        let vad = ModelCatalog.voiceActivity
        #expect(vad.purpose == .voiceActivity)
        #expect(vad.engine == .whisper)
        #expect(ModelCatalog.auxiliary.contains(vad))
        #expect(!ModelCatalog.all.contains(vad))
        #expect(!ModelCatalog.models(for: .whisper).contains(vad))
        let file = try! #require(vad.files.first)
        #expect(vad.files.count == 1)
        #expect(file.url.absoluteString == "https://huggingface.co/ggml-org/whisper-vad/resolve/9ffd54a1e1ee413ddf265af9913beaf518d1639b/ggml-silero-v6.2.0.bin")
        #expect(file.sha256 == "2aa269b785eeb53a82983a20501ddf7c1d9c48e33ab63a41391ac6c9f7fb6987")
        #expect(file.sizeBytes == 885_098)
    }
}

