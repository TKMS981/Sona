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

    @Test func clampsAtTheEdgesAndMergesOverlaps() throws {
        let plan = SpeechGapPlan(speech: [s(5.8) ..< s(6.5), s(0.1) ..< s(0.3), s(6) ..< s(7)],
                                 originalCount: s(7), keptGap: s(1))
        try #require(plan.pieces.count == 2)
        #expect(plan.pieces[0].originalStart == 0)
        #expect(plan.pieces[0].length == s(0.8))
        #expect(plan.pieces[1].originalStart == s(5.3))
        #expect(plan.pieces[1].originalStart + plan.pieces[1].length == s(7))
    }

    @Test func extractCopiesOriginalSamplesOnly() throws {
        let samples = (0 ..< s(16)).map { Float($0) }
        let plan = SpeechGapPlan(speech: [s(3) ..< s(4), s(12) ..< s(13)], originalCount: samples.count, keptGap: s(1))
        let out = plan.extract(from: samples)
        try #require(out.count == plan.compressedCount)
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

    // MARK: 境界（無音の長さが minSkippedGap ちょうど／1 サンプル長い）

    private func p(_ originalStart: Int, _ length: Int, _ compressedStart: Int) -> SpeechGapPlan.Piece {
        SpeechGapPlan.Piece(originalStart: originalStart, length: length, compressedStart: compressedStart)
    }

    @Test func gapExactlyAtTheMinimumIsKeptAndOneSampleLongerIsShortened() {
        // 発話と発話の間がちょうど 5 秒ならそのまま残す
        let exact = SpeechGapPlan(speech: [s(10) ..< s(11), s(16) ..< s(17)], originalCount: s(30), keptGap: s(1), minSkippedGap: s(5))
        #expect(exact.pieces == [p(s(9.5), s(8), 0)])
        // 1 サンプル長いと短くする
        let longer = SpeechGapPlan(speech: [s(10) ..< s(11), s(16) + 1 ..< s(17)], originalCount: s(30), keptGap: s(1), minSkippedGap: s(5))
        #expect(longer.pieces == [p(s(9.5), s(2), 0), p(s(15.5) + 1, s(2) - 1, s(2))])
        #expect(longer.compressedCount == s(4) - 1)
    }

    @Test func leadingAndTrailingSilenceBoundaries() {
        // 先頭の無音がちょうど 5 秒なら先頭から残す。1 サンプル長いと発話の 0.5 秒前から
        #expect(SpeechGapPlan(speech: [s(5) ..< s(6)], originalCount: s(30), keptGap: s(1), minSkippedGap: s(5)).pieces
            == [p(0, s(6.5), 0)])
        #expect(SpeechGapPlan(speech: [s(5) + 1 ..< s(6)], originalCount: s(30), keptGap: s(1), minSkippedGap: s(5)).pieces
            == [p(s(4.5) + 1, s(2) - 1, 0)])
        // 末尾の無音がちょうど 5 秒なら末尾まで残す。1 サンプル長いと発話の 0.5 秒後まで
        #expect(SpeechGapPlan(speech: [s(10) ..< s(25)], originalCount: s(30), keptGap: s(1), minSkippedGap: s(5)).pieces
            == [p(s(9.5), s(20.5), 0)])
        #expect(SpeechGapPlan(speech: [s(10) ..< s(25) - 1], originalCount: s(30), keptGap: s(1), minSkippedGap: s(5)).pieces
            == [p(s(9.5), s(16) - 1, 0)])
    }

    @Test func nestedSpeechMeasuresTheGapFromTheFurthestEnd() {
        // 2–3 秒は 1–9 秒の中。次の発話（12 秒）までの間は 9 秒からの 3 秒なので、短くしない
        let plan = SpeechGapPlan(speech: [s(1) ..< s(9), s(2) ..< s(3), s(12) ..< s(13)], originalCount: s(30), keptGap: s(1), minSkippedGap: s(5))
        #expect(plan.pieces == [p(0, s(13.5), 0)])
    }

    @Test func minimumBelowTheKeptGapActsAsTheKeptGap() {
        // minSkippedGap（0）は keptGap（1 秒）とみなすので、1 秒以下の先頭・末尾の無音は残る
        #expect(SpeechGapPlan(speech: [s(0.75) ..< s(2)], originalCount: s(10), keptGap: s(1)).pieces == [p(0, s(2.5), 0)])
        #expect(SpeechGapPlan(speech: [s(5) ..< s(9.25)], originalCount: s(10), keptGap: s(1)).pieces == [p(s(4.5), s(5.5), 0)])
    }

    @Test func withoutLongSilenceTheAudioAndTimesAreUnchanged() {
        let samples = (0 ..< s(8)).map { Float($0) }
        let plan = SpeechGapPlan(speech: [s(1) ..< s(2), s(5) ..< s(6)], originalCount: samples.count, keptGap: s(1), minSkippedGap: s(5))
        #expect(plan.pieces == [p(0, s(8), 0)])
        #expect(plan.extract(from: samples) == samples)
        for t in [0, 1.25, 4, 8.0] {
            #expect(abs(plan.originalTime(ofCompressed: t, sampleRate: rate, isEnd: false) - t) < 1e-9)
            #expect(abs(plan.originalTime(ofCompressed: t, sampleRate: rate, isEnd: true) - t) < 1e-9)
        }
    }

    @Test func mapsTimesAcrossManyPieces() {
        // 残す範囲: 2.5–4.5 → 0–2、11.5–13.5 → 2–4、21.5–23.5 → 4–6、31.5–33.5 → 6–8
        let plan = SpeechGapPlan(speech: [s(3) ..< s(4), s(12) ..< s(13), s(22) ..< s(23), s(32) ..< s(33)],
                                 originalCount: s(40), keptGap: s(1))
        let cases: [(TimeInterval, Bool, TimeInterval)] = [
            (2, false, 11.5), (2, true, 4.5), (4, false, 21.5), (4, true, 13.5),
            (6, false, 31.5), (6, true, 23.5), (5, true, 22.5), (7, false, 32.5), (8, false, 33.5),
        ]
        for (t, isEnd, expected) in cases {
            #expect(abs(plan.originalTime(ofCompressed: t, sampleRate: rate, isEnd: isEnd) - expected) < 1e-9, "t=\(t) isEnd=\(isEnd)")
        }
    }

    @Test func zeroLengthSegmentsAtAJoinNeverEndBeforeTheyStart() {
        let plan = SpeechGapPlan(speech: [s(3) ..< s(4), s(12) ..< s(13)], originalCount: s(16), keptGap: s(1))
        let segments = [(2.0, 2.0), (1.5, 2.0), (2.0, 2.5)].map { TranscriptSegment(start: $0.0, end: $0.1, text: "x") }
        let mapped = plan.mapToOriginal(segments, sampleRate: rate).map { ($0.start, $0.end) }
        let expected = [(11.5, 11.5), (4.0, 4.5), (11.5, 12.0)]
        for (m, e) in zip(mapped, expected) {
            #expect(abs(m.0 - e.0) < 1e-9 && abs(m.1 - e.1) < 1e-9, "\(m) != \(e)")
        }
    }

    /// 乱数（シード固定）で作った入力について、仕様の性質がいつも成り立つことを確かめる
    @Test func invariantsHoldForRandomInputs() throws {
        var rng = SplitMix64(seed: 0x5EED)
        for _ in 0 ..< 300 {
            let total = Int.random(in: 1 ... 40_000, using: &rng)
            let keptGap = Int.random(in: 0 ... 4_000, using: &rng)
            let minSkipped = Int.random(in: 0 ... 12_000, using: &rng)
            let speech: [Range<Int>] = (0 ..< Int.random(in: 0 ... 8, using: &rng)).map { _ in
                let lower = Int.random(in: 0 ..< total, using: &rng)
                return lower ..< min(total, lower + Int.random(in: 1 ... 6_000, using: &rng))
            }
            let plan = SpeechGapPlan(speech: speech, originalCount: total, keptGap: keptGap, minSkippedGap: minSkipped)
            let context = "total=\(total) keptGap=\(keptGap) minSkipped=\(minSkipped) speech=\(speech)"
            #expect(plan.isEmpty == speech.isEmpty, "\(context)")
            // 残す範囲は昇順で、重ならず接しもしない。短くした音声の上では隙間なく並ぶ
            var compressed = 0
            for (i, piece) in plan.pieces.enumerated() {
                #expect(piece.length > 0 && piece.originalStart >= 0 && piece.originalStart + piece.length <= total, "\(context)")
                #expect(piece.compressedStart == compressed, "\(context)")
                compressed += piece.length
                if i > 0 {
                    let previous = plan.pieces[i - 1]
                    #expect(previous.originalStart + previous.length < piece.originalStart, "\(context)")
                }
            }
            #expect(plan.compressedCount <= total, "\(context)")
            // 発話の前後 keptGap / 2 までは必ずどれかの範囲に入る
            for range in speech {
                let lower = max(range.lowerBound - keptGap / 2, 0)
                let upper = min(range.upperBound + keptGap / 2, total)
                #expect(plan.pieces.contains { $0.originalStart <= lower && upper <= $0.originalStart + $0.length }, "\(context) range=\(range)")
            }
            // 短くした音声の各位置は、元の音声の同じサンプルを指す（extract と originalTime が一致する）
            let samples = (0 ..< total).map { Float($0) }
            let out = plan.extract(from: samples)
            try #require(out.count == plan.compressedCount)
            var lastStart = -Double.infinity
            for c in stride(from: 0, to: out.count, by: max(out.count / 50, 1)) {
                let t = Double(c) / rate
                let start = plan.originalTime(ofCompressed: t, sampleRate: rate, isEnd: false)
                let end = plan.originalTime(ofCompressed: t, sampleRate: rate, isEnd: true)
                #expect(abs(start * rate - Double(out[c])) < 1e-6, "\(context) c=\(c)")
                #expect(end <= start + 1e-12, "\(context) c=\(c)")
                #expect(start >= lastStart, "\(context) c=\(c)")
                lastStart = start
            }
        }
    }
}

