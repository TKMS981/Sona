import Foundation
import Testing
import WhisperBatchCore
import WhisperBatchEngine
@testable import SonaLLM
@testable import SonaVantageAI

// ローカルの言語モデルの読み込み・解放と、結果の再利用（実モデル）。WHISPER_BATCH_TEST_LLM_DIR を設定したときだけ実行する。
// TinySwallow 1.5B と Qwen3 1.7B（カタログのファイル名）を使う。

private let llmDir = ProcessInfo.processInfo.environment["WHISPER_BATCH_TEST_LLM_DIR"].map { URL(fileURLWithPath: $0) }
private let small = LocalLLMCatalog.model(id: "tinyswallow-1.5b")!
private let other = LocalLLMCatalog.model(id: "qwen3-1.7b")!

private func url(_ model: LocalLLM) -> URL? {
    guard let llmDir else { return nil }
    let url = llmDir.appendingPathComponent(model.file.name)
    return FileManager.default.fileExists(atPath: url.path) ? url : nil
}

private let available = url(small) != nil && url(other) != nil

private let longRequest = GenerationRequest(instructions: "You write long stories.",
                                            prompt: "Write a very long story about a cat, at least 2000 words.",
                                            greedy: false, maxTokens: 3000)
private let shortRequest = GenerationRequest(instructions: "あなたは日本語で短く答えます。", prompt: "日本の首都はどこですか。一言で答えてください。",
                                             greedy: true, maxTokens: 32)

/// 条件が満たされるまで待つ（最大 `timeout`）
private func eventually(_ timeout: Duration = .seconds(5), _ condition: () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(50))
    }
    return await condition()
}

@Suite("ローカルの言語モデルの保持と解放（実モデル）", .enabled(if: available), .serialized)
struct ModelLifecycleTests {
    init() { TestLocalization.setUp() }

    /// 使用中に解放を頼んでも解放しない（処理は最後まで終わる）。手放したら解放する。
    @Test func releaseWaitsUntilTheGeneratorIsDropped() async throws {
        let host = LlamaModelHost(idleTimeout: nil)
        do {
            let generator = try await host.generator(for: small, fileURL: url(small)!)
            await host.release()
            #expect(await host.loadedModelID == small.id)
            let answer = try await generator.generate(shortRequest)
            #expect(!answer.isEmpty)
            #expect(await host.activeUseCount == 1)
        }
        #expect(await eventually { await host.loadedModelID == nil })
        #expect(await host.activeUseCount == 0)
    }

    /// 使い終わってから一定の時間使われなければ解放する。使用中は時間が過ぎても解放しない。
    @Test func idleTimeoutReleasesOnlyUnusedModels() async throws {
        let host = LlamaModelHost(idleTimeout: .milliseconds(300))
        do {
            let generator = try await host.generator(for: small, fileURL: url(small)!)
            try await Task.sleep(for: .milliseconds(800))
            #expect(await host.loadedModelID == small.id)
            _ = try await generator.generate(shortRequest)
        }
        #expect(await eventually { await host.loadedModelID == nil })
        // もう一度使うと読み込み直す（同じ設定で）
        let again = try await host.generator(for: small, fileURL: url(small)!)
        #expect(await host.loadedModelID == small.id)
        _ = again
        await host.shutdown()
    }

    /// 別のモデルへの切り替えは、使用中のモデルの処理が終わるまで待つ（途中で解放して処理を壊さない。2 つを同時に置かない）
    @Test func switchingWaitsForTheModelInUse() async throws {
        let host = LlamaModelHost(idleTimeout: nil)
        let job: Task<String, any Error>
        do {
            let first = try await host.generator(for: small, fileURL: url(small)!)
            job = Task { try await first.generate(GenerationRequest(instructions: "Answer briefly.", prompt: "Count from 1 to 40.",
                                                                    greedy: true, maxTokens: 160)) }
        }
        let switching = Task { () -> String? in
            _ = try await host.generator(for: other, fileURL: url(other)!)
            return await host.loadedModelID
        }
        try await Task.sleep(for: .milliseconds(200))
        #expect(await host.loadedModelID == small.id) // まだ切り替えない
        let text = try await job.value // 前のモデルの処理は中止されずに終わる
        #expect(!text.isEmpty)
        #expect(try await switching.value == other.id)
        await host.shutdown()
    }

