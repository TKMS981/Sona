import Darwin
import Foundation
import Synchronization
import Testing
import WhisperBatchCore
import WhisperBatchEngine
@testable import SonaLLM

// 誤認識の修正の計測（処理時間の内訳と修正の正確さ。最適化の前後比較用）。次の環境変数を設定したときだけ実行する。
//   WHISPER_BATCH_TEST_BENCH_OUT : 結果を追記するファイル（返答の全文は <名前>.outputs に書く）
//   WHISPER_BATCH_TEST_LLM_DIR   : カタログのファイル名の GGUF を置いたフォルダ
//   WHISPER_BATCH_TEST_BENCH_LLM : 計測するモデルの id（カンマ区切り。既定 tinyswallow-1.5b,qwen3-4b）
//   WHISPER_BATCH_TEST_BENCH_INSTRUCTIONS : （任意）まとめての修正の指示を差し替えるフォルダ（ja.txt・en.txt）。指示の案を比べるとき用
//   WHISPER_BATCH_TEST_BENCH_LLAMA : （任意）読み込みの設定を変えて比べる（例 "batch=2048,ubatch=1024,threads=perf,kv=q8_0"。
//                                    threads は数か perf＝性能コアの数。指定のない項目はアプリの設定のまま）
// 誤りを入れた合成の文字起こし（正解つき）で、画面と同じ AITaskRunner の処理を行う。結果の再利用（AIResultCache）は通さない。

