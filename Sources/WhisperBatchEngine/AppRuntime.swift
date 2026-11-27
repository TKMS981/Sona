import Foundation
import WhisperBatchCore

/// 起動時に決まるエディションと AI の実装。画面の状態（AppModel）が起動時に一度だけ受け取る。
///
/// AI の実装は常にある（Air では `DisabledAIRuntime`）。使えるかどうかは `providesAI` と `features` で判断し、
/// 呼び出し側で nil を判定しない。
public struct AppRuntime: Sendable {
    public let edition: SonaEdition
    public let ai: any AIRuntime
    /// 本物の AI の実装があるか（Air・AI の実装を渡さなかったときは false）
    public let providesAI: Bool

    /// - Parameter ai: AI の実装（Vantage だけ）。nil なら `DisabledAIRuntime` を使う。
    public init(edition: SonaEdition, ai: (any AIRuntime)?) {
        precondition(edition == .vantage || ai == nil, "Sona Air は AI の実装を使わない")
        self.edition = edition
        self.ai = ai ?? DisabledAIRuntime()
        providesAI = ai != nil
    }

    /// 使える機能（AI の実装がなければ AI の機能は使えない）
    public var features: SonaFeatures {
        providesAI ? edition.features : []
    }

    /// 選べる文字起こしの方式（Qwen3-ASR・Granite Speech は AI の実装が必要）
    public var availableEngines: [SpeechEngine] {
        SpeechEngine.available(hasAIRuntime: providesAI)
    }
}

/// Air 用の AI の実装: どの AI の機能も使えない状態を返し、解放・消去などは何もしない。
public final class DisabledAIRuntime: AIRuntime {
    public init() {}

    public func appleIntelligenceAvailability(languageCode: String?) -> AIAvailability {
        .notInEdition
    }

    public func textGenerator(for engine: AITextEngine, storage: ModelStorage, cacheScope: String?) async throws -> any TextGenerator {
        throw AIGuidanceError(guidance: .appleIntelligenceUnavailable(.notInEdition))
    }

    public func releaseTextModel() async {}
    public func shutdownTextModel() async {}
    public func loadedTextModelID() async -> String? { nil }
    public func observeLoadedTextModel(_ handler: @escaping @Sendable (String?) -> Void) async {}
    public func invalidateCachedResults(scope: String) async {}
    public func invalidateCachedResults(modelID: String) async {}

    public func speechTranscriber(for model: SpeechModel, storage: ModelStorage) async throws -> any Transcriber {
        throw WhisperBatchError.onDeviceAIUnavailable(reason: L("engine.requiresVantage", model.engine.displayName))
    }

    @MainActor
    public func identifySpeakers(item: QueueItem, storage: ModelStorage, speakerCount: Int?,
                                 onRefresh: @escaping @MainActor (SecurityScopedAccess.RefreshedBookmark) -> Void,
                                 progress: @escaping @Sendable (SpeakerIdentificationPhase, Double) -> Void) async throws -> [SpeakerTurn] {
        throw AIGuidanceError(guidance: .appleIntelligenceUnavailable(.notInEdition))
    }
}
