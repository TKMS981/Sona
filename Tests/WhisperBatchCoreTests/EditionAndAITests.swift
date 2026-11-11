import Foundation
import Synchronization
import Testing
@testable import WhisperBatchCore

// エディションの分離と、ランタイムに依存しない AI の処理（形式・検査・差分・モデルの選び方・処理の手順・カタログ）のテスト

@Suite("エディション")
struct EditionTests {
    @Test func airHasNoAIFeatures() {
        #expect(SonaEdition.air.features.isEmpty)
        #expect(SonaEdition.vantage.features == .all)
        for feature: SonaFeatures in [.aiCorrection, .aiPolish, .fillerRemoval, .speakerIdentification, .summary,
                                      .translation, .reviewCandidates, .aiModelManagement] {
            #expect(!SonaEdition.air.features.contains(feature))
            #expect(SonaEdition.vantage.features.contains(feature))
        }
        #expect(SonaEdition.air.productName == "Sona Air")
        #expect(SonaEdition.vantage.productName == "Sona Vantage")
    }
}

@Suite("チャットの形式")
struct ChatFormatTests {
    let date = ISO8601DateFormatter().date(from: "2026-11-11T00:00:00Z")!

    @Test func rendersTemplatesLikeTheGGUFTemplates() {
        // 各モデルの GGUF のテンプレートを描画した結果と同じ（2026-11 に jinja2 で描画して確認）
        #expect(ChatFormat.qwen3NoThinking.render(system: "SYS", user: "USER")
            == "<|im_start|>system\nSYS<|im_end|>\n<|im_start|>user\nUSER<|im_end|>\n<|im_start|>assistant\n<think>\n\n</think>\n\n")
        #expect(ChatFormat.graniteNoThinking.render(system: "SYS", user: "USER")
            == "<|im_start|>system\nSYS<|im_end|>\n<|im_start|>user\nUSER<|im_end|>\n<|im_start|>assistant\n<think></think>")
        #expect(ChatFormat.gemma4.render(system: "SYS", user: "USER")
            == "<bos><|turn>system\nSYS<turn|>\n<|turn>user\nUSER<turn|>\n<|turn>model\n")
        #expect(ChatFormat.mistral3.render(system: "SYS", user: "USER") == "<s>[SYSTEM_PROMPT]SYS[/SYSTEM_PROMPT][INST]USER[/INST]")
        #expect(ChatFormat.phi4.render(system: "SYS", user: "USER")
            == "<|im_start|>system<|im_sep|>SYS<|im_end|><|im_start|>user<|im_sep|>USER<|im_end|><|im_start|>assistant<|im_sep|>")
        let harmony = ChatFormat.harmonyLLMJP.render(system: "SYS", user: "USER", date: date)
        #expect(harmony.hasPrefix("<|start|>system<|message|>You are LLM-jp-4"))
        #expect(harmony.contains("Current date: 2026-11-11\n\nReasoning: low"))
        #expect(harmony.hasSuffix("<|start|>developer<|message|># Instructions\n\nSYS\n\n<|end|><|start|>user<|message|>USER<|end|><|start|>assistant"))
        #expect(ChatFormat.plamo(text: "こんにちは", source: "ja", target: "en")
            == "<|plamo:bos|><|plamo:tag|>dataset<|plamo:msg|>translation<|plamo:tag|>input<|plamo:key|>lang<|plamo:val|>ja<|plamo:msg|>こんにちは<|plamo:tag|>output<|plamo:key|>lang<|plamo:val|>en<|plamo:msg|>")
    }

    @Test func extractsOnlyTheAnswer() {
        #expect(ChatFormat.qwen3NoThinking.extractAnswer("<think>考え中</think>\n- 要点<|im_end|>余り") == "- 要点")
        #expect(ChatFormat.chatML.extractAnswer("<think>終わらない思考") == "")
        // LLM-jp-4.1 を本家の llama.cpp で動かすと、特別なトークンの後に空白が入る
        let raw = "<|channel|> analysis<|message|> We need bullets.<|end|><|start|> assistant<|channel|> final<|message|> - 発売日は十五日\n- 予算は三百万円"
        #expect(ChatFormat.harmonyLLMJP.extractAnswer(raw) == "- 発売日は十五日\n- 予算は三百万円")
        #expect(ChatFormat.harmonyGPTOSS.extractAnswer("<|channel|>analysis<|message|>考えの途中") == "")
        #expect(ChatFormat.plamoTranslate.extractAnswer("Hello.<|plamo:tag|>output") == "Hello.")
        #expect(ChatFormat.gemma4.extractAnswer("答え<turn|>") == "答え")
    }
}

