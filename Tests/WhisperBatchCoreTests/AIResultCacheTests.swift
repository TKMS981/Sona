import Foundation
import Synchronization
import Testing
@testable import WhisperBatchCore

/// 呼ばれた回数を数え、依頼文をそのまま返す生成器（待たせる・失敗させることもできる）
private final class CountingGenerator: TextGenerator, Sendable {
    let displayName = "Counting"
    let maxInputCharacters = 2_000
    private let calls = Mutex(0)
    var callCount: Int { calls.withLock { $0 } }
    let delay: Duration
    let failure: (any Error & Sendable)?

    init(delay: Duration = .zero, failure: (any Error & Sendable)? = nil) {
        self.delay = delay
        self.failure = failure
    }

    func generate(_ request: GenerationRequest) async throws -> String {
        calls.withLock { $0 += 1 }
        if delay > .zero { try await Task.sleep(for: delay) }
        if let failure { throw failure }
        return "out:" + request.prompt
    }

    func translate(_ text: String, from source: String?, to target: String) async throws -> String {
        calls.withLock { $0 += 1 }
        return "\(target):" + text
    }
}

private struct Boom: Error {}

private let model = AIResultCacheKey.Model(id: "qwen3-4b", revision: "rev1", fileSHA256: "sha-a", format: "chatML",
                                           contextTokens: 8192, inferenceSettings: "llama.cpp b11976;seed=1234")
private let request = GenerationRequest(instructions: "要約してください", prompt: "#1 [00:00] 本日は会議です", greedy: true, maxTokens: 512)

@Suite("AI の結果の再利用")
struct AIResultCacheTests {
    @Test func reusesOnlyExactlyTheSameRequest() async throws {
        let cache = AIResultCache()
        let base = CountingGenerator()
        let generator = CachingTextGenerator(base: base, cache: cache, model: model, scope: "item-1")
        let first = try await generator.generate(request)
        let second = try await generator.generate(request)
        #expect(first == second)
        #expect(base.callCount == 1)
        #expect(await cache.hits == 1)
    }

    /// 入力・モデル・処理の種類・推論の設定のどれか 1 つでも違えば、もう一度処理する
    @Test func anyDifferenceMakesADifferentKey() {
        let base = AIResultCacheKey.generate(request, model: model)
        var variants: [AIResultCacheKey] = []
        var r = request
        r.prompt += "。"; variants.append(.generate(r, model: model))
        r = request; r.instructions += " "; variants.append(.generate(r, model: model))
        r = request; r.greedy = false; variants.append(.generate(r, model: model))
        r = request; r.maxTokens = 513; variants.append(.generate(r, model: model))
        var m = model; m.id = "qwen3-8b"; variants.append(.generate(request, model: m))
        m = model; m.revision = "rev2"; variants.append(.generate(request, model: m))
        m = model; m.fileSHA256 = "sha-b"; variants.append(.generate(request, model: m))
        m = model; m.format = "gemma"; variants.append(.generate(request, model: m))
        m = model; m.contextTokens = 4096; variants.append(.generate(request, model: m))
        m = model; m.inferenceSettings += ";threads=4"; variants.append(.generate(request, model: m))
        // 翻訳は生成と別の処理として扱い、言語が違えば別のキー
        variants.append(.translate(request.prompt, source: "ja", target: "en", model: model))
        variants.append(.translate(request.prompt, source: "ja", target: "fr", model: model))
        variants.append(.translate(request.prompt, source: nil, target: "en", model: model))
        #expect(Set(variants.map(\.digest)).count == variants.count)
        #expect(!variants.contains { $0.digest == base.digest })
        // 同じ条件なら同じキー
        #expect(AIResultCacheKey.generate(request, model: model) == base)
    }

    /// 区切り文字を含む文を並べ替えても、別の条件と同じキーにならない
    @Test func fieldBoundariesAreUnambiguous() {
        let a = GenerationRequest(instructions: "ab", prompt: "c")
        let b = GenerationRequest(instructions: "a", prompt: "bc")
        #expect(AIResultCacheKey.generate(a, model: model) != AIResultCacheKey.generate(b, model: model))
    }

