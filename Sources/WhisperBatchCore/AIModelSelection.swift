import Foundation

/// AI の処理に使うものの選び方（1 つの用途、または言語共通の設定）
public enum AIModelChoice: Hashable, Sendable {
    /// 文字起こしの言語に応じて、取得済みのモデルから自動で選ぶ
    case automatic
    /// Apple Intelligence（端末内のモデル）
    case appleIntelligence
    /// 指定したローカルのモデル（`LocalLLM.id`）
    case model(String)

    /// 保存用の文字列
    public var storageValue: String {
        switch self {
        case .automatic: "auto"
        case .appleIntelligence: "apple"
        case .model(let id): "model:\(id)"
        }
    }

    public init?(storageValue: String) {
        switch storageValue {
        case "auto": self = .automatic
        case "apple": self = .appleIntelligence
        default:
            guard storageValue.hasPrefix("model:") else { return nil }
            let id = String(storageValue.dropFirst("model:".count))
            guard LocalLLMCatalog.model(id: id) != nil else { return nil }
            self = .model(id)
        }
    }
}

/// 選び方の方式
public enum AISelectionMode: String, Sendable, CaseIterable, Identifiable {
    /// 文字起こしの言語に応じて自動で選ぶ（用途ごとに向いたモデルを選ぶ）
    case automatic
    /// 言語共通のモデルを 1 つ決めて、どの用途・言語にも使う
    case common
    /// 用途（誤認識の修正・文章の整形・要約・翻訳）ごとに選ぶ
    case perTask

    public var id: String { rawValue }
    public var displayName: String { L("ai.selection.\(rawValue)") }
}

public struct AIModelPreferences: Equatable, Sendable {
    public var mode: AISelectionMode
    public var common: AIModelChoice
    public var perTask: [AITask: AIModelChoice]

    public init(mode: AISelectionMode = .automatic, common: AIModelChoice = .automatic, perTask: [AITask: AIModelChoice] = [:]) {
        self.mode = mode
        self.common = common
        self.perTask = perTask
    }

    /// 用途に対する選び方
    public func choice(for task: AITask) -> AIModelChoice {
        switch mode {
        case .automatic: .automatic
        case .common: common
        case .perTask: perTask[task] ?? .automatic
        }
    }
}

/// 選んだ結果
public enum AIModelResolution: Equatable, Sendable {
    case local(LocalLLM)
    case appleIntelligence
    /// 使えるものがない（ダウンロードは始めず、案内する）
    case unavailable(AIModelGuidance)

    public var engine: AITextEngine? {
        switch self {
        case .local(let model): .local(model)
        case .appleIntelligence: .appleIntelligence
        case .unavailable: nil
        }
    }
}

/// 使えるものがないときの案内
public enum AIModelGuidance: Equatable, Sendable {
    /// 指定したモデルが取得されていない
    case notInstalled(LocalLLM)
    /// 取得済みのモデルがない（候補を示す）
    case noInstalledModel(suggestions: [LocalLLM])
    /// 指定したモデルはこの用途に使えない（翻訳専用のモデルなど）
    case unsupportedTask(LocalLLM)
    /// 指定したモデルはこの Mac のメモリでは重すぎる
    case tooLarge(LocalLLM)
    /// Apple Intelligence を使えない
    case appleIntelligenceUnavailable(AIAvailability)

    public var message: String {
        switch self {
        case .notInstalled(let model):
            L("ai.guidance.notInstalled", model.displayName)
        case .noInstalledModel(let suggestions):
            suggestions.isEmpty
                ? L("ai.guidance.noModel")
                : L("ai.guidance.noModelSuggest", suggestions.map(\.displayName).joined(separator: L("list.separator")))
        case .unsupportedTask(let model):
            L("ai.guidance.unsupportedTask", model.displayName)
        case .tooLarge(let model):
            L("ai.guidance.tooLarge", model.displayName)
        case .appleIntelligenceUnavailable(let availability):
            availability.message
        }
    }
}

