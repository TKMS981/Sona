import Foundation
import Synchronization
import WhisperBatchCore
import WhisperBatchEngine

/// AI 機能（Vantage だけ）。Air では `runtime.ai` が `DisabledAIRuntime` なので、どれも使えない状態を返す。
extension AppModel {
    /// このエディションで使える機能
    var features: SonaFeatures { runtime.features }

    func has(_ feature: SonaFeatures) -> Bool { features.contains(feature) }

    var edition: SonaEdition { runtime.edition }

    /// 選べる文字起こしの方式（Air では Qwen3-ASR・Granite Speech を出さない）
    var availableEngines: [SpeechEngine] { runtime.availableEngines }

    /// 取得済みで使えるローカルのモデル（以前のリビジョンが残っているものを含む）
    var installedLLMIDs: Set<String> { models.installedLLMIDs() }

    func appleIntelligenceAvailability(_ languageCode: String?) -> AIAvailability {
        runtime.ai.appleIntelligenceAvailability(languageCode: languageCode)
    }

    /// 用途と言語から使うものを決める（モデルの取得はしない。なければ案内を返す）
    func resolveAI(_ task: AITask, languageCode: String?) -> AIModelResolution {
        guard runtime.providesAI else { return .unavailable(.appleIntelligenceUnavailable(.notInEdition)) }
        return AIModelSelector.resolve(task: task, languageCode: languageCode, preferences: settings.aiPreferences,
                                       installed: installedLLMIDs,
                                       appleAvailability: { [weak self] in self?.appleIntelligenceAvailability($0) ?? .notInEdition })
    }

    /// 用途に使う生成器を用意する（ローカルのモデルは照合してから読み込む。前のモデルは使い終わるのを待って解放する）。
    /// 返した生成器を持っている間はモデルを解放しない（処理が終わったら手放す）。
    /// - Parameter scope: 結果を再利用するときの対象（キューの項目の id・"live"。編集・削除でこの単位の結果を消す）
    func textGenerator(for task: AITask, languageCode: String?, scope: String?) async throws -> any TextGenerator {
        guard let storage = models.storage else {
            throw AIGuidanceError(guidance: .appleIntelligenceUnavailable(.notInEdition))
        }
        let ai = runtime.ai
        switch resolveAI(task, languageCode: languageCode) {
        case .unavailable(let guidance):
            throw AIGuidanceError(guidance: guidance)
        case .local(let model):
            return try await ai.textGenerator(for: .local(model), storage: storage, cacheScope: scope)
        case .appleIntelligence:
            return try await ai.textGenerator(for: .appleIntelligence, storage: storage, cacheScope: scope)
        }
    }

    /// 読み込んでいるローカルのモデルを解放する（使用中なら、使い終わったときに解放する。表示は解放したときに変わる）
    func releaseAIModel() {
        Task {
            await runtime.ai.releaseTextModel()
        }
    }

    /// ローカルのモデルを削除する（読み込み中なら解放を頼む。以前のリビジョンのファイルも消す）。
    /// 使用中ならモデルは使い終わったときに解放される（読み込んだ内容はファイルを消しても使い終わるまで残る）。
    func deleteLLM(_ model: LocalLLM) async throws {
        if await runtime.ai.loadedTextModelID() == model.id {
            await runtime.ai.releaseTextModel()
        }
        await runtime.ai.invalidateCachedResults(modelID: model.id)
        try models.delete(model.downloadModel)
        for previous in model.previousFiles {
            try models.delete(model.downloadModel(for: previous))
        }
    }

    /// AI の機能の状態の通知を受け取る（起動時に一度だけ呼ぶ。Air では AI の機能がないので何もつながない）
    func connectAIRuntime() {
        guard runtime.providesAI else { return }
        let ai = runtime.ai
        // 読み込んでいるモデルの表示（自動で解放したときも反映する）。届いた順に反映する。
        let order = AIModelEventOrder()
        Task {
            await ai.observeLoadedTextModel { [weak self] id in
                let sequence = order.next()
                Task { @MainActor in
                    guard let self, order.accept(sequence) else { return }
                    self.loadedAIModelID = id
                }
            }
        }
        // 文字起こしを編集・削除した項目の AI の結果は、再利用しない
        transcription.onTranscriptInputChanged = { ids in
            Task {
                for id in ids { await ai.invalidateCachedResults(scope: id.uuidString) }
            }
        }
        live.onSessionReset = {
            Task { await ai.invalidateCachedResults(scope: AnalysisTarget.live.id) }
        }
    }

    /// ローカルのモデルを取得し直した（更新した）ときは、そのモデルの結果を再利用しない
    func modelDownloadFinished(_ model: SpeechModel) {
        let ai = runtime.ai
        guard model.purpose == .textGeneration,
              let llm = LocalLLMCatalog.all.first(where: { llm in
                  llm.downloadModel.id == model.id || llm.previousFiles.contains { llm.downloadModel(for: $0).id == model.id }
              }) else { return }
        Task { await ai.invalidateCachedResults(modelID: llm.id) }
    }
}

/// 読み込んでいるモデルの通知を、届いた順に反映する（後から届いた古い通知で上書きしない）
final class AIModelEventOrder: Sendable {
    private let state = Mutex((issued: 0, applied: 0))
    func next() -> Int { state.withLock { $0.issued += 1; return $0.issued } }
    func accept(_ sequence: Int) -> Bool {
        state.withLock {
            guard sequence > $0.applied else { return false }
            $0.applied = sequence
            return true
        }
    }
}