private let env = ProcessInfo.processInfo.environment
private let benchOut = env["WHISPER_BATCH_TEST_BENCH_OUT"].map { URL(fileURLWithPath: $0) }
private let llmDir = env["WHISPER_BATCH_TEST_LLM_DIR"].map { URL(fileURLWithPath: $0) }
private let benchModels = (env["WHISPER_BATCH_TEST_BENCH_LLM"] ?? "tinyswallow-1.5b,qwen3-4b").split(separator: ",").map(String.init)
private let instructionOverrides: [String: String] = {
    guard let dir = env["WHISPER_BATCH_TEST_BENCH_INSTRUCTIONS"] else { return [:] }
    var result: [String: String] = [:]
    for (language, name) in [(LocalAIText.OutputLanguage.japanese, "ja"), (.english, "en")] {
        let url = URL(fileURLWithPath: dir).appendingPathComponent("\(name).txt")
        if let text = try? String(contentsOf: url, encoding: .utf8) {
            result[LocalAIText.correctionBatchInstructions(language)] = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
    return result
}()

/// 計測する読み込みの設定（指定がなければアプリと同じ）
private let loadConfig: LlamaLoadConfig = {
    var config = LlamaLoadConfig.standard
    for item in (env["WHISPER_BATCH_TEST_BENCH_LLAMA"] ?? "").split(separator: ",") {
        let kv = item.split(separator: "=", maxSplits: 1).map { String($0).trimmingCharacters(in: .whitespaces) }
        guard kv.count == 2 else { continue }
        switch kv[0] {
        case "batch": config.batch = UInt32(kv[1]) ?? config.batch
        case "ubatch": config.ubatch = UInt32(kv[1]) ?? config.ubatch
        case "threads": config.threads = kv[1] == "perf" ? (LlamaLoadConfig.performanceCores ?? 4) : (Int32(kv[1]) ?? config.threads)
        case "kv": if let type = LlamaLoadConfig.CacheType(rawValue: kv[1]) { config.cacheK = type; config.cacheV = type }
        default: break
        }
    }
    return config
}()

/// このプロセスが使っているメモリ（phys_footprint。Metal に置いたモデル・KV キャッシュも含む）
private func footprintMB() -> Int {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
    }
    return result == KERN_SUCCESS ? Int(info.phys_footprint / 1_048_576) : 0
}

private func append(_ line: String, to url: URL) {
    let data = Data((line + "\n").utf8)
    if let handle = try? FileHandle(forWritingTo: url) {
        handle.seekToEndOfFile()
        handle.write(data)
        try? handle.close()
    } else {
        try? data.write(to: url)
    }
}

private func record(_ line: String) {
    guard let benchOut else { return }
    append(line, to: benchOut)
    print(line)
}

private func recordOutput(_ label: String, _ text: String) {
    guard let benchOut else { return }
    append("## \(label)\n\(text)", to: benchOut.appendingPathExtension("outputs"))
}

private func sec(_ d: Duration) -> Double {
    Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
}

private func f(_ x: Double) -> String { String(format: "%.3f", x) }

/// 正解つきの文（`wrong` が nil なら誤りのない文）
private struct Sample {
    var correct: String
    var wrong: String?
    var shown: String { wrong ?? correct }
}

/// 会議の文字起こし（日本語）。人名・数字・日付・金額・英字の語・地名を含む。
private let meetingJA: [Sample] = [
    .init(correct: "本日は第3四半期の売上について報告します。"),
    .init(correct: "司会は営業部の佐藤さんにお願いします。"),
    .init(correct: "先月の売上は前年比で12％増加しました。"),
    .init(correct: "特に東京と大阪の店舗が好調でした。"),
    .init(correct: "一方で、新製品の在庫が不足しています。", wrong: "一方で、新製品の在庫が不測しています。"),
    .init(correct: "工場の生産体制を見直す必要があります。", wrong: "工場の生産大勢を見直す必要があります。"),
    .init(correct: "来週の月曜日に工場を見学する予定です。", wrong: "来週の月曜日に工場を建学する予定です。"),
    .init(correct: "見学には鈴木部長も参加します。"),
    .init(correct: "次に、広告の予算について説明します。", wrong: "次に、公告の予算について説明します。"),
    .init(correct: "今年度の広告費は450万円を予定しています。"),
    .init(correct: "SNSでの宣伝を強化したいと考えています。", wrong: "SNSでの宣伝を教化したいと考えています。"),
    .init(correct: "InstagramとYouTubeを中心に展開します。"),
    .init(correct: "若い世代の関心を集めることが目標です。", wrong: "若い世代の感心を集めることが目標です。"),
    .init(correct: "次回の会議は11月20日の午後2時からです。"),
    .init(correct: "会場は本社の会議室です。", wrong: "会場は本社の会議質です。"),
    .init(correct: "資料は前日までに共有してください。"),
    .init(correct: "質問がある方は挙手をお願いします。"),
    .init(correct: "価格の設定について意見を聞かせてください。"),
    .init(correct: "競合他社の価格と比較する必要があります。", wrong: "強豪他社の価格と比較する必要があります。"),
    .init(correct: "品質を保証するための検査を強化します。"),
    .init(correct: "顧客からの意見を製品の改善に生かします。"),
    .init(correct: "問い合わせの件数は先月より減りました。", wrong: "問い合わせの県数は先月より減りました。"),
    .init(correct: "サポートの対応時間を延長する予定です。", wrong: "サポートの対応時間を園長する予定です。"),
    .init(correct: "新しいシステムの導入は来年の春です。"),
    .init(correct: "移行の作業は情報システム部が担当します。", wrong: "意向の作業は情報システム部が担当します。"),
    .init(correct: "担当の窓口は株式会社ミライテックです。"),
    .init(correct: "社員向けの説明会を開く予定です。"),
    .init(correct: "説明会の日程は改めて連絡します。"),
    .init(correct: "以上で本日の報告を終わります。", wrong: "以上で本日の方向を終わります。"),
    .init(correct: "最後に、田中社長から一言お願いします。"),
]

private let meetingEN: [Sample] = [
    .init(correct: "The meeting will be held on March 15 at the Tokyo office."),
    .init(correct: "Please send the report to Mr. Smith by Friday.", wrong: "Please send the report to Mr. Smith buy Friday."),
    .init(correct: "Our sales increased by 12 percent last quarter.", wrong: "Our sails increased by 12 percent last quarter."),
    .init(correct: "We need to hear more from our customers.", wrong: "We need to here more from our customers."),
    .init(correct: "The new budget is 4.5 million yen."),
]

/// 誤りを入れる文の番号を選んで、残りは正しい文にする
private func dataset(_ base: [Sample], indices: [Int]? = nil, errors: Set<Int>) -> [Sample] {
    (indices ?? Array(base.indices)).map { i in
        var s = base[i]
        if !errors.contains(i) { s.wrong = nil }
        return s
    }
}

private let allJAErrors = Set(meetingJA.indices.filter { meetingJA[$0].wrong != nil })

private let datasets: [(name: String, language: String, samples: [Sample], hints: [Int: [String]])] = [
    // 短文・誤りなし（固有名詞・数字だけ）
    ("ja-short-none", "ja", dataset(meetingJA, indices: [1, 9, 13], errors: []), [:]),
    // 短文・誤り 1 つ
    ("ja-short-few", "ja", dataset(meetingJA, indices: [3, 4, 7], errors: [4]), [:]),
    // 短文・誤りが多い
    ("ja-short-many", "ja", dataset(meetingJA, indices: [4, 5, 8, 12], errors: [4, 5, 8, 12]), [:]),
    // 長文・誤り 2 つ
    ("ja-long-few", "ja", dataset(meetingJA, errors: [4, 28]), [:]),
    // 長文・誤りが多い（確からしさが低い語の手がかりを一部に付ける。誤りのない文にも 1 つ）
    ("ja-long-many", "ja", dataset(meetingJA, errors: allJAErrors), [4: ["不測"], 14: ["会議質"], 21: ["県数"], 2: ["12％"]]),
    ("en-short", "en", meetingEN, [:]),
]

/// 生成器の呼び出しを、内訳を記録しながら行う（LlamaGenerator.generate と同じ手順）
private final class MeasuringGenerator: TextGenerator, Sendable {
    struct Call: Sendable {
        var stats: LlamaRunStats
        var wall: Duration
        var extract: Duration
        var raw: String
        var answer: String
    }

    let base: LlamaGenerator
    private let state = Mutex<[Call]>([])

    init(base: LlamaGenerator) { self.base = base }

    var displayName: String { base.displayName }
    var maxInputCharacters: Int { base.maxInputCharacters }
    var calls: [Call] { state.withLock { $0 } }
    func reset() { state.withLock { $0 = [] } }

    func generate(_ request: GenerationRequest) async throws -> String {
        let spec = base.model.spec
        let instructions = instructionOverrides[request.instructions] ?? request.instructions
        let prompt = spec.format.render(system: instructions, user: request.prompt)
        let clock = ContinuousClock()
        let t0 = clock.now
        let raw = try await base.model.complete(prompt: prompt, greedy: request.greedy, maxTokens: request.maxTokens)
        let t1 = clock.now
        let answer = spec.format.extractAnswer(raw)
        let t2 = clock.now
        let stats = try #require(base.model.lastRunStats)
        state.withLock { $0.append(Call(stats: stats, wall: t1 - t0, extract: t2 - t1, raw: raw, answer: answer)) }
        return answer
    }
}

/// 修正の正確さ
private struct Accuracy: CustomStringConvertible {
    var errors = 0, fixed = 0, missed = 0, wrongFix = 0, falseChange = 0, protectedChanged = 0, rejected = 0

    var description: String {
        "errors=\(errors)\tfixed=\(fixed)\tmissed=\(missed)\twrongFix=\(wrongFix)\tfalseChange=\(falseChange)"
            + "\tprotectedChanged=\(protectedChanged)\tguardRejected=\(rejected)"
    }
}

private func evaluate(_ samples: [Sample], outcome: RewriteOutcome) -> (Accuracy, [String]) {
    var acc = Accuracy()
    acc.rejected = outcome.rejected.count
    let applied = Dictionary(outcome.candidates.map { ($0.index, $0.rewritten) }, uniquingKeysWith: { a, _ in a })
    var finals: [String] = []
    for (i, s) in samples.enumerated() {
        let final = applied[i] ?? s.shown
        finals.append(final)
        if s.wrong != nil {
            acc.errors += 1
            if final == s.correct { acc.fixed += 1 } else if final == s.shown { acc.missed += 1 } else { acc.wrongFix += 1 }
        } else if final != s.correct {
            acc.falseChange += 1
        }
        if RewriteGuard.protectedTokens(in: final) != RewriteGuard.protectedTokens(in: s.correct) { acc.protectedChanged += 1 }
    }
    return (acc, finals)
}

@Suite("誤認識の修正の計測（ローカルの言語モデル）", .enabled(if: benchOut != nil && llmDir != nil), .serialized)
struct CorrectionBenchmarks {
    init() { TestLocalization.setUp() }

    @Test(arguments: benchModels)
    func correction(id: String) async throws {
        let model = try #require(LocalLLMCatalog.model(id: id))
        let source = llmDir!.appendingPathComponent(model.file.name)
        try #require(FileManager.default.fileExists(atPath: source.path))
        let label = env["WHISPER_BATCH_TEST_BENCH_LABEL"] ?? "run"

        // 画面と同じく、読み込む前にファイルを照合する（取得済みのモデルとして置く。ハードリンク）
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sona-bench-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let storage = ModelStorage(directory: dir)
        let download = model.downloadModel
        let dest = storage.fileURL(for: download.files[0], of: download)
        try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.linkItem(at: source, to: dest)
        let clock = ContinuousClock()
        var t = clock.now
        try await storage.verifyContents(of: download)
        let verify = clock.now - t

        let host = LlamaModelHost(idleTimeout: .seconds(180), loadConfig: loadConfig)
        let memBefore = footprintMB()
        // 生成器はこの中だけで持つ（抜けたら手放す）
        do {
            t = clock.now
            let leased = try await host.generator(for: model, fileURL: dest)
            let load = clock.now - t
            record("load\t\(label)\t\(id)\tverifySeconds=\(f(sec(verify)))\tloadSeconds=\(f(sec(load)))"
                + "\tmemBeforeMB=\(memBefore)\tmemLoadedMB=\(footprintMB())\tconfig=\(loadConfig.signature)")
            let generator = MeasuringGenerator(base: try #require(leased as? LlamaGenerator))

            for set in datasets {
                let transcript = Transcript(segments: set.samples.enumerated().map { i, s in
                    TranscriptSegment(start: Double(i) * 4, end: Double(i) * 4 + 4, text: s.shown)
                }, language: set.language)
                let lines = LocalAIText.lines(original: transcript, edits: TranscriptEdits(), speakerNames: [:])
                generator.reset()
                t = clock.now
                let outcome = try await AITaskRunner.rewrite(.correction, lines: lines, suspicious: set.hints,
                                                             generator: generator, languageCode: set.language)
                let total = clock.now - t
                let calls = generator.calls
                let promptTokens = calls.map(\.stats.promptTokens).reduce(0, +)
                let genTokens = calls.map(\.stats.generatedTokens).reduce(0, +)
                let promptSec = calls.map { sec($0.stats.promptDuration) }.reduce(0, +)
                let decodeSec = calls.map { sec($0.stats.decodeDuration) }.reduce(0, +)
                let wallSec = calls.map { sec($0.wall) }.reduce(0, +)
                let extractSec = calls.map { sec($0.extract) }.reduce(0, +)
                // 依頼の組み立て・返答の読み取り・検査（生成器の外の処理）
                let postSec = sec(total) - wallSec
                let rawChars = calls.map(\.raw.count).reduce(0, +)
                let answerChars = calls.map(\.answer.count).reduce(0, +)
                let hitBudget = calls.filter { $0.stats.generatedTokens >= $0.stats.budget }.count
                let (acc, finals) = evaluate(set.samples, outcome: outcome)
                let rate = decodeSec > 0 ? Double(genTokens) / decodeSec : 0
                var fields = ["correction", label, id, set.name, "lines=\(lines.count)", "calls=\(calls.count)"]
                fields += ["promptTokens=\(promptTokens)", "promptSeconds=\(f(promptSec))"]
                fields += ["genTokens=\(genTokens)", "decodeSeconds=\(f(decodeSec))", "genTokPerSec=\(f(rate))"]
                fields += ["rawChars=\(rawChars)", "answerChars=\(answerChars)", "hitBudget=\(hitBudget)"]
                fields += ["extractSeconds=\(f(extractSec))", "postSeconds=\(f(postSec))", "totalSeconds=\(f(sec(total)))", acc.description]
                record(fields.joined(separator: "\t"))
                recordOutput("\(label) \(id) \(set.name) raw", calls.map(\.raw).joined(separator: "\n---\n"))
                var report: [String] = []
                for (i, s) in set.samples.enumerated() {
                    let final = finals[i]
                    let mark: String
                    if s.wrong == nil {
                        mark = final == s.correct ? "  " : "!!"
                    } else {
                        mark = final == s.correct ? "OK" : (final == s.shown ? "--" : "XX")
                    }
                    report.append("\(mark) #\(i + 1) \(final)" + (final == s.correct ? "" : "   [正解: \(s.correct)]"))
                }
                let rejectedText = outcome.rejected.map { "#\($0.index + 1) \($0.rewritten) \($0.violations)" }.joined(separator: " / ")
                recordOutput("\(label) \(id) \(set.name) result", report.joined(separator: "\n") + "\nrejected: " + rejectedText)
            }

            // 1 区間ごとの修正案（編集画面の「修正案」）
            let singles: [(target: Int, base: [Sample])] = [(4, meetingJA), (9, meetingJA), (28, meetingJA)]
            for (target, base) in singles {
                let s = base[target]
                generator.reset()
                t = clock.now
                let suggestion = try await AITaskRunner.suggestCorrection(
                    target: s.shown, before: base[max(0, target - 2) ..< target].map(\.correct),
                    after: base[(target + 1) ..< min(base.count, target + 3)].map(\.correct), suspicious: [],
                    generator: generator, languageCode: "ja")
                let total = clock.now - t
                let calls = generator.calls
                let call = try #require(calls.first)
                let final = suggestion ?? s.shown
                let verdict = s.wrong == nil ? (final == s.correct ? "keptClean" : "falseChange")
                    : (final == s.correct ? "fixed" : final == s.shown ? "missed" : "wrongFix")
                record("suggest\t\(label)\t\(id)\t#\(target + 1)\tpromptTokens=\(call.stats.promptTokens)\tpromptSeconds=\(f(sec(call.stats.promptDuration)))"
                    + "\tgenTokens=\(call.stats.generatedTokens)\tdecodeSeconds=\(f(sec(call.stats.decodeDuration)))"
                    + "\ttotalSeconds=\(f(sec(total)))\tresult=\(verdict)")
                recordOutput("\(label) \(id) suggest #\(target + 1)", "raw: \(call.raw)\nsuggestion: \(suggestion ?? "nil")")
            }

            // 長い入力（要約。入力の処理＝バッチの大きさの影響を見る）
            let long = Transcript(segments: (0 ..< 3).flatMap { _ in meetingJA }.enumerated().map { i, s in
                TranscriptSegment(start: Double(i) * 4, end: Double(i) * 4 + 4, text: s.correct)
            }, language: "ja")
            let longLines = LocalAIText.lines(original: long, edits: TranscriptEdits(), speakerNames: [:])
            generator.reset()
            t = clock.now
            let summary = try await AITaskRunner.summarize(longLines, generator: generator, languageCode: "ja")
            let summaryTotal = clock.now - t
            let sc = generator.calls
            record("summary\t\(label)\t\(id)\tcalls=\(sc.count)\tpromptTokens=\(sc.map(\.stats.promptTokens).reduce(0, +))"
                + "\tpromptSeconds=\(f(sc.map { sec($0.stats.promptDuration) }.reduce(0, +)))"
                + "\tgenTokens=\(sc.map(\.stats.generatedTokens).reduce(0, +))\tdecodeSeconds=\(f(sc.map { sec($0.stats.decodeDuration) }.reduce(0, +)))"
                + "\ttotalSeconds=\(f(sec(summaryTotal)))\tmemAfterRunsMB=\(footprintMB())")
            recordOutput("\(label) \(id) summary", summary.joined(separator: "\n"))
        }
        // 生成器を手放してから解放する（持ったままだと使い終わるまで解放されず、終了時に ggml-metal が止まる）
        await host.release()
        #expect(await host.loadedModelID == nil)
    }
}