@Suite("書き換えの検査（守る語・内容の追加）")
struct RewriteGuardTests {
    init() { TestLocalization.setUp() }

    @Test func protectedTokens() {
        let tokens = RewriteGuard.protectedTokens(in: "田中さんがiPhoneの新製品を３月１５日に三百万円で発表。Today Apple met Tim Cook in Tokyo.")
        #expect(tokens["田中"] == 1)
        #expect(tokens["iPhone"] == 1)
        #expect(tokens["3"] == 1 && tokens["15"] == 1)
        #expect(tokens["三百万"] == 1)
        #expect(tokens["Apple"] == 1)
        #expect(tokens["Tokyo"] == 1)
        // 文頭の語（大文字は文法上の理由）は守る語にしない
        #expect(tokens["Today"] == nil)
        #expect(RewriteGuard.protectedTokens(in: "ミーティングは十五日")["ミーティング"] == 1)
    }

    @Test func polishMustOnlyRemoveOrPunctuate() {
        #expect(RewriteGuard.check(original: "えー今日は晴れです", rewritten: "今日は晴れです。", task: .polish).isEmpty)
        #expect(RewriteGuard.check(original: "um so we decided", rewritten: "So we decided.", task: .polish).isEmpty)
        // 語を言い換えた・足した
        #expect(RewriteGuard.check(original: "今日は晴れです", rewritten: "本日は晴天です。", task: .polish).contains(.notSubsequence))
        #expect(RewriteGuard.check(original: "会議は金曜", rewritten: "会議は金曜と木曜", task: .polish).contains(.notSubsequence))
    }

    @Test func correctionKeepsNamesNumbersAndStaysSmall() {
        #expect(RewriteGuard.check(original: "会議の議事録を自動で作製します。", rewritten: "会議の議事録を自動で作成します。",
                                   task: .correction).isEmpty)
        // 数字・金額・日付を変えた
        #expect(RewriteGuard.check(original: "予算は300万円です", rewritten: "予算は30万円です", task: .correction)
            .contains(.changedProtected("300")))
        #expect(RewriteGuard.check(original: "発売は十五日です", rewritten: "発売は十六日です", task: .correction)
            .contains(.changedProtected("十五")))
        // 人名（敬称の前）・製品名（カタカナ）を変えた・足した
        #expect(RewriteGuard.check(original: "田中さんが来ます", rewritten: "田村さんが来ます", task: .correction)
            .contains(.changedProtected("田中")))
        #expect(RewriteGuard.check(original: "新しい製品です", rewritten: "新しいソナです", task: .correction).contains(.added("ソナ")))
        // 大きすぎる変更
        #expect(RewriteGuard.check(original: "来週の会議出また報告します", rewritten: "次回の打ち合わせで改めてご説明いたします",
                                   task: .correction).contains(.tooDifferent))
        #expect(RewriteGuard.check(original: "a", rewritten: " ", task: .correction) == [.empty])
    }
}

@Suite("差分")
struct TextDiffTests {
    @Test func characterDiffForJapanese() {
        let pieces = TextDiff.diff("会議出また報告", "会議でまた報告")
        #expect(pieces == [.init(kind: .same, text: "会議"), .init(kind: .removed, text: "出"), .init(kind: .added, text: "で"),
                           .init(kind: .same, text: "また報告")])
    }

    @Test func wordDiffForEnglish() {
        let pieces = TextDiff.diff("we decided to launch", "we decided to ship")
        #expect(pieces.contains(.init(kind: .removed, text: "launch")))
        #expect(pieces.contains(.init(kind: .added, text: "ship")))
        #expect(TextDiff.editDistance(["a", "b", "c"], ["a", "x", "c", "d"]) == 2)
    }
}

