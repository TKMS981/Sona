import Foundation

/// AI が作った書き換えの候補（区間 1 つ分）
public struct RewriteCandidate: Equatable, Sendable, Identifiable {
    /// 元の区間の番号（`Transcript.segments` の添字）
    public var index: Int
    /// 書き換える前の文（編集を反映した今の文）
    public var original: String
    public var rewritten: String
    public var id: Int { index }

    public init(index: Int, original: String, rewritten: String) {
        self.index = index
        self.original = original
        self.rewritten = rewritten
    }

    public var diff: [TextDiff.Piece] { TextDiff.diff(original, rewritten) }
}

/// 検査で使わなかった書き換え（原文のまま残した）
public struct RejectedRewrite: Equatable, Sendable {
    public var index: Int
    public var rewritten: String
    public var violations: [RewriteGuard.Violation]
}

public struct RewriteOutcome: Equatable, Sendable {
    public var candidates: [RewriteCandidate]
    public var rejected: [RejectedRewrite]
}

/// AI の処理の手順（分割・依頼・返答の読み取り・検査）。生成そのものは `TextGenerator` が行うので、
/// ローカルの言語モデルでも Apple Intelligence でも同じ手順を使う。
///
/// - 長い文字起こしは、生成器の文脈の長さに合わせて区切って順に渡す（一度に 1 つずつ。並行しない）。
/// - 重要な発言は番号を選ばせ、文は文字起こしのものをそのまま使う。
/// - 誤認識の修正と文章の整形は別の処理。どちらも `RewriteGuard` を通らない候補は使わない。
public enum AITaskRunner {
    static func chunkLimit(_ generator: any TextGenerator) -> Int {
        max(400, min(LocalAIText.chunkCharacters, generator.maxInputCharacters))
    }

    // MARK: 要約

