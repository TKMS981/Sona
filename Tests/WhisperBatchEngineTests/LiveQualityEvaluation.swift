import Foundation
import Synchronization
import Testing
import WhisperBatchCore
@testable import WhisperBatchEngine

// ライブ文字起こしの認識品質を測る評価（実際の Whisper モデルを使う。環境変数を設定したときだけ実行する）。
//   WHISPER_BATCH_TEST_MODEL          : ggml モデルファイルのパス
//   WHISPER_BATCH_TEST_EVAL_SPEECH    : 実時間で流し込む音声ファイル
//   WHISPER_BATCH_TEST_EVAL_REFERENCE : 正解の文章（テキストファイル）
//   WHISPER_BATCH_TEST_EVAL_LANGUAGE  : 認識言語（ja / en。既定 ja）
//   WHISPER_BATCH_TEST_EVAL_GAIN_DB   : 音声の音量を変える（dB。例: -30 で小さな音声）
//   WHISPER_BATCH_TEST_EVAL_MUSIC_DB  : 伴奏の代わりの合成音（和音とリズム）を、声の音量からこの dB だけ下げて重ねる
//   WHISPER_BATCH_TEST_EVAL_LABEL     : 結果に付ける名前
//   WHISPER_BATCH_TEST_EVAL_OUT       : 結果を 1 行ずつ追記するファイル
//   WHISPER_BATCH_TEST_EVAL_VARIANT   : 比較用に変える設定（カンマ区切り）
//       noagree: 一致による確定をしない / context: 直前の文を手がかりにする（既定はしない）
//       pause045: 話の切れ目とみなす無音を 0.45 秒にする（既定 0.6 秒）
//       beam: ビーム探索（幅 5）で認識する
//   WHISPER_BATCH_TEST_EVAL_HINT      : 語彙のヒント
//
// 正解との差は文字（英語は単語）単位の編集距離で数える。数字の書き方（十一月 / 11 月）などの表記の違いも
// 誤りとして数えるので、値そのものより、同じ音声での設定の違いの比較に使う。

private let env = ProcessInfo.processInfo.environment
private let modelPath = env["WHISPER_BATCH_TEST_MODEL"].map { URL(fileURLWithPath: $0) }
private let evalSpeech = env["WHISPER_BATCH_TEST_EVAL_SPEECH"].map { URL(fileURLWithPath: $0) }
private let evalReference = env["WHISPER_BATCH_TEST_EVAL_REFERENCE"].map { URL(fileURLWithPath: $0) }

private let variant = Set((env["WHISPER_BATCH_TEST_EVAL_VARIANT"] ?? "").split(separator: ",").map(String.init))

/// ビーム探索で認識する（精度優先の設定の候補を比べるため）
private final class BeamRecognizer: LiveRecognizer {
    let context: WhisperContext
    init(context: WhisperContext) { self.context = context }
    func recognize(_ samples: [Float], language: String?, prompt: String?) async throws -> LiveRecognition {
        try await context.recognizeLive(samples, language: language, prompt: prompt, decoding: .beamSearch)
    }
}

/// 認識にかかった時間を記録する
private final class TimingRecognizer: LiveRecognizer {
    let base: any LiveRecognizer
    private let durations = Mutex<[Double]>([])
    init(base: any LiveRecognizer) { self.base = base }
    var timings: [Double] { durations.withLock { $0 } }
    func recognize(_ samples: [Float], language: String?, prompt: String?) async throws -> LiveRecognition {
        let start = ContinuousClock.now
        defer {
            let d = ContinuousClock.now - start
            durations.withLock { $0.append(Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18) }
        }
        return try await base.recognize(samples, language: language, prompt: prompt)
    }
}

@MainActor
private final class EvalSource: LiveAudioSource {
    let kind: LiveInputKind = .system
    private(set) var sink: LiveAudioSink?
    func start(sink: LiveAudioSink) async throws { self.sink = sink }
    func stop() async { sink = nil }
}

/// 編集距離の内訳
struct EditCounts: Equatable {
    var substitutions = 0
    var deletions = 0
    var insertions = 0
    var total: Int { substitutions + deletions + insertions }
}

enum EvalText {
    /// 比較用に句読点・空白・記号を除く（英語は小文字にして単語に分ける）
    static func tokens(_ text: String, words: Bool) -> [String] {
        let drop = CharacterSet.punctuationCharacters.union(.symbols).union(.whitespacesAndNewlines)
        if words {
            return text.lowercased()
                .components(separatedBy: CharacterSet.whitespacesAndNewlines)
                .map { String(String.UnicodeScalarView($0.unicodeScalars.filter { !drop.contains($0) })) }
                .filter { !$0.isEmpty }
        }
        return text.unicodeScalars.filter { !drop.contains($0) }.map { String($0) }
    }

