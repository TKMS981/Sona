import Foundation

/// 製品のエディション。
///
/// - Air: AI を使わない機能（Whisper などの通常・ライブの文字起こし、編集・部分修正・原文の復元、
///   ドラッグ＆ドロップ、TXT / SRT / WebVTT / Markdown の出力、通知、設定の管理など）。
///   AI のモデル・推論エンジン（llama.cpp・FoundationModels・話者識別）にはリンクしない。
/// - Vantage: Air のすべてに加えて、AI の機能（誤認識の修正・修正候補・自動修正、文章の整形、フィラーの除去、
///   話者の自動識別、要約・重要な発言、翻訳、AI モデルの管理と切り替え）。
public enum SonaEdition: String, Sendable, CaseIterable, Identifiable {
    case air
    case vantage

    public var id: String { rawValue }

    /// 製品名（固有名詞なので表示言語によらない）
    public var productName: String {
        switch self {
        case .air: "Sona Air"
        case .vantage: "Sona Vantage"
        }
    }

    public var features: SonaFeatures {
        switch self {
        case .air: []
        case .vantage: .all
        }
    }
}

/// エディションで使える機能（Air ではどれも使えない）
public struct SonaFeatures: OptionSet, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    /// AI による誤認識の修正（修正候補の表示・自動修正・1 区間ごとの修正案）
    public static let aiCorrection = SonaFeatures(rawValue: 1 << 0)
    /// AI による文章の整形
    public static let aiPolish = SonaFeatures(rawValue: 1 << 1)
    /// フィラーの除去
    public static let fillerRemoval = SonaFeatures(rawValue: 1 << 2)
    /// 話者の自動識別・話者ごとの表示
    public static let speakerIdentification = SonaFeatures(rawValue: 1 << 3)
    /// 全文の要約・重要な発言の抽出
    public static let summary = SonaFeatures(rawValue: 1 << 4)
    /// 翻訳
    public static let translation = SonaFeatures(rawValue: 1 << 5)
    /// 誤認識の候補（要確認）の表示
    public static let reviewCandidates = SonaFeatures(rawValue: 1 << 6)
    /// AI モデルの管理と切り替え
    public static let aiModelManagement = SonaFeatures(rawValue: 1 << 7)

    public static let all: SonaFeatures = [.aiCorrection, .aiPolish, .fillerRemoval, .speakerIdentification,
                                           .summary, .translation, .reviewCandidates, .aiModelManagement]
}
