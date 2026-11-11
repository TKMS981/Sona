import Foundation
import WhisperBatchCore
import WhisperBatchEngine

/// 起動したエディションと、AI 機能の実装（Vantage だけ）。起動時に一度だけ設定する。
///
/// 画面は AI 機能をここを通してだけ使う。Air では `ai` が nil で、AI の機能は表示しない。
@MainActor
public enum SonaRuntime {
    public private(set) static var edition: SonaEdition = .air
    public private(set) static var ai: (any AIRuntime)?

    /// エディションと AI の実装を設定する（Air では AI の実装を渡さない）
    public static func configure(edition: SonaEdition, ai: (any AIRuntime)?) {
        precondition(edition == .vantage || ai == nil, "Sona Air は AI の実装を使わない")
        self.edition = edition
        self.ai = ai
    }

    /// 使える機能（AI の実装がなければ AI の機能は使えない）
    public static var features: SonaFeatures {
        ai == nil ? [] : edition.features
    }
}
