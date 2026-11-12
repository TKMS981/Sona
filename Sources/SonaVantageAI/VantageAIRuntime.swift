import Foundation
import SonaLLM
import WhisperBatchCore
import WhisperBatchEngine

/// Sona Vantage の AI 機能の実装（ローカルの言語モデル・Apple Intelligence の端末内のモデル・話者識別）。
/// どの処理もこの Mac の中だけで行い、音声・文字を外部へ送らない。
public final class VantageAIRuntime: AIRuntime {
    private let host: LlamaModelHost
    /// ローカルの言語モデルの結果の再利用（メモリの中だけ）
    let cache: AIResultCache

    /// - Parameter idleTimeout: 使い終わってからローカルのモデルを自動で解放するまでの時間（nil なら自動では解放しない）
    public init(idleTimeout: Duration? = .seconds(180), cache: AIResultCache = AIResultCache()) {
        host = LlamaModelHost(idleTimeout: idleTimeout)
        self.cache = cache
    }

    public func appleIntelligenceAvailability(languageCode: String?) -> AIAvailability {
        AppleIntelligenceGenerator.availability(languageCode: languageCode)
    }

    public func textGenerator(for engine: AITextEngine, storage: ModelStorage, cacheScope: String?) async throws -> any TextGenerator {
        switch engine {
        case .appleIntelligence:
            let availability = AppleIntelligenceGenerator.availability(languageCode: nil)
            guard availability == .available else {
                throw WhisperBatchError.onDeviceAIUnavailable(reason: availability.message)
            }
            // Apple Intelligence の結果は再利用しない（モデルは macOS が更新し、版を確かめられない。要約は毎回少し揺らす）
            return AppleIntelligenceGenerator()
        case .local(let model):
            let installed = ModelInstallation.resolve(model, storage: storage)
            guard let download = installed.usableModel else {
                throw WhisperBatchError.modelNotInstalled(modelName: model.displayName)
            }
            // 読み込む前に SHA-256 で照合する（照合済みで変わっていないファイルは照合し直さない）
            try await storage.verifyContents(of: download)
            let file = download.files[0]
            let generator = try await host.generator(for: model, fileURL: storage.fileURL(for: file, of: download))
            // 同じ条件（入力・モデルのファイル・推論の設定・プロンプトの版）の依頼は、前の結果を使う
            let identity = AIResultCacheKey.Model(
                id: model.id, revision: Self.revision(of: installed, model: model), fileSHA256: file.sha256,
                format: model.format.rawValue, contextTokens: model.contextTokens,
                inferenceSettings: LlamaInferenceSettings.signature)
            return CachingTextGenerator(base: generator, cache: cache, model: identity, scope: cacheScope)
        }
    }

    private static func revision(of installation: ModelInstallation, model: LocalLLM) -> String {
        switch installation {
        case .outdated(_, let revision): revision
        default: model.revision
        }
    }

    public func releaseTextModel() async {
        await host.release()
    }

    public func shutdownTextModel() async {
        await host.shutdown()
    }

    public func loadedTextModelID() async -> String? {
        await host.loadedModelID
    }

    public func observeLoadedTextModel(_ handler: @escaping @Sendable (String?) -> Void) async {
        await host.setObserver(handler)
    }

    public func invalidateCachedResults(scope: String) async {
        await cache.invalidate(scope: scope)
    }

    public func invalidateCachedResults(modelID: String) async {
        await cache.invalidate(modelID: modelID)
    }

    @MainActor
    public func identifySpeakers(item: QueueItem, storage: ModelStorage, speakerCount: Int?,
                                 onRefresh: @escaping @MainActor (SecurityScopedAccess.RefreshedBookmark) -> Void,
                                 progress: @escaping @Sendable (SpeakerIdentificationPhase, Double) -> Void) async throws -> [SpeakerTurn] {
        try await SpeakerIdentification.run(item: item, storage: storage, speakerCount: speakerCount,
                                            onRefresh: onRefresh, progress: progress)
    }
}
