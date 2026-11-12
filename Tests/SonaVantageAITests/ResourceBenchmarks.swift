import Darwin
import Foundation
import Testing
import WhisperBatchCore
import WhisperBatchEngine
@testable import SonaVantageAI

// ローカルの言語モデルの負荷の計測（最適化の前後比較用）。次の環境変数を設定したときだけ実行する。
//   WHISPER_BATCH_TEST_BENCH_OUT : 結果を追記するファイル（出力した文章は <名前>.outputs に書く）
//   WHISPER_BATCH_TEST_LLM_DIR   : カタログのファイル名の GGUF を置いたフォルダ
//   WHISPER_BATCH_TEST_BENCH_LLM : 計測するモデルの id（カンマ区切り。既定 tinyswallow-1.5b,qwen3-4b）
// 画面と同じく VantageAIRuntime から生成器を受け取り、同じ依頼を 2 回ずつ行う（2 回目は画面の「再実行」に当たる）。

private let env = ProcessInfo.processInfo.environment
private let benchOut = env["WHISPER_BATCH_TEST_BENCH_OUT"].map { URL(fileURLWithPath: $0) }
private let llmDir = env["WHISPER_BATCH_TEST_LLM_DIR"].map { URL(fileURLWithPath: $0) }
private let benchModels = (env["WHISPER_BATCH_TEST_BENCH_LLM"] ?? "tinyswallow-1.5b,qwen3-4b").split(separator: ",").map(String.init)

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

/// このプロセスが使っているメモリ（phys_footprint。Metal に置いたモデルも含む）
private func footprintMB() -> Int {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
    }
    return result == KERN_SUCCESS ? Int(info.phys_footprint / 1_048_576) : 0
}

private func seconds(_ d: Duration) -> String {
    String(format: "%.3f", Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18)
}

/// 会議の文字起こし（合成）。要約が 2 つのまとまりに分かれる長さにする。
private let meeting: Transcript = {
    let base = [
        "えー、本日は新製品の発売日について話し合います。",
        "発売日は来月の十五日に決定しました。",
        "資料は田中さんが金曜日までに用意してください。",
        "広告の予算は三百万円を予定しています",
        "在庫の不足が課題として残っています",
        "札幌の店舗は雪の影響で客足が落ちています。",
        "エンジニアを三名、デザイナーを一名募集しています",
        "面接はオンラインと対面の両方で行います。",
        "月曜日は全体会議、水曜日は顧客訪問、金曜日は振り返りです。",
        "以上で会議を終わります。お疲れ様でした。",
    ]
    var segments: [TranscriptSegment] = []
    for round in 0 ..< 8 {
        for (i, text) in base.enumerated() {
            let t = Double(segments.count) * 4
            segments.append(.init(start: t, end: t + 4, text: round == 0 ? text : "（第\(round + 1)部）" + text, speaker: i % 2))
        }
    }
    return Transcript(segments: segments, language: "ja")
}()

@Suite("負荷の計測（ローカルの言語モデル）", .enabled(if: benchOut != nil && llmDir != nil), .serialized)
struct LLMResourceBenchmarks {
    init() { TestLocalization.setUp() }

    @Test(arguments: benchModels)
    func loadRunRelease(id: String) async throws {
        let model = try #require(LocalLLMCatalog.model(id: id))
        let source = llmDir!.appendingPathComponent(model.file.name)
        try #require(FileManager.default.fileExists(atPath: source.path))
        // 取得済みのモデルとして置く（ハードリンク。元のファイルは変えない）
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sona-bench-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let storage = ModelStorage(directory: dir)
        let download = model.downloadModel
        let dest = storage.fileURL(for: download.files[0], of: download)
        try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.linkItem(at: source, to: dest)
        try await storage.verifyContents(of: download) // 照合（SHA-256）は計測に含めない

        let runtime = VantageAIRuntime()
        let clock = ContinuousClock()
        let lines = LocalAIText.lines(original: meeting, edits: TranscriptEdits(), speakerNames: [:])
        let memBefore = footprintMB()

        // 生成器はまとまりごとに受け取り、使い終わったら手放す（画面と同じ。手放すまでモデルは使用中）
        var start = clock.now
        var load = Duration.zero
        var memLoaded = 0
        do {
            _ = try await runtime.textGenerator(for: .local(model), storage: storage)
            load = clock.now - start
            memLoaded = footprintMB()
        }

        var results: [String: [String]] = [:]
        var times: [String: [String]] = [:]
        for _ in 1 ... 2 {
            // 画面と同じく、処理のたびに生成器を受け取り直す
            let generator = try await runtime.textGenerator(for: .local(model), storage: storage)
            start = clock.now
            let summary = try await AITaskRunner.summarize(lines, generator: generator, languageCode: "ja")
            times["summary", default: []].append(seconds(clock.now - start))
            results["summary", default: []].append(summary.joined(separator: "\n"))

            start = clock.now
            let points = try await AITaskRunner.keyPoints(lines, segments: meeting.segments, generator: generator, languageCode: "ja")
            times["keyPoints", default: []].append(seconds(clock.now - start))
            results["keyPoints", default: []].append(points.map(\.text).joined(separator: "\n"))

            start = clock.now
            let polish = try await AITaskRunner.rewrite(.polish, lines: Array(lines.prefix(10)), generator: generator, languageCode: "ja")
            times["polish", default: []].append(seconds(clock.now - start))
            results["polish", default: []].append(polish.candidates.map { "\($0.index): \($0.rewritten)" }.joined(separator: "\n"))
        }
        let memAfterRuns = footprintMB()

        await runtime.releaseTextModel()
        try await Task.sleep(for: .milliseconds(300))
        let memReleased = footprintMB()
        let loadedAfterRelease = await runtime.loadedTextModelID() != nil

        // 解放した後に同じ依頼をもう一度（読み込み直し）
        var reload = Duration.zero
        var polish3Time = Duration.zero
        var polish3: RewriteOutcome?
        do {
            start = clock.now
            let generator = try await runtime.textGenerator(for: .local(model), storage: storage)
            reload = clock.now - start
            start = clock.now
            polish3 = try await AITaskRunner.rewrite(.polish, lines: Array(lines.prefix(10)), generator: generator, languageCode: "ja")
            polish3Time = clock.now - start
        }
        await runtime.releaseTextModel()

        for key in ["summary", "keyPoints", "polish"] {
            let r = results[key]!
            recordOutput("\(id) \(key) run1", r[0])
            recordOutput("\(id) \(key) run2", r[1])
        }
        recordOutput("\(id) polish afterReload", (polish3?.candidates ?? []).map { "\($0.index): \($0.rewritten)" }.joined(separator: "\n"))
        let same = ["summary", "keyPoints", "polish"].map { "\($0)Same=\(results[$0]![0] == results[$0]![1])" }.joined(separator: "\t")
        record("llm\t\(id)\tloadSeconds=\(seconds(load))\tmemBeforeMB=\(memBefore)\tmemLoadedMB=\(memLoaded)\tmemAfterRunsMB=\(memAfterRuns)\tmemReleasedMB=\(memReleased)"
            + "\tsummary=\(times["summary"]!.joined(separator: "/"))\tkeyPoints=\(times["keyPoints"]!.joined(separator: "/"))"
            + "\tpolish=\(times["polish"]!.joined(separator: "/"))\treloadSeconds=\(seconds(reload))\tpolishAfterReload=\(seconds(polish3Time))\t\(same)"
            + "\tloadedAfterRelease=\(loadedAfterRelease)")
    }
}
