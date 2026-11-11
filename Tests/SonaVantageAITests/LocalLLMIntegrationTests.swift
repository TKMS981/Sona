import Darwin
import Foundation
import Testing
import WhisperBatchCore
@testable import SonaLLM

// ローカルの言語モデル（llama.cpp）の結合テスト。次の環境変数を設定したときだけ実行する。
//   WHISPER_BATCH_TEST_LLM_DIR : カタログのファイル名（LocalLLM.file.name）の GGUF を置いたフォルダ。
//                                置いてあるモデルだけを試す（SHA-256 は取得時に照合しておく）。
// 結果（生成した文・かかった時間）は標準出力に出す。合成した短い文で試すもので、実際の録音での精度は確かめない。

private let llmDir = ProcessInfo.processInfo.environment["WHISPER_BATCH_TEST_LLM_DIR"].map { URL(fileURLWithPath: $0) }

private func fileURL(_ model: LocalLLM) -> URL? {
    guard let dir = llmDir else { return nil }
    let url = dir.appendingPathComponent(model.file.name)
    return FileManager.default.fileExists(atPath: url.path) ? url : nil
}

/// このプロセスが使っているメモリ（phys_footprint。Metal に置いたモデルも含む）
private func footprint() -> Int64 {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
    }
    return result == KERN_SUCCESS ? Int64(info.phys_footprint) : 0
}

private let japanese = Transcript(segments: [
    .init(start: 0, end: 4, text: "えー、本日は新製品の発売日について話し合います。", speaker: 0),
    .init(start: 4, end: 9, text: "発売日は来月の十五日に決定しました。", speaker: 0),
    .init(start: 9, end: 13, text: "資料は田中さんが金曜日までに用意してください。", speaker: 1),
    .init(start: 13, end: 17, text: "広告の予算は三百万円を予定しています", speaker: 0),
    .init(start: 17, end: 21, text: "在庫の不足が課題として残っています", speaker: 1),
], language: "ja")

private let english = Transcript(segments: [
    .init(start: 0, end: 4, text: "um so today we will talk about the launch date of the new product"),
    .init(start: 4, end: 8, text: "We decided to launch on March 15."),
    .init(start: 8, end: 12, text: "Tanaka will prepare the slides by Friday."),
    .init(start: 12, end: 16, text: "The advertising budget is 3 million yen."),
], language: "en")

private func lines(_ t: Transcript) -> [LocalAIText.Line] {
    LocalAIText.lines(original: t, edits: TranscriptEdits(), speakerNames: [:])
}

/// 返答に、特別なトークンや思考が残っていない
private func isClean(_ text: String) -> Bool {
    !text.contains("<|") && !text.contains("|>") && !text.contains("<think") && !text.contains("<turn") && !text.contains("[INST]")
}

@Suite("ローカルの言語モデル（llama.cpp・実モデル）", .enabled(if: llmDir != nil), .serialized)
struct LocalLLMIntegrationTests {
    init() { TestLocalization.setUp() }

