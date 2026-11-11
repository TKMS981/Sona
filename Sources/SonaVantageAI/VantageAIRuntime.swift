import Foundation
import SonaLLM
import WhisperBatchCore
import WhisperBatchEngine

/// Sona Vantage の AI 機能の実装（ローカルの言語モデル・Apple Intelligence の端末内のモデル・話者識別）。
/// どの処理もこの Mac の中だけで行い、音声・文字を外部へ送らない。
public final class VantageAIRuntime: AIRuntime {
    private let host = LlamaModelHost()

    public init() {}

    public func appleIntelligenceAvailability(languageCode: String?) -> AIAvailability {
        AppleIntelligenceGenerator.availability(languageCode: languageCode)
    }

    public func textGenerator(for engine: AITextEngine, storage: ModelStorage) async throws -> any TextGenerator {
        switch engine {
        case .appleIntelligence:
            let availability = AppleIntelligenceGenerator.availability(languageCode: nil)
            guard availability == .available else {
                throw WhisperBatchError.onDeviceAIUnavailable(reason: availability.message)
            }
            return AppleIntelligenceGenerator()
        case .local(let model):
            let installed = ModelInstallation.resolve(model, storage: storage)
            guard let download = installed.usableModel else {
                throw WhisperBatchError.modelNotInstalled(modelName: model.displayName)
            }
            // 読み込む前に SHA-256 で照合する（照合済みで変わっていないファイルは照合し直さない）
            try await storage.verifyContents(of: download)
            return try await host.generator(for: model, fileURL: storage.fileURL(for: download.files[0], of: download))
        }
    }

    public func releaseTextModel() async {
        await host.release()
    }

    public func loadedTextModelID() async -> String? {
        await host.loadedModelID
    }

    @MainActor
    public func identifySpeakers(item: QueueItem, storage: ModelStorage, speakerCount: Int?,
                                 onRefresh: @escaping @MainActor (SecurityScopedAccess.RefreshedBookmark) -> Void,
                                 progress: @escaping @Sendable (SpeakerIdentificationPhase, Double) -> Void) async throws -> [SpeakerTurn] {
        try await SpeakerIdentification.run(item: item, storage: storage, speakerCount: speakerCount,
                                            onRefresh: onRefresh, progress: progress)
    }
}
