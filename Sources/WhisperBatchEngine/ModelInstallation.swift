import Foundation
import WhisperBatchCore

/// ローカルの言語モデルの取得状況（今のリビジョン・以前のリビジョン）
public enum ModelInstallation: Equatable, Sendable {
    case notInstalled
    /// 今のカタログのリビジョンが揃っている
    case current(SpeechModel)
    /// 以前のリビジョンが揃っている（更新があるが、更新するまではこれを使う。更新は利用者が選んだときだけ）
    case outdated(SpeechModel, revision: String)

    /// 使えるファイル（読み込む前に SHA-256 で照合する）
    public var usableModel: SpeechModel? {
        switch self {
        case .notInstalled: nil
        case .current(let m), .outdated(let m, _): m
        }
    }

    public var hasUpdate: Bool {
        if case .outdated = self { return true }
        return false
    }

    public static func resolve(_ model: LocalLLM, storage: ModelStorage) -> ModelInstallation {
        let current = model.downloadModel
        if storage.isInstalled(current) { return .current(current) }
        for previous in model.previousFiles {
            let old = model.downloadModel(for: previous)
            if storage.isInstalled(old) { return .outdated(old, revision: previous.revision) }
        }
        return .notInstalled
    }
}