    static func edits(reference: [String], hypothesis: [String]) -> EditCounts {
        let n = reference.count, m = hypothesis.count
        if n == 0 { return EditCounts(insertions: m) }
        if m == 0 { return EditCounts(deletions: n) }
        var prev = (0 ... m).map { EditCounts(insertions: $0) }
        for i in 1 ... n {
            var cur = [EditCounts(deletions: i)]
            for j in 1 ... m {
                var sub = prev[j - 1]
                if reference[i - 1] != hypothesis[j - 1] { sub.substitutions += 1 }
                var del = prev[j]; del.deletions += 1
                var ins = cur[j - 1]; ins.insertions += 1
                cur.append([sub, del, ins].min { $0.total < $1.total }!)
            }
            prev = cur
        }
        return prev[m]
    }
}

/// 伴奏の代わりの合成音（和音の持続音と、短い雑音のリズム）。毎回同じ音になる。
enum SyntheticMusic {
    static func make(frames: Int, sampleRate: Double) -> [Float] {
        let chords: [[Double]] = [[220, 277.18, 329.63], [196, 246.94, 293.66], [174.61, 220, 261.63], [196, 246.94, 329.63]]
        var out = [Float](repeating: 0, count: frames)
        var seed: UInt32 = 12345
        for i in 0 ..< frames {
            let t = Double(i) / sampleRate
            let chord = chords[Int(t / 2) % chords.count]
            var v = 0.0
            for f in chord {
                v += sin(2 * .pi * f * t) + 0.4 * sin(4 * .pi * f * t) + 0.2 * sin(6 * .pi * f * t)
            }
            // 8 分音符ごとの短い雑音（ハイハットの代わり）
            let beat = t.truncatingRemainder(dividingBy: 0.25)
            seed = seed &* 1_664_525 &+ 1_013_904_223
            let noise = Double(Int32(bitPattern: seed)) / Double(Int32.max)
            v += 1.5 * noise * exp(-beat * 40)
            out[i] = Float(v)
        }
        return out
    }
}

private func rms(_ x: [Float], voicedOnly: Bool) -> Float {
    let frame = 320
    var sum: Float = 0, count = 0
    for start in stride(from: 0, to: x.count - frame, by: frame) {
        var p: Float = 0
        for i in start ..< start + frame { p += x[i] * x[i] }
        p /= Float(frame)
        if !voicedOnly || p > 1e-5 { sum += p; count += 1 }
    }
    return count > 0 ? sqrt(sum / Float(count)) : 0
}