@Suite("AI のモデルの選び方")
struct AIModelSelectorTests {
    init() { TestLocalization.setUp() }

    let gb32: UInt64 = 32 * 1_073_741_824
    let unavailable: (String?) -> AIAvailability = { _ in .notEnabled }
    let available: (String?) -> AIAvailability = { _ in .available }

    private func resolve(_ task: AITask, _ lang: String?, _ prefs: AIModelPreferences = .init(), installed: Set<String>,
                         apple: ((String?) -> AIAvailability)? = nil, memory: UInt64? = nil) -> AIModelResolution {
        AIModelSelector.resolve(task: task, languageCode: lang, preferences: prefs, installed: installed,
                                appleAvailability: apple ?? unavailable, physicalMemory: memory ?? gb32)
    }

    @Test func automaticPrefersTheLanguageOfTheTranscript() {
        let installed: Set<String> = ["qwen3-4b", "llm-jp-4.1-8b", "granite-4.2-3b"]
        #expect(resolve(.summary, "ja", installed: installed) == .local(LocalLLMCatalog.model(id: "llm-jp-4.1-8b")!))
        #expect(resolve(.summary, "en", installed: installed) == .local(LocalLLMCatalog.model(id: "granite-4.2-3b")!))
        #expect(resolve(.summary, "fr", installed: installed) == .local(LocalLLMCatalog.model(id: "qwen3-4b")!))
    }

    @Test func translationPrefersTranslationModelsButOtherTasksNeverUseThem() {
        let installed: Set<String> = ["plamo-3-translate-2b", "qwen3-4b"]
        #expect(resolve(.translation, "ja", installed: installed) == .local(LocalLLMCatalog.model(id: "plamo-3-translate-2b")!))
        #expect(resolve(.correction, "ja", installed: installed) == .local(LocalLLMCatalog.model(id: "qwen3-4b")!))
        let only: Set<String> = ["plamo-3-translate-2b"]
        if case .unavailable = resolve(.summary, "ja", installed: only) {} else { Issue.record("翻訳専用のモデルを要約に使った") }
        var prefs = AIModelPreferences(mode: .perTask)
        prefs.perTask[.summary] = .model("plamo-3-translate-2b")
        #expect(resolve(.summary, "ja", prefs, installed: only)
            == .unavailable(.unsupportedTask(LocalLLMCatalog.model(id: "plamo-3-translate-2b")!)))
    }

    @Test func fallsBackToAppleIntelligenceThenGuidanceWithoutDownloading() {
        #expect(resolve(.summary, "ja", installed: [], apple: available) == .appleIntelligence)
        // Apple Intelligence は翻訳には使わない
        if case .unavailable(.noInstalledModel(let suggestions)) = resolve(.translation, "ja", installed: [], apple: available) {
            #expect(suggestions.first?.categories.contains(.translation) == true)
        } else {
            Issue.record("翻訳はローカルのモデルだけ")
        }
        guard case .unavailable(.noInstalledModel(let suggestions)) = resolve(.correction, "ja", installed: []) else {
            Issue.record("案内になっていない"); return
        }
        #expect(!suggestions.isEmpty && suggestions.count <= 3)
        #expect(suggestions.allSatisfy { !$0.isTranslationOnly })
    }

    @Test func manualCommonAndPerTask() {
        let common = AIModelPreferences(mode: .common, common: .model("gemma-4-e2b"))
        #expect(resolve(.polish, "ja", common, installed: ["gemma-4-e2b", "llm-jp-4.1-8b"])
            == .local(LocalLLMCatalog.model(id: "gemma-4-e2b")!))
        #expect(resolve(.polish, "ja", common, installed: [])
            == .unavailable(.notInstalled(LocalLLMCatalog.model(id: "gemma-4-e2b")!)))
        var perTask = AIModelPreferences(mode: .perTask)
        perTask.perTask[.correction] = .appleIntelligence
        #expect(resolve(.correction, "ja", perTask, installed: ["qwen3-4b"], apple: available) == .appleIntelligence)
        #expect(resolve(.correction, "ja", perTask, installed: ["qwen3-4b"])
            == .unavailable(.appleIntelligenceUnavailable(.notEnabled)))
        // 指定していない用途は自動
        #expect(resolve(.summary, "ja", perTask, installed: ["qwen3-4b"]) == .local(LocalLLMCatalog.model(id: "qwen3-4b")!))
    }

    @Test func tooLargeForThisMac() {
        let prefs = AIModelPreferences(mode: .common, common: .model("gpt-oss-20b"))
        #expect(resolve(.summary, "en", prefs, installed: ["gpt-oss-20b"], memory: 8 * 1_073_741_824)
            == .unavailable(.tooLarge(LocalLLMCatalog.model(id: "gpt-oss-20b")!)))
        #expect(!AIModelSelector.ranked(for: .summary, languageCode: "en", physicalMemory: 8 * 1_073_741_824)
            .contains { $0.id == "gpt-oss-20b" })
    }

    @Test func choiceStorage() {
        for choice: AIModelChoice in [.automatic, .appleIntelligence, .model("qwen3-4b")] {
            #expect(AIModelChoice(storageValue: choice.storageValue) == choice)
        }
        #expect(AIModelChoice(storageValue: "model:unknown") == nil)
        #expect(AIModelChoice(storageValue: "x") == nil)
    }
}

