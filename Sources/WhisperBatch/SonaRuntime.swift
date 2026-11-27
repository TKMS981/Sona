import Foundation
import WhisperBatchCore
import WhisperBatchEngine

/// 起動したエディションと、AI 機能の実装（Vantage だけ）。起動時に一度だけ設定する。
///
/// ここを読むのは起動時（`SonaApp` が `AppModel` を作るとき）だけ。画面は `AppModel` が受け取った
/// `AppRuntime`（`model.features`・`model.availableEngines` など）を通して使う。
@MainActor
public enum SonaRuntime {
    private static var configured = AppRuntime(edition: .air, ai: nil)

    /// エディションと AI の実装を設定する（Air では AI の実装を渡さない）
    public static func configure(edition: SonaEdition, ai: (any AIRuntime)?) {
        configured = AppRuntime(edition: edition, ai: ai)
    }

    /// 設定した内容（`AppModel` を作るときに渡す）
    static var current: AppRuntime { configured }
}
