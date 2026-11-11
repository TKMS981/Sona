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

    /// 生成器を用意する。ローカルのモデルは一度に 1 つだけ読み込み、別のモデルを使うときは前のモデルを解放する。
    /// 読み込む前にモデルのファイルを SHA-256 で照合する。
    func textGenerator(for engine: AITextEngine, storage: ModelStorage) async throws -> any TextGenerator

    /// 読み込んでいるローカルのモデルを解放する
    func releaseTextModel() async

    /// 読み込んでいるローカルのモデルの id（なければ nil）
    func loadedTextModelID() async -> String?

    /// 話者を識別する（話者識別のモデルが必要）
    @MainActor
    func identifySpeakers(item: QueueItem, storage: ModelStorage, speakerCount: Int?,
                          onRefresh: @escaping @MainActor (SecurityScopedAccess.RefreshedBookmark) -> Void,
                          progress: @escaping @Sendable (SpeakerIdentificationPhase, Double) -> Void) async throws -> [SpeakerTurn]
}
