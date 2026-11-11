import Foundation
import WhisperBatchCore
import WhisperBatchEngine

/// AI 機能（Vantage だけ）。Air では `SonaRuntime.ai` が nil なので、どれも使えない状態を返す。
extension AppModel {
    /// このエディションで使える機能
    var features: SonaFeatures { SonaRuntime.features }

    func has(_ feature: SonaFeatures) -> Bool { features.contains(feature) }

    var edition: SonaEdition { SonaRuntime.edition }

    /// 取得済みで使えるローカルのモデル（以前のリビジョンが残っているものを含む）
    var installedLLMIDs: Set<String> {
        Set(LocalLLMCatalog.all.filter { models.llmInstallation($0).usableModel != nil }.map(\.id))
    }

    func appleIntelligenceAvailability(_ languageCode: String?) -> AIAvailability {
        SonaRuntime.ai?.appleIntelligenceAvailability(languageCode: languageCode) ?? .notInEdition
    }

    /// 用途と言語から使うものを決める（モデルの取得はしない。なければ案内を返す）
    func resolveAI(_ task: AITask, languageCode: String?) -> AIModelResolution {
        guard SonaRuntime.ai != nil else { return .unavailable(.appleIntelligenceUnavailable(.notInEdition)) }
        return AIModelSelector.resolve(task: task, languageCode: languageCode, preferences: settings.aiPreferences,
                                       installed: installedLLMIDs,
                                       appleAvailability: { [weak self] in self?.appleIntelligenceAvailability($0) ?? .notInEdition })
    }

    /// 用途に使う生成器を用意する（ローカルのモデルは照合してから読み込む。前のモデルは解放する）
    func textGenerator(for task: AITask, languageCode: String?) async throws -> any TextGenerator {
        guard let ai = SonaRuntime.ai, let storage = models.storage else {
            throw AIGuidanceError(guidance: .appleIntelligenceUnavailable(.notInEdition))
        }
        switch resolveAI(task, languageCode: languageCode) {
        case .unavailable(let guidance):
            throw AIGuidanceError(guidance: guidance)
        case .local(let model):
            let generator = try await ai.textGenerator(for: .local(model), storage: storage)
            loadedAIModelID = model.id
            return generator
        case .appleIntelligence:
            return try await ai.textGenerator(for: .appleIntelligence, storage: storage)
        }
    }

    /// 読み込んでいるローカルのモデルを解放する
    func releaseAIModel() {
        Task {
            await SonaRuntime.ai?.releaseTextModel()
            loadedAIModelID = nil
        }
    }

    /// ローカルのモデルを削除する（読み込み中なら先に解放する。以前のリビジョンのファイルも消す）
    func deleteLLM(_ model: LocalLLM) async throws {
        let loaded = await SonaRuntime.ai?.loadedTextModelID()
        if loadedAIModelID == model.id || loaded == model.id {
            await SonaRuntime.ai?.releaseTextModel()
            loadedAIModelID = nil
        }
        try models.delete(model.downloadModel)
        for previous in model.previousFiles {
            try models.delete(model.downloadModel(for: previous))
        }
    }
}