    /// 切り替えを待っている間に中止できる（使用中のモデルはそのまま）
    @Test func waitingForSwitchCanBeCancelled() async throws {
        let host = LlamaModelHost(idleTimeout: nil)
        let first = try await host.generator(for: small, fileURL: url(small)!)
        let switching = Task { _ = try await host.generator(for: other, fileURL: url(other)!) }
        try await Task.sleep(for: .milliseconds(200))
        switching.cancel()
        await #expect(throws: CancellationError.self) { try await switching.value }
        #expect(await host.loadedModelID == small.id)
        _ = try await first.generate(shortRequest)
        await host.shutdown()
    }

    /// アプリの終了時は、実行中の推論を打ち切ってすぐに解放する
    @Test func shutdownAbortsRunningGeneration() async throws {
        let host = LlamaModelHost(idleTimeout: nil)
        let generator = try await host.generator(for: small, fileURL: url(small)!)
        let job = Task { try await generator.generate(longRequest) }
        try await Task.sleep(for: .milliseconds(500))
        let start = ContinuousClock.now
        await host.shutdown()
        await #expect(throws: CancellationError.self) { try await job.value }
        #expect(ContinuousClock.now - start < .seconds(3))
        #expect(await host.loadedModelID == nil)
    }
}

@Suite("AI の結果の再利用（実モデル）", .enabled(if: available), .serialized)
struct RuntimeCacheTests {
    init() { TestLocalization.setUp() }

    private func storage() throws -> (ModelStorage, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sona-cache-test-\(UUID().uuidString)")
        let storage = ModelStorage(directory: dir)
        for model in [small, other] {
            let download = model.downloadModel
            let dest = storage.fileURL(for: download.files[0], of: download)
            try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.linkItem(at: url(model)!, to: dest)
        }
        return (storage, dir)
    }

    @Test func sameInputSameModelReusesAndOtherwiseRecomputes() async throws {
        let (storage, dir) = try storage()
        defer { try? FileManager.default.removeItem(at: dir) }
        let runtime = VantageAIRuntime(idleTimeout: nil)
        func makeLines(_ suffix: String) -> [LocalAIText.Line] {
            LocalAIText.lines(original: Transcript(segments: [
                .init(start: 0, end: 3, text: "えー、本日は新製品の発売日について話し合います" + suffix),
                .init(start: 3, end: 6, text: "発売日は来月の十五日に決定しました" + suffix),
            ], language: "ja"), edits: TranscriptEdits(), speakerNames: [:])
        }
        let lines = makeLines("")

        func polish(_ model: LocalLLM, scope: String) async throws -> RewriteOutcome {
            let generator = try await runtime.textGenerator(for: .local(model), storage: storage, cacheScope: scope)
            return try await AITaskRunner.rewrite(.polish, lines: lines, generator: generator, languageCode: "ja")
        }

        let first = try await polish(small, scope: "item-1")
        #expect(await runtime.cache.hits == 0)
        // 同じ入力・同じモデル・同じ設定 → 再利用（同じ結果）
        let clock = ContinuousClock()
        let start = clock.now
        let second = try await polish(small, scope: "item-1")
        #expect(clock.now - start < .milliseconds(500))
        #expect(second == first)
        #expect(await runtime.cache.hits >= 1)
        let hitsAfterReuse = await runtime.cache.hits

        // モデルを解放しても、同じ条件なら再利用する（読み込み直さない）
        await runtime.releaseTextModel()
        #expect(await eventually { await runtime.loadedTextModelID() == nil })

        // 入力が違う → 処理し直す
        let edited = makeLines("。")
        do {
            let generator = try await runtime.textGenerator(for: .local(small), storage: storage, cacheScope: "item-1")
            _ = try await AITaskRunner.rewrite(.polish, lines: edited, generator: generator, languageCode: "ja")
        }
        #expect(await runtime.cache.hits == hitsAfterReuse)

        // モデルが違う → 処理し直す（前のモデルの結果を使わない）
        _ = try await polish(other, scope: "item-1")
        #expect(await runtime.cache.hits == hitsAfterReuse)

        // 編集で対象の結果を消した → 処理し直す。決まった手順なので結果は同じ
        await runtime.invalidateCachedResults(scope: "item-1")
        let recomputed = try await polish(small, scope: "item-1")
        #expect(await runtime.cache.hits == hitsAfterReuse)
        #expect(recomputed == first)
        await runtime.shutdownTextModel()
    }
}