    @Test func invalidationByScopeAndModel() async throws {
        let cache = AIResultCache()
        let base = CountingGenerator()
        let item1 = CachingTextGenerator(base: base, cache: cache, model: model, scope: "item-1")
        let item2 = CachingTextGenerator(base: base, cache: cache, model: model, scope: "item-2")
        var other = model
        other.id = "gemma-4-e2b"
        let otherModel = CachingTextGenerator(base: base, cache: cache, model: other, scope: "item-2")
        _ = try await item1.generate(request)
        _ = try await item2.generate(GenerationRequest(instructions: "x", prompt: "y"))
        _ = try await otherModel.generate(GenerationRequest(instructions: "x", prompt: "y"))
        #expect(await cache.count == 3)

        // 項目 1 を編集・削除した → 項目 1 の結果だけ消える
        await cache.invalidate(scope: "item-1")
        #expect(await cache.count == 2)
        _ = try await item1.generate(request)
        #expect(base.callCount == 4)

        // モデルを削除・更新した → そのモデルの結果だけ消える
        await cache.invalidate(modelID: other.id)
        #expect(await cache.count == 2)
        _ = try await otherModel.generate(GenerationRequest(instructions: "x", prompt: "y"))
        #expect(base.callCount == 5)
    }

    /// 同じ結果を 2 つの対象で使ったら、どちらを消しても消える（もう一方の編集で古い結果が残らない）
    @Test func sharedResultBelongsToBothScopes() async throws {
        let cache = AIResultCache()
        let base = CountingGenerator()
        _ = try await CachingTextGenerator(base: base, cache: cache, model: model, scope: "a").generate(request)
        _ = try await CachingTextGenerator(base: base, cache: cache, model: model, scope: "b").generate(request)
        #expect(base.callCount == 1)
        await cache.invalidate(scope: "b")
        #expect(await cache.count == 0)
    }

    @Test func cancelledOrFailedRequestsAreNotStored() async throws {
        let cache = AIResultCache()
        let slow = CachingTextGenerator(base: CountingGenerator(delay: .seconds(10)), cache: cache, model: model, scope: nil)
        let task = Task { try await slow.generate(request) }
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await cache.count == 0)

        let failing = CachingTextGenerator(base: CountingGenerator(failure: Boom()), cache: cache, model: model, scope: nil)
        await #expect(throws: Boom.self) { try await failing.generate(request) }
        #expect(await cache.count == 0)
    }

    @Test func translationIsCachedSeparately() async throws {
        let cache = AIResultCache()
        let base = CountingGenerator()
        let generator = CachingTextGenerator(base: base, cache: cache, model: model, scope: "live")
        #expect(try await generator.translate("こんにちは", from: "ja", to: "en") == "en:こんにちは")
        #expect(try await generator.translate("こんにちは", from: "ja", to: "en") == "en:こんにちは")
        #expect(try await generator.translate("こんにちは", from: "ja", to: "fr") == "fr:こんにちは")
        #expect(base.callCount == 2)
    }

    @Test func limitsEvictLeastRecentlyUsed() async {
        let cache = AIResultCache(limits: .init(maxEntries: 2, maxBytes: 1_000_000))
        let keys = (0 ..< 3).map { AIResultCacheKey.generate(GenerationRequest(instructions: "i", prompt: "p\($0)"), model: model) }
        await cache.store("0", for: keys[0], scope: nil)
        await cache.store("1", for: keys[1], scope: nil)
        _ = await cache.value(for: keys[0]) // 0 を使った → 1 が最も古い
        await cache.store("2", for: keys[2], scope: nil)
        #expect(await cache.value(for: keys[0]) == "0")
        #expect(await cache.value(for: keys[1]) == nil)
        #expect(await cache.value(for: keys[2]) == "2")

        // 大きさの上限を超える結果は入れない・合計が上限を超えたら古いものから消す
        let small = AIResultCache(limits: .init(maxEntries: 10, maxBytes: 200))
        await small.store(String(repeating: "x", count: 500), for: keys[0], scope: nil)
        #expect(await small.count == 0)
        await small.store(String(repeating: "a", count: 60), for: keys[0], scope: nil)
        await small.store(String(repeating: "b", count: 60), for: keys[1], scope: nil)
        #expect(await small.count == 1)
        #expect(await small.value(for: keys[1]) != nil)
    }
}

@Suite("進捗の通知の間引き")
struct ProgressGateTests {
    @Test func passesFirstMeaningfulStepsAndCompletion() {
        let gate = ProgressGate(step: 0.01)
        #expect(gate.pass(0))
        #expect(!gate.pass(0.005))
        #expect(gate.pass(0.01))
        #expect(!gate.pass(0.009)) // 戻る値は通さない
        #expect(!gate.pass(0.0195))
        #expect(gate.pass(0.02))
        #expect(gate.pass(1)) // 完了は必ず通す
        #expect(!gate.pass(1))
    }

    @Test func limitsTheNumberOfUpdates() {
        let gate = ProgressGate()
        var passed = 0
        for i in 0 ... 100_000 where gate.pass(Double(i) / 100_000) { passed += 1 }
        #expect(passed <= Int(1 / ProgressGate.defaultStep) + 2)
        #expect(passed >= Int(1 / ProgressGate.defaultStep) - 1)
    }
}