    public static func summarize(_ lines: [LocalAIText.Line], generator: any TextGenerator, languageCode: String?,
                                 progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> [String] {
        let language = LocalAIText.OutputLanguage(code: languageCode)
        let limit = chunkLimit(generator)
        let chunks = LocalAIText.chunks(lines, limit: limit)
        guard !chunks.isEmpty else { return [] }
        let steps = Double(chunks.count + (chunks.count > 1 ? 1 : 0))
        var partials: [[String]] = []
        for (i, chunk) in chunks.enumerated() {
            try Task.checkCancellation()
            let response = try await generator.generate(.init(
                instructions: LocalAIText.summaryInstructions(language),
                prompt: LocalAIText.summaryPrompt(chunk, part: i + 1, of: chunks.count, language: language),
                greedy: false, maxTokens: 768))
            partials.append(LocalAIText.parseBullets(response))
            progress(Double(i + 1) / steps)
        }
        guard partials.count > 1 else { return partials.first ?? [] }
        // 部分ごとの要約をまとめる（長すぎるときは半分ずつまとめ直す）
        var items = partials
        while true {
            try Task.checkCancellation()
            let prompt = LocalAIText.combinePrompt(items, language: language)
            if prompt.count <= limit * 2 || items.count <= 2 {
                let response = try await generator.generate(.init(
                    instructions: LocalAIText.summaryInstructions(language), prompt: prompt, greedy: false, maxTokens: 1024))
                progress(1)
                return LocalAIText.parseBullets(response)
            }
            let half = items.count / 2
            var merged: [[String]] = []
            for part in [Array(items[..<half]), Array(items[half...])] {
                let response = try await generator.generate(.init(
                    instructions: LocalAIText.summaryInstructions(language),
                    prompt: LocalAIText.combinePrompt(part, language: language), greedy: false, maxTokens: 1024))
                merged.append(LocalAIText.parseBullets(response))
            }
            items = merged
        }
    }

    // MARK: 重要な発言

    public static func keyPoints(_ lines: [LocalAIText.Line], segments: [TranscriptSegment], generator: any TextGenerator,
                                 languageCode: String?, maxCount: Int = 10,
                                 progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> [KeyPoint] {
        let language = LocalAIText.OutputLanguage(code: languageCode)
        let chunks = LocalAIText.chunks(lines, limit: chunkLimit(generator))
        guard !chunks.isEmpty else { return [] }
        let perChunk = max(2, min(5, Int((Double(maxCount) / Double(chunks.count)).rounded(.up))))
        var picked: [(index: Int, reason: KeyPointReason?)] = []
        for (i, chunk) in chunks.enumerated() {
            try Task.checkCancellation()
            let response = try await generator.generate(.init(
                instructions: LocalAIText.keyPointInstructions(language),
                prompt: LocalAIText.keyPointPrompt(chunk, maxCount: perChunk, language: language), greedy: true, maxTokens: 384))
            for (index, text) in LocalAIText.parseNumbered(response, valid: Set(chunk.map(\.index))).prefix(perChunk) {
                picked.append((index, LocalAIText.reason(from: text)))
            }
            progress(Double(i + 1) / Double(chunks.count))
        }
        let byIndex = Dictionary(lines.map { ($0.index, $0) }, uniquingKeysWith: { a, _ in a })
        return picked.prefix(maxCount).sorted { $0.index < $1.index }.compactMap { item in
            guard let line = byIndex[item.index], segments.indices.contains(item.index) else { return nil }
            return KeyPoint(text: line.text, start: line.start, speaker: segments[item.index].speaker,
                            reasons: item.reason.map { [$0] } ?? [])
        }
    }

    // MARK: 誤認識の修正・文章の整形

    /// 書き換えの候補を作る（`task` は `.correction` か `.polish`）。検査を通らない候補は `rejected` に入れ、原文のまま残す。
    /// - Parameter suspicious: 確からしさが低い語（誤認識の修正の手がかり。区間の番号 → 語）
    public static func rewrite(_ task: AITask, lines: [LocalAIText.Line], suspicious: [Int: [String]] = [:],
                               generator: any TextGenerator, languageCode: String?,
                               progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> RewriteOutcome {
        precondition(task == .correction || task == .polish)
        let language = LocalAIText.OutputLanguage(code: languageCode)
        // 返答が長くなるので、要約より小さく区切る
        let chunks = LocalAIText.chunks(lines, limit: chunkLimit(generator) / 2)
        var candidates: [RewriteCandidate] = []
        var rejected: [RejectedRewrite] = []
        for (i, chunk) in chunks.enumerated() {
            try Task.checkCancellation()
            let request: GenerationRequest = task == .polish
                ? .init(instructions: LocalAIText.polishInstructions(language),
                        prompt: LocalAIText.polishPrompt(chunk, language: language), greedy: true, maxTokens: 1024)
                : .init(instructions: LocalAIText.correctionBatchInstructions(language),
                        prompt: LocalAIText.correctionBatchPrompt(chunk, suspicious: suspicious, language: language),
                        greedy: true, maxTokens: 1024)
            let response = try await generator.generate(request)
            let originals = Dictionary(chunk.map { ($0.index, $0.text) }, uniquingKeysWith: { a, _ in a })
            for (index, text) in LocalAIText.parseNumbered(response, valid: Set(originals.keys)) {
                guard let original = originals[index] else { continue }
                let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard cleaned != original else { continue }
                let violations = RewriteGuard.check(original: original, rewritten: cleaned, task: task)
                if violations.isEmpty {
                    candidates.append(RewriteCandidate(index: index, original: original, rewritten: cleaned))
                } else {
                    rejected.append(RejectedRewrite(index: index, rewritten: cleaned, violations: violations))
                }
            }
            progress(Double(i + 1) / Double(max(chunks.count, 1)))
        }
        return RewriteOutcome(candidates: candidates.sorted { $0.index < $1.index },
                              rejected: rejected.sorted { $0.index < $1.index })
    }

    /// 1 つの区間の修正案（前後の文を手がかりにする）。直す必要がない・検査を通らない場合は nil。
    public static func suggestCorrection(target: String, before: [String], after: [String], suspicious: [String],
                                         generator: any TextGenerator, languageCode: String?) async throws -> String? {
        let language = LocalAIText.OutputLanguage(code: languageCode)
        let response = try await generator.generate(.init(
            instructions: LocalAIText.correctionInstructions(language),
            prompt: LocalAIText.correctionPrompt(target: target, before: before, after: after,
                                                 suspicious: suspicious, language: language),
            greedy: true, maxTokens: 256))
        guard let suggestion = LocalAIText.acceptedCorrection(response, original: target) else { return nil }
        return RewriteGuard.check(original: target, rewritten: suggestion, task: .correction).isEmpty ? suggestion : nil
    }

    // MARK: 翻訳

    /// 文字起こしを翻訳する（区切ったまとまりごとに訳し、まとまりごとの訳文を返す。原文は変えない）
    /// - Parameter target: 訳す先の言語コード（ja / en など）
    public static func translate(_ lines: [LocalAIText.Line], generator: any TextGenerator, source: String?, target: String,
                                 progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> [String] {
        let chunks = LocalAIText.chunks(lines, limit: chunkLimit(generator) / 2)
        var result: [String] = []
        for (i, chunk) in chunks.enumerated() {
            try Task.checkCancellation()
            let text = chunk.map(\.text).joined(separator: "\n")
            let translated = try await generator.translate(text, from: source, to: target)
            result.append(LocalAIText.cleanTranslation(translated))
            progress(Double(i + 1) / Double(max(chunks.count, 1)))
        }
        return result
    }
}