/// テスト用の生成器（依頼を記録し、決めた返答を返す）
final class FakeGenerator: TextGenerator, Sendable {
    let displayName = "Fake"
    let maxInputCharacters: Int
    let isTranslationOnly = false
    private let log = Mutex<[GenerationRequest]>([])
    var requests: [GenerationRequest] { log.withLock { $0 } }
    let respond: @Sendable (GenerationRequest) -> String

    init(maxInputCharacters: Int = 2_000, respond: @escaping @Sendable (GenerationRequest) -> String) {
        self.maxInputCharacters = maxInputCharacters
        self.respond = respond
    }

    func generate(_ request: GenerationRequest) async throws -> String {
        log.withLock { $0.append(request) }
        return respond(request)
    }
}

@Suite("AI の処理の手順（偽の生成器）")
struct AITaskRunnerTests {
    init() { TestLocalization.setUp() }

    let transcript = Transcript(segments: (0 ..< 30).map {
        TranscriptSegment(start: Double($0) * 5, end: Double($0) * 5 + 4, text: "これは \($0) 番目の発言で、予算は300万円です。")
    }, language: "ja")

    private var lines: [LocalAIText.Line] { LocalAIText.lines(original: transcript, edits: TranscriptEdits(), speakerNames: [:]) }

    @Test func longTranscriptsAreSplitThenCombined() async throws {
        let generator = FakeGenerator(maxInputCharacters: 400) { _ in "- 要点" }
        let summary = try await AITaskRunner.summarize(lines, generator: generator, languageCode: "ja")
        #expect(summary == ["要点"])
        // 区切った数＋まとめの 1 回
        let chunks = LocalAIText.chunks(lines, limit: 400).count
        #expect(chunks > 1)
        #expect(generator.requests.count == chunks + 1)
        #expect(generator.requests.dropLast().allSatisfy { $0.prompt.count < 400 + 200 })
    }

    @Test func keyPointsUseTranscriptTextOnly() async throws {
        let generator = FakeGenerator { _ in "#3: 決定\n#999: 依頼\n#1: 数値" }
        let points = try await AITaskRunner.keyPoints(Array(lines.prefix(5)), segments: transcript.segments, generator: generator,
                                                      languageCode: "ja")
        #expect(points.map(\.text) == [transcript.segments[0].text, transcript.segments[2].text])
        #expect(points[1].reasons == [.decision])
    }

