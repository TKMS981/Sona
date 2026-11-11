import Foundation

/// AI の用途
public enum AITask: String, Sendable, CaseIterable, Identifiable, Codable {
    /// 誤認識の修正（音声認識の誤りだけを直す）
    case correction
    /// 文章の整形（句読点・フィラー・言い直しを整える。語は変えない）
    case polish
    /// 要約・重要な発言
    case summary
    /// 翻訳
    case translation

    public var id: String { rawValue }
    public var displayName: String { L("ai.task.\(rawValue)") }
}

/// 文章を生成するもの（ローカルの言語モデル・Apple Intelligence の端末内のモデル。テストでは差し替える）
public protocol TextGenerator: Sendable {
    /// 表示用の名前（例: 「Qwen3 4B（ローカル）」）
    var displayName: String { get }
    /// 1 回に渡す文字起こしの文字数の上限（文脈の長さから、指示と返答の分を除いたもの）
    var maxInputCharacters: Int { get }
    /// 翻訳専用のモデル（指示に従う一般の生成ではなく、`translate` だけを使う）
    var isTranslationOnly: Bool { get }

    /// 指示（system）と依頼（user）から返答を作る
    func generate(_ request: GenerationRequest) async throws -> String

    /// 翻訳（翻訳専用のモデルは専用の形式で、一般のモデルは指示で翻訳する）
    func translate(_ text: String, from source: String?, to target: String) async throws -> String
}

public struct GenerationRequest: Sendable, Equatable {
    public var instructions: String
    public var prompt: String
    /// 毎回同じ結果になる選び方（修正・選択向け）。false なら少しだけ揺らす（要約向け）。
    public var greedy: Bool
    /// 返答の長さの上限（トークン）
    public var maxTokens: Int

    public init(instructions: String, prompt: String, greedy: Bool = true, maxTokens: Int = 1024) {
        self.instructions = instructions
        self.prompt = prompt
        self.greedy = greedy
        self.maxTokens = maxTokens
    }
}

extension TextGenerator {
    public var isTranslationOnly: Bool { false }

    /// 一般のモデルでの翻訳（指示で翻訳させる）
    public func translate(_ text: String, from source: String?, to target: String) async throws -> String {
        let request = GenerationRequest(instructions: LocalAIText.translationInstructions(target: target),
                                        prompt: text, greedy: true, maxTokens: max(256, text.count * 3))
        return try await generate(request)
    }
}

/// AI の処理に使うもの
public enum AITextEngine: Equatable, Sendable {
    /// Apple Intelligence の端末内のモデル（FoundationModels の SystemLanguageModel。Private Cloud Compute は使わない）
    case appleIntelligence
    /// この Mac に取得したローカルの言語モデル
    case local(LocalLLM)

    public var displayName: String {
        switch self {
        case .appleIntelligence: L("ai.engine.appleIntelligence")
        case .local(let model): L("ai.engine.local", model.displayName)
        }
    }
}

/// AI の処理を使えるか
public enum AIAvailability: Equatable, Sendable {
    case available
    /// この Mac は Apple Intelligence に対応していない
    case deviceNotEligible
    /// Apple Intelligence がオフ
    case notEnabled
    /// モデルの準備中（ダウンロード中など）
    case modelNotReady
    /// 文字起こしの言語に対応していない
    case unsupportedLanguage
    case unavailable
    /// このエディション（Air）では使えない
    case notInEdition

    public var message: String {
        switch self {
        case .available: L("ai.availability.available")
        case .deviceNotEligible: L("ai.availability.deviceNotEligible")
        case .notEnabled: L("ai.availability.notEnabled")
        case .modelNotReady: L("ai.availability.modelNotReady")
        case .unsupportedLanguage: L("ai.availability.unsupportedLanguage")
        case .unavailable: L("ai.availability.unavailable")
        case .notInEdition: L("ai.availability.notInEdition")
        }
    }
}