/// テスト用の乱数（シードを固定して、毎回同じ入力にする）
private struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

@Suite("長い無音を飛ばす設定とモデル")
@MainActor
struct SkipSilenceSettingTests {
    @Test func defaultsToOffAndPersists() throws {
        let suite = "WhisperBatchTests.skipSilence.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SettingsStore(defaults: defaults)
        #expect(!store.skipsLongSilence)
        #expect(store.makeSnapshot(appearance: nil).general?.skipsLongSilence == false)
        store.skipsLongSilence = true
        #expect(SettingsStore(defaults: defaults).skipsLongSilence)
    }

    @Test func modelIsPinnedAndNotATranscriptionModel() throws {
        let vad = ModelCatalog.voiceActivity
        #expect(vad.purpose == .voiceActivity)
        #expect(vad.engine == .whisper)
        #expect(ModelCatalog.auxiliary.contains(vad))
        #expect(!ModelCatalog.all.contains(vad))
        #expect(!ModelCatalog.models(for: .whisper).contains(vad))
        let file = try #require(vad.files.first)
        #expect(vad.files.count == 1)
        #expect(file.url.absoluteString == "https://huggingface.co/ggml-org/whisper-vad/resolve/9ffd54a1e1ee413ddf265af9913beaf518d1639b/ggml-silero-v6.2.0.bin")
        #expect(file.sha256 == "2aa269b785eeb53a82983a20501ddf7c1d9c48e33ab63a41391ac6c9f7fb6987")
        #expect(file.sizeBytes == 885_098)
    }
}