    @Test func rewritesThatBreakTheRulesAreRejected() async throws {
        let generator = FakeGenerator { _ in
            "#1: これは 0 番目の発言で、予算は300万円です\n#2: これは 1 番目の発言で、予算は30万円です。\n#3: まったく別の文になりました"
        }
        let outcome = try await AITaskRunner.rewrite(.polish, lines: Array(lines.prefix(3)), generator: generator, languageCode: "ja")
        #expect(outcome.candidates.map(\.index) == [0])
        #expect(outcome.rejected.map(\.index) == [1, 2])
        #expect(outcome.rejected[0].violations.contains(.changedProtected("300")))
        // 誤認識の修正には、確からしさが低い語を渡す
        let correction = FakeGenerator { _ in "" }
        _ = try await AITaskRunner.rewrite(.correction, lines: Array(lines.prefix(2)), suspicious: [1: ["番目"]],
                                           generator: correction, languageCode: "ja")
        #expect(correction.requests.first?.prompt.contains("確からしさが低い語: 番目") == true)
        #expect(correction.requests.first?.instructions.contains("人名・地名・製品名・数字・日付・金額") == true)
    }

    @Test func suggestionMustPassTheChecks() async throws {
        let ok = FakeGenerator { _ in "会議の議事録を自動で作成します。" }
        #expect(try await AITaskRunner.suggestCorrection(target: "会議の議事録を自動で作製します。", before: [], after: [],
                                                         suspicious: [], generator: ok, languageCode: "ja")
            == "会議の議事録を自動で作成します。")
        let bad = FakeGenerator { _ in "会議の議事録を3日で作成します。" }
        #expect(try await AITaskRunner.suggestCorrection(target: "会議の議事録を自動で作製します。", before: [], after: [],
                                                         suspicious: [], generator: bad, languageCode: "ja") == nil)
    }

    @Test func translationKeepsTheTranscriptAndCleansNumbers() async throws {
        let generator = FakeGenerator { _ in "#1 This is the translation." }
        let result = try await AITaskRunner.translate(Array(lines.prefix(2)), generator: generator, source: "ja", target: "en")
        #expect(result == ["This is the translation."])
        #expect(generator.requests.first?.instructions.contains("English") == true)
    }

    @Test func cancellationStopsBetweenChunks() async throws {
        let generator = FakeGenerator(maxInputCharacters: 400) { _ in "- 要点" }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await AITaskRunner.summarize(lines, generator: generator, languageCode: "ja")
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}

@Suite("ローカルの言語モデルのカタログ")
struct LocalLLMCatalogTests {
    init() { TestLocalization.setUp() }

    @Test func entriesArePinnedAndConsistent() {
        let all = LocalLLMCatalog.all
        #expect(all.count >= 10)
        #expect(Set(all.map(\.id)).count == all.count)
        for m in all {
            #expect(m.revision.count == 40 && m.revision.allSatisfy(\.isHexDigit), "\(m.id)")
            #expect(m.file.sha256.count == 64 && m.file.sha256.allSatisfy(\.isHexDigit), "\(m.id)")
            #expect(m.file.name.hasSuffix(".gguf"))
            #expect(m.file.sizeBytes > 100_000_000)
            #expect(!m.tasks.isEmpty)
            #expect(!m.license.name.isEmpty)
            let url = m.downloadModel.files[0].url
            #expect(url.scheme == "https" && url.host() == "huggingface.co")
            #expect(url.path.contains("/resolve/\(m.revision)/"))
            #expect(m.downloadModel.purpose == .textGeneration)
            #expect(m.downloadModel.folder == "llm/\(m.id)")
            #expect(m.downloadModel.displayName == m.displayName)
            if m.isTranslationOnly { #expect(m.tasks == [.translation]) }
            #expect(LocalLLMCatalog.fitsInMemory(m, physicalMemory: 32 * 1_073_741_824))
        }
        // 用途のカテゴリがそろっている
        for c in [LLMCategory.japanese, .english, .multilingual, .translation, .lightweight, .highQuality] {
            #expect(all.contains { $0.categories.contains(c) }, "\(c)")
        }
        #expect(LocalLLMCatalog.model(downloadID: "llm-qwen3-4b")?.id == "qwen3-4b")
    }
}

@Suite("AI の設定の保存と書き出し")
@MainActor
struct AISettingsTests {
    init() { TestLocalization.setUp() }