/// 用途と文字起こしの言語から、使うものを決める。モデルの取得は行わない（ないときは案内を返す）。
public enum AIModelSelector {
    /// - Parameters:
    ///   - installed: 取得して照合済みのモデルの id
    ///   - appleAvailability: Apple Intelligence を使えるか（言語コードごと）
    public static func resolve(task: AITask, languageCode: String?, preferences: AIModelPreferences,
                               installed: Set<String>, appleAvailability: (String?) -> AIAvailability,
                               physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory) -> AIModelResolution {
        switch preferences.choice(for: task) {
        case .model(let id):
            guard let model = LocalLLMCatalog.model(id: id) else {
                return .unavailable(.noInstalledModel(suggestions: suggestions(for: task, languageCode: languageCode,
                                                                               physicalMemory: physicalMemory)))
            }
            if !model.tasks.contains(task) { return .unavailable(.unsupportedTask(model)) }
            if !LocalLLMCatalog.fitsInMemory(model, physicalMemory: physicalMemory) { return .unavailable(.tooLarge(model)) }
            if !installed.contains(model.id) { return .unavailable(.notInstalled(model)) }
            return .local(model)
        case .appleIntelligence:
            // Apple Intelligence は翻訳に使わない（言語の対応が文字起こしの言語に限られるため、翻訳はローカルのモデルで行う）
            if task == .translation { return .unavailable(.appleIntelligenceUnavailable(.unsupportedLanguage)) }
            let availability = appleAvailability(languageCode)
            return availability == .available ? .appleIntelligence : .unavailable(.appleIntelligenceUnavailable(availability))
        case .automatic:
            let candidates = ranked(for: task, languageCode: languageCode, physicalMemory: physicalMemory)
            if let model = candidates.first(where: { installed.contains($0.id) }) { return .local(model) }
            if task != .translation, appleAvailability(languageCode) == .available { return .appleIntelligence }
            return .unavailable(.noInstalledModel(suggestions: suggestions(for: task, languageCode: languageCode,
                                                                           physicalMemory: physicalMemory)))
        }
    }

    /// 用途と言語に向いた順のモデル（この Mac のメモリに収まり、動かないと分かっているものを除く）
    public static func ranked(for task: AITask, languageCode: String?,
                              physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory) -> [LocalLLM] {
        LocalLLMCatalog.all
            .filter { $0.tasks.contains(task) && $0.verification != .incompatible }
            .filter { LocalLLMCatalog.fitsInMemory($0, physicalMemory: physicalMemory) }
            .filter { task == .translation || !$0.isTranslationOnly }
            .enumerated()
            .sorted { a, b in
                let sa = score(a.element, task: task, languageCode: languageCode)
                let sb = score(b.element, task: task, languageCode: languageCode)
                return sa != sb ? sa > sb : a.offset < b.offset
            }
            .map(\.element)
    }

    /// 取得を勧める候補（軽いものから。自動ではダウンロードしない）
    public static func suggestions(for task: AITask, languageCode: String?,
                                   physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory) -> [LocalLLM] {
        let list = ranked(for: task, languageCode: languageCode, physicalMemory: physicalMemory)
            .filter { $0.verification == .verified || $0.verification == .familyVerified }
        let light = list.filter { $0.categories.contains(.lightweight) }
        return Array((light + list.filter { !$0.categories.contains(.lightweight) }).prefix(3))
    }

    /// 言語の合い方（大）＞ 性能（中）＞ 動作の確認（小）で点を付ける
    static func score(_ model: LocalLLM, task: AITask, languageCode: String?) -> Int {
        var score = 0
        let c = model.categories
        if task == .translation, c.contains(.translation) { score += 1000 }
        switch languageCode {
        case "ja":
            if c.contains(.japanese) { score += 300 } else if c.contains(.multilingual) { score += 200 } else { score += 100 }
        case "en":
            if c.contains(.english) { score += 300 } else if c.contains(.multilingual) { score += 200 } else { score += 100 }
        default:
            if c.contains(.multilingual) { score += 300 } else if c.contains(.english) { score += 200 } else { score += 100 }
        }
        if c.contains(.highQuality) { score += 20 } else if !c.contains(.lightweight) { score += 10 }
        switch model.verification {
        case .verified: score += 5
        case .familyVerified: score += 2
        default: break
        }
        return score
    }
}

/// 使えるものがないときのエラー（案内の文を表示する）
public struct AIGuidanceError: LocalizedError, Equatable, Sendable {
    public var guidance: AIModelGuidance
    public init(guidance: AIModelGuidance) { self.guidance = guidance }
    public var errorDescription: String? { guidance.message }
}