@Suite("ライブ文字起こしの品質評価（実際の Whisper）", .enabled(if: modelPath != nil && evalSpeech != nil && evalReference != nil), .serialized)
@MainActor
struct LiveQualityEvaluation {
    @Test func evaluate() async throws {
        let language: LanguageOption = env["WHISPER_BATCH_TEST_EVAL_LANGUAGE"] == "en" ? .english : .japanese
        let reference = try String(contentsOf: try #require(evalReference), encoding: .utf8)
        let reader = try await AudioSampleReader(url: try #require(evalSpeech))
        var audio = try await reader.read(maxFrames: Int(reader.duration * LiveAudioSink.sampleRate) + 16_000)
        // 終わりに 2 秒の無音（最後の文を確定させるため）
        audio += [Float](repeating: 0, count: 32_000)
        if let gain = env["WHISPER_BATCH_TEST_EVAL_GAIN_DB"].flatMap(Double.init) {
            let g = Float(pow(10, gain / 20))
            audio = audio.map { $0 * g }
        }
        if let musicDB = env["WHISPER_BATCH_TEST_EVAL_MUSIC_DB"].flatMap(Double.init) {
            var music = SyntheticMusic.make(frames: audio.count, sampleRate: LiveAudioSink.sampleRate)
            let target = rms(audio, voicedOnly: true) * Float(pow(10, -musicDB / 20))
            let scale = target / max(rms(music, voicedOnly: false), 1e-9)
            music = music.map { $0 * scale }
            audio = zip(audio, music).map { min(max($0 + $1, -1), 1) }
        }

        let url = try #require(modelPath)
        let model = ModelCatalog.all.first { $0.files.first?.name == url.lastPathComponent } ?? ModelCatalog.defaultModel(for: .whisper)
        let context = try await WhisperContext.load(model: model, fileURL: url)
        let recognizer = TimingRecognizer(base: variant.contains("beam") ? BeamRecognizer(context: context) : context)
        let source = EvalSource()
        let session = LiveTranscriptionSession(
            policy: LiveCommitPolicy(pauseToCommit: variant.contains("pause045") ? 0.45 : 0.6,
                                     commitsOnAgreement: !variant.contains("noagree")),
            promptBuilder: LivePromptBuilder(usesContext: variant.contains("context")),
            loadRecognizer: { _ in recognizer })
        await session.start(.init(model: model, language: language, sources: [source], labels: [.system: "eval"],
                                  vocabularyHint: env["WHISPER_BATCH_TEST_EVAL_HINT"] ?? ""))
        #expect(session.state == .running)

        // 実時間で 0.1 秒ずつ流し込み、区間が確定した時点と、画面に文字が出ている範囲を記録する
        var segmentLatencies: [Double] = []     // 区間の終わりから確定まで
        var batchLatencies: [Double] = []       // 一緒に確定した区間のうち最後の区間の終わりから確定まで
        var commits: [String] = []
        var shown: [(time: Double, end: Double)] = []
        var seen = 0
        let clock = ContinuousClock()
        let begin = clock.now
        for (i, offset) in stride(from: 0, to: audio.count, by: 1600).enumerated() {
            source.sink?.push(Array(audio[offset ..< min(offset + 1600, audio.count)]), from: .system)
            try await clock.sleep(until: begin + .milliseconds(100 * (i + 1)))
            let now = Double(i + 1) * 0.1
            let confirmed = session.transcript.confirmed
            if confirmed.count > seen {
                let batch = confirmed[seen...]
                for seg in batch { segmentLatencies.append(now - seg.end) }
                if let last = batch.last {
                    batchLatencies.append(now - last.end)
                    commits.append(String(format: "%.1f秒 %@ 遅れ%.1f「%@」", now, session.diagnostics.lastCommitReason.rawValue,
                                          now - last.end, batch.map(\.text).joined(separator: " ")))
                }
                seen = confirmed.count
            }
            let end = max(confirmed.last?.end ?? 0, session.transcript.provisional.last?.end ?? 0)
            shown.append((now, end))
        }
        await session.finish()

        let final = session.transcript.confirmed
        // 文字が画面に出るまでの遅れ（暫定・確定を問わず、その区間の終わり近くまで表示された時点）
        let displayLatencies = final.compactMap { seg in shown.first { $0.end >= seg.end - 0.3 }.map { max($0.time - seg.end, 0) } }
        let text = session.transcript.confirmedText
        let words = language == .english
        let ref = EvalText.tokens(reference, words: words)
        let hyp = EvalText.tokens(text, words: words)
        let e = EvalText.edits(reference: ref, hypothesis: hyp)
        let rate = Double(e.total) / Double(max(ref.count, 1))
        let label = env["WHISPER_BATCH_TEST_EVAL_LABEL"] ?? evalSpeech!.lastPathComponent
        let t = recognizer.timings
        let d = session.diagnostics
        func stats(_ x: [Double]) -> String {
            String(format: "中央 %.2f・p95 %.2f・最大 %.2f", Stats.percentile(x, 0.5), Stats.percentile(x, 0.95), x.max() ?? 0)
        }
        let line = String(format: "%@\t誤り率 %.3f（置換 %d・脱落 %d・挿入 %d / %d）\t区間 %d\t確定までの遅れ 平均 %.2f 秒・最大 %.2f 秒\t認識 %d 回・平均 %.2f 秒・最大 %.2f 秒\t取りこぼし %.1f 秒",
                          label, rate, e.substitutions, e.deletions, e.insertions, ref.count,
                          final.count, Stats.mean(segmentLatencies), segmentLatencies.max() ?? 0,
                          t.count, Stats.mean(t), t.max() ?? 0, session.droppedSeconds)
        let detail = [
            "# 区間ごとの確定の遅れ: " + stats(segmentLatencies),
            "# 発話のまとまりの終わりから確定まで: " + stats(batchLatencies),
            "# 文字が画面に出るまで: " + stats(displayLatencies),
            "# 認識時間: " + stats(t),
            String(format: "# 確定の理由: %@ / 発話なしとして読まずに捨てた音声 %.1f 秒 / 処理が追いつかずに捨てた音声 %.1f 秒 / 認識待ちの最大 %.1f 秒 / 1 回の認識の最大の長さ %.1f 秒",
                   LiveCommitPolicy.Decision.Reason.allCases.compactMap { r in d.commits[r].map { "\(r.rawValue)=\($0)" } }.joined(separator: ","),
                   d.silenceSkippedSeconds, session.droppedSeconds, d.longestBacklogSeconds, d.longestWindowSeconds),
        ] + commits.map { "#   " + $0 }
        print("確定した文:\n\(text)")
        print(line)
        print(detail.joined(separator: "\n"))
        if let out = env["WHISPER_BATCH_TEST_EVAL_OUT"] {
            let entry = line + "\n" + text.replacingOccurrences(of: "\n", with: " / ") + "\n" + detail.joined(separator: "\n") + "\n\n"
            if let handle = FileHandle(forWritingAtPath: out) {
                handle.seekToEndOfFile()
                handle.write(Data(entry.utf8))
                try? handle.close()
            } else {
                try entry.write(toFile: out, atomically: true, encoding: .utf8)
            }
        }
        #expect(!text.isEmpty)
    }
}

enum Stats {
    static func mean(_ x: [Double]) -> Double { x.isEmpty ? 0 : x.reduce(0, +) / Double(x.count) }
    /// 最も近い順位の値（nearest-rank）
    static func percentile(_ x: [Double], _ p: Double) -> Double {
        guard !x.isEmpty else { return 0 }
        let sorted = x.sorted()
        let rank = max(Int((p * Double(sorted.count)).rounded(.up)) - 1, 0)
        return sorted[min(rank, sorted.count - 1)]
    }
}

@Suite("品質評価の計算")
struct EvalTextTests {
    @Test func editDistanceCountsKinds() {
        let e = EvalText.edits(reference: ["a", "b", "c", "d"], hypothesis: ["a", "x", "c", "d", "e"])
        #expect(e == EditCounts(substitutions: 1, deletions: 0, insertions: 1))
        #expect(EvalText.edits(reference: ["a", "b"], hypothesis: []).deletions == 2)
        #expect(EvalText.edits(reference: [], hypothesis: ["a"]).insertions == 1)
    }

    @Test func percentiles() {
        #expect(Stats.percentile([5, 1, 3, 2, 4], 0.5) == 3)
        #expect(Stats.percentile([1, 2, 3, 4, 5, 6, 7, 8, 9, 10], 0.95) == 10)
        #expect(Stats.percentile([], 0.5) == 0)
    }

    @Test func tokensIgnorePunctuation() {
        #expect(EvalText.tokens("今日は、晴れ。", words: false) == ["今", "日", "は", "晴", "れ"])
        #expect(EvalText.tokens("Hello, World!", words: true) == ["hello", "world"])
    }
}

// 2 つの実際の音声を同時に鳴らしたときの、混合（AudioMixer）のピーク抑制の確認。
//   WHISPER_BATCH_TEST_EVAL_MIX_A / _MIX_B : 混ぜる 2 つの音声ファイル
private let mixA = env["WHISPER_BATCH_TEST_EVAL_MIX_A"].map { URL(fileURLWithPath: $0) }
private let mixB = env["WHISPER_BATCH_TEST_EVAL_MIX_B"].map { URL(fileURLWithPath: $0) }

@Suite("ライブ文字起こし: 実際の音声での混合", .enabled(if: mixA != nil && mixB != nil))
struct LiveMixerOnRealAudio {
    @Test func limiterOnTwoLoudVoices() async throws {
        let a = try await AudioSampleReader(url: try #require(mixA))
        let b = try await AudioSampleReader(url: try #require(mixB))
        let x = try await a.read(maxFrames: Int(min(a.duration, b.duration) * 16_000))
        let y = try await b.read(maxFrames: x.count)
        for gainDB in [0.0, 6, 12] {
            let g = Float(pow(10, gainDB / 20))
            var mixer = AudioMixer<LiveInputKind>(sampleRate: 16_000, capacity: 200)
            mixer.setInputs([.system, .microphone])
            mixer.append(x.map { min(max($0 * g, -1), 1) }, to: .system)
            mixer.append(Array(y.prefix(x.count)).map { min(max($0 * g, -1), 1) }, to: .microphone)
            let out = mixer.drain()
            let raw = zip(x, y).map { min(max($0 * g, -1), 1) + min(max($1 * g, -1), 1) }
            let overKnee = raw.filter { abs($0) > 0.8 }.count
            let overOne = raw.filter { abs($0) > 1 }.count
            let unchanged = zip(raw, out).filter { abs($0.0) <= 0.8 }.allSatisfy { $0.0 == $0.1 }
            print(String(format: "+%.0fdB: 足し合わせの最大 %.2f、0.8 超 %.3f%%、1 超 %.3f%%、出力の最大 %.3f、0.8 以下は変更なし %@",
                         gainDB, raw.map(abs).max() ?? 0, 100 * Double(overKnee) / Double(raw.count),
                         100 * Double(overOne) / Double(raw.count), out.map(abs).max() ?? 0, unchanged ? "はい" : "いいえ"))
            #expect((out.map(abs).max() ?? 0) < 1)
            #expect(unchanged)
        }
    }
}