    @Test(arguments: LocalLLMCatalog.all.map(\.id))
    func generatesCleanOutput(id: String) async throws {
        let model = try #require(LocalLLMCatalog.model(id: id))
        guard let url = fileURL(model) else {
            print("[\(id)] ファイルがないので試さない")
            return
        }
        let host = LlamaModelHost()
        let clock = ContinuousClock()
        let loadStart = clock.now
        let generator = try await host.generator(for: model, fileURL: url)
        print("[\(id)] 読み込み \(clock.now - loadStart)")
        defer { Task { await host.release() } }

        if model.isTranslationOnly {
            let t0 = clock.now
            let en = try await generator.translate("本日は新製品の発売日について話し合います。", from: "ja", to: "en")
            let ja = try await generator.translate("We decided to launch the new product on March 15.", from: "en", to: "ja")
            print("[\(id)] 翻訳 ja→en: \(en) / en→ja: \(ja) (\(clock.now - t0))")
            #expect(isClean(en) && isClean(ja))
            #expect(en.lowercased().contains("product") || en.lowercased().contains("release") || en.lowercased().contains("launch"))
            #expect(ja.contains("15") || ja.contains("十五"))
            await host.release()
            return
        }

        let t0 = clock.now
        let summary = try await AITaskRunner.summarize(lines(japanese), generator: generator, languageCode: "ja")
        print("[\(id)] 要約(ja): \(summary) (\(clock.now - t0))")
        #expect(!summary.isEmpty)
        #expect(summary.allSatisfy(isClean))

        let t1 = clock.now
        let enSummary = try await AITaskRunner.summarize(lines(english), generator: generator, languageCode: "en")
        print("[\(id)] 要約(en): \(enSummary) (\(clock.now - t1))")
        #expect(!enSummary.isEmpty)
        #expect(enSummary.allSatisfy(isClean))

        let t2 = clock.now
        let points = try await AITaskRunner.keyPoints(lines(japanese), segments: japanese.segments, generator: generator,
                                                      languageCode: "ja")
        print("[\(id)] 重要な発言: \(points.map(\.text)) (\(clock.now - t2))")
        #expect(points.allSatisfy { p in japanese.segments.contains { $0.text == p.text } })

        let t3 = clock.now
        let polish = try await AITaskRunner.rewrite(.polish, lines: lines(japanese), generator: generator, languageCode: "ja")
        print("[\(id)] 整形: 候補 \(polish.candidates.map(\.rewritten)) 検査で除外 \(polish.rejected.count) (\(clock.now - t3))")
        #expect(polish.candidates.allSatisfy { RewriteGuard.check(original: $0.original, rewritten: $0.rewritten, task: .polish).isEmpty })

        let t4 = clock.now
        let wrong = Transcript(segments: [.init(start: 0, end: 3, text: "会議の議事録を自動で作製します。"),
                                          .init(start: 3, end: 6, text: "来週の会議出また報告します。")], language: "ja")
        let correction = try await AITaskRunner.rewrite(.correction, lines: lines(wrong), generator: generator, languageCode: "ja")
        print("[\(id)] 誤認識の修正: 候補 \(correction.candidates.map(\.rewritten)) 検査で除外 \(correction.rejected.map(\.rewritten)) (\(clock.now - t4))")
        #expect(correction.candidates.allSatisfy {
            RewriteGuard.check(original: $0.original, rewritten: $0.rewritten, task: .correction).isEmpty
        })

        if model.tasks.contains(.translation) {
            let t5 = clock.now
            let en = try await generator.translate("本日は新製品の発売日について話し合います。", from: "ja", to: "en")
            print("[\(id)] 翻訳 ja→en: \(en) (\(clock.now - t5))")
            #expect(isClean(en))
        }
        await host.release()
    }

    /// 別のモデルに切り替えると前のモデルを解放する（メモリに 2 つを同時に置かない）
    @Test func switchingReleasesThePreviousModel() async throws {
        let candidates = ["tinyswallow-1.5b", "qwen3-1.7b"].compactMap(LocalLLMCatalog.model(id:))
        let urls = candidates.compactMap(fileURL)
        guard urls.count == 2 else { print("切り替えのテストに使うファイルがない"); return }
        let host = LlamaModelHost()
        let base = footprint()
        _ = try await host.generator(for: candidates[0], fileURL: urls[0])
        let first = footprint()
        #expect(await host.loadedModelID == candidates[0].id)
        _ = try await host.generator(for: candidates[1], fileURL: urls[1])
        let second = footprint()
        #expect(await host.loadedModelID == candidates[1].id)
        await host.release()
        let released = footprint()
        #expect(await host.loadedModelID == nil)
        let mb = { (x: Int64) in x / 1_000_000 }
        print("メモリ: 開始 \(mb(base))MB → 1 つ目 \(mb(first))MB → 切り替え後 \(mb(second))MB → 解放後 \(mb(released))MB")
        // 2 つ目を読み込んだ後も、2 つのモデルの合計ぶんは増えていない（1 つ目を解放している）
        #expect(second - base < candidates[0].file.sizeBytes + candidates[1].file.sizeBytes)
        // 解放すると、2 つ目のモデルの大きさの半分以上が戻る
        #expect(second - released > candidates[1].file.sizeBytes / 2)
    }

    /// 生成の途中で中止できる
    @Test func cancellationStopsGeneration() async throws {
        guard let model = LocalLLMCatalog.model(id: "qwen3-1.7b"), let url = fileURL(model) else { return }
        let host = LlamaModelHost()
        let generator = try await host.generator(for: model, fileURL: url)
        let task = Task {
            try await generator.generate(.init(instructions: "You write long stories.",
                                               prompt: "Write a very long story about a cat, at least 2000 words.",
                                               greedy: false, maxTokens: 3000))
        }
        try await Task.sleep(for: .milliseconds(800))
        let clock = ContinuousClock()
        let start = clock.now
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        let took = clock.now - start
        print("中止までの時間: \(took)")
        #expect(took < .seconds(3))
        await host.release()
    }

    /// メモリの上限を超えるモデルは読み込まない
    @Test func refusesModelsOverTheMemoryBudget() async throws {
        #expect(LocalLLMCatalog.memoryBudget(physicalMemory: 32 * 1_073_741_824) > 19_000_000_000)
        #expect(LocalLLMCatalog.all.allSatisfy { LocalLLMCatalog.fitsInMemory($0, physicalMemory: 32 * 1_073_741_824) })
        let small = LocalLLMCatalog.all.filter { !LocalLLMCatalog.fitsInMemory($0, physicalMemory: 8 * 1_073_741_824) }
        #expect(small.contains { $0.id == "gpt-oss-20b" })
    }
}
