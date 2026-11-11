import Foundation
@testable import WhisperBatchCore

/// テストでは、リポジトリの Localization フォルダから文字列を読み込み、日本語表示にそろえる
enum TestLocalization {
    static let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Localization")

    private static let loaded: Void = {
        Localizer.shared.loadTables(fromDirectory: directory)
        Localizer.shared.setLanguage(.japanese)
    }()

    static func setUp() { _ = loaded }

    /// アプリ側（テストから参照できないターゲット）で、値から組み立てて使うキー
    static let extraDynamicKeys: [String] = [
        // ライブ文字起こしの品質（LiveQualityMeter.Status）
        "live.quality.measuring", "live.quality.good", "live.quality.delayed", "live.quality.behind",
        "live.quality.measuring.help", "live.quality.good.help", "live.quality.delayed.help", "live.quality.behind.help",
        // 結果の表示方法（TranscriptViewMode）
        "editor.mode.text", "editor.mode.segments",
        // 話者識別のモデル（ModelCatalog.auxiliary）
        "model.speaker-diarization.name", "model.speaker-diarization.summary",
    ]
}