    private func store() -> SettingsStore {
        let name = "AISettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return SettingsStore(defaults: defaults)
    }

    @Test func persistsAndTransfers() throws {
        let a = store()
        #expect(a.aiSelectionMode == .automatic && a.aiRewriteMode == .review && a.aiCommonChoice == .automatic)
        a.aiSelectionMode = .perTask
        a.aiTaskChoices = [.correction: .model("qwen3-8b"), .translation: .model("plamo-3-translate-2b")]
        a.aiCommonChoice = .appleIntelligence
        a.aiRewriteMode = .automatic
        let b = store()
        let report = b.apply(try SettingsSnapshot.decode(try a.makeSnapshot(appearance: nil).encoded()))
        #expect(report.skipped.isEmpty)
        #expect(b.aiSelectionMode == .perTask && b.aiRewriteMode == .automatic && b.aiCommonChoice == .appleIntelligence)
        #expect(b.aiTaskChoices == a.aiTaskChoices)
        #expect(b.aiPreferences.choice(for: .correction) == .model("qwen3-8b"))
    }

    @Test func invalidChoicesAreSkipped() throws {
        let json = #"{"format":"Sona.settings","version":1,"ai":{"selectionMode":"x","taskChoices":{"summary":"model:nope"},"rewriteMode":"automatic"}}"#
        let s = store()
        let report = s.apply(try SettingsSnapshot.decode(Data(json.utf8)))
        #expect(Set(report.skipped) == ["ai.selectionMode", "ai.taskChoices"])
        #expect(s.aiRewriteMode == .automatic)
    }
}

@Suite("エディションの依存関係（ソース）")
struct EditionDependencyTests {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private func sources(_ target: String) throws -> [(String, String)] {
        let dir = Self.root.appendingPathComponent("Sources/\(target)")
        let files = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)!
        var result: [(String, String)] = []
        while let url = files.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            result.append((url.lastPathComponent, try String(contentsOf: url, encoding: .utf8)))
        }
        return result
    }

    @Test func aiRuntimesAreOnlyInVantageTargets() throws {
        for target in ["WhisperBatchCore", "WhisperBatchEngine", "WhisperBatch", "SonaAir"] {
            for (name, text) in try sources(target) {
                #expect(!text.contains("import FoundationModels"), "\(target)/\(name)")
                #expect(!text.contains("import llama"), "\(target)/\(name)")
                #expect(!text.contains("import SonaLLM") && !text.contains("import SonaVantageAI"), "\(target)/\(name)")
            }
        }
        // Air の起動は AI の実装を渡さない
        let air = try sources("SonaAir").map(\.1).joined()
        #expect(air.contains("configure(edition: .air, ai: nil)"))
    }

    @Test func privateCloudComputeIsNeverUsed() throws {
        for target in ["WhisperBatchCore", "WhisperBatchEngine", "WhisperBatch", "SonaLLM", "SonaVantageAI", "SonaAir", "SonaVantage"] {
            for (name, text) in try sources(target) {
                #expect(!text.contains("PrivateCloudComputeLanguageModel("), "\(target)/\(name)")
                #expect(!text.contains("PrivateCloudComputeLanguageModel."), "\(target)/\(name)")
            }
        }
    }

    @Test func packageKeepsAirFreeOfAI() throws {
        let manifest = try String(contentsOf: Self.root.appendingPathComponent("Package.swift"), encoding: .utf8)
        #expect(manifest.contains(#".executableTarget(name: "SonaAir", dependencies: ["WhisperBatch"])"#))
        #expect(manifest.contains(#".executable(name: "Sona", targets: ["SonaVantage"])"#))
        // 既存のモジュール名を保つ
        for name in ["WhisperBatchCore", "WhisperBatchEngine", "WhisperBatch"] {
            #expect(manifest.contains(#".target(name: "\#(name)""#) || manifest.contains(#"name: "\#(name)","#))
        }
    }
}
