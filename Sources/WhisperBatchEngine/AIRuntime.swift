import Foundation
import WhisperBatchCore

/// 話者識別の段階
public enum SpeakerIdentificationPhase: Sendable {
    case converting, reading, analyzing
}

/// Vantage の AI 機能の実装（Air では使わない。実装は SonaVantageAI にあり、起動時に設定する）。
///
/// どの処理もこの Mac の中だけで行い、音声・文字を外部へ送らない。
public protocol AIRuntime: AnyObject, Sendable {
    /// Apple Intelligence の端末内のモデルを使えるか
    func appleIntelligenceAvailability(languageCode: String?) -> AIAvailability

    /// 生成器を用意する。ローカルのモデルは一度に 1 つだけ読み込み、別のモデルを使うときは前のモデルを使い終わるのを待って解放する。
    /// 読み込む前にモデルのファイルを SHA-256 で照合する。返した生成器を持っている間はモデルを解放しない。
    /// - Parameter cacheScope: 結果を再利用するときの対象（キューの項目の id・"live"。編集・削除のときにこの単位で消す）
    func textGenerator(for engine: AITextEngine, storage: ModelStorage, cacheScope: String?) async throws -> any TextGenerator

    /// 読み込んでいるローカルのモデルを解放する（使用中なら、使い終わったときに解放する）
    func releaseTextModel() async

    /// アプリの終了時: 実行中の推論を打ち切り、モデルを解放する
    func shutdownTextModel() async

    /// 読み込んでいるローカルのモデルの id（なければ nil）
    func loadedTextModelID() async -> String?

    /// 読み込んでいるモデルが変わったら呼ぶ（自動で解放したときを含む。表示の更新用）
    func observeLoadedTextModel(_ handler: @escaping @Sendable (String?) -> Void) async

    /// 対象（キューの項目の id・"live"）の、再利用のために残している AI の結果を消す（編集・削除のとき）
    func invalidateCachedResults(scope: String) async

    /// モデルの、再利用のために残している AI の結果を消す（モデルの削除・更新のとき）
    func invalidateCachedResults(modelID: String) async

    /// 音声を直接読む言語モデル（Qwen3-ASR・Granite Speech）で文字起こしする認識器を読み込む。
    /// モデルのファイルは呼び出し側が照合してから渡す。返した認識器を手放すと解放する。
    func speechTranscriber(for model: SpeechModel, storage: ModelStorage) async throws -> any Transcriber

    /// 話者を識別する（話者識別のモデルが必要）
    @MainActor
    func identifySpeakers(item: QueueItem, storage: ModelStorage, speakerCount: Int?,
                          onRefresh: @escaping @MainActor (SecurityScopedAccess.RefreshedBookmark) -> Void,
                          progress: @escaping @Sendable (SpeakerIdentificationPhase, Double) -> Void) async throws -> [SpeakerTurn]
}

extension AIRuntime {
    public func textGenerator(for engine: AITextEngine, storage: ModelStorage) async throws -> any TextGenerator {
        try await textGenerator(for: engine, storage: storage, cacheScope: nil)
    }
}
