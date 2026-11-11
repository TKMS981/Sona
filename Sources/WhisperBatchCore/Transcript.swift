import Foundation

/// 認識結果の 1 区間。時刻は音声ファイル先頭からの秒数。
public struct TranscriptSegment: Equatable, Sendable, Codable {
    public var start: TimeInterval
    public var end: TimeInterval
    public var text: String
    /// 認識の確からしさ（0...1）。認識方式が値を返したときだけ入る（推測した値は入れない）。
    /// Whisper はトークン確率の平均、ReazonSpeech はトークンの対数確率から求めた確率の平均、
    /// Apple の音声認識は語句ごとの confidence の平均。正解率ではなく、モデル自身の確からしさ。
    public var confidence: Double?
    /// 語句（トークン）ごとの確からしさ。認識方式が返したときだけ入る。
    /// `text` はこれらを順につなげて前後の空白を除いたもの。
    public var words: [TranscriptWord]?
    /// 話者の番号（0 始まり）。話者識別をしたときだけ入る。
    public var speaker: Int?

    public init(start: TimeInterval, end: TimeInterval, text: String,
                confidence: Double? = nil, words: [TranscriptWord]? = nil, speaker: Int? = nil) {
        self.start = start
        self.end = end
        self.text = text
        self.confidence = confidence
        self.words = words
        self.speaker = speaker
    }

    /// 時刻だけを変えたもの（確からしさ・語句・話者はそのまま）
    public func with(start: TimeInterval, end: TimeInterval) -> TranscriptSegment {
        var copy = self
        copy.start = start
        copy.end = end
        return copy
    }

    /// 文字だけを変えたもの。語句ごとの確からしさは文字と合わなくなるので外す（区間の確からしさと話者は残す）。
    public func with(text: String) -> TranscriptSegment {
        var copy = self
        copy.text = text
        copy.words = nil
        return copy
    }
}

/// 語句（トークン）1 つ分の確からしさ
public struct TranscriptWord: Equatable, Sendable, Codable {
    public var text: String
    /// 0...1。この語句について値が返されなかった（句読点など）ときは nil。
    public var probability: Double?

    public init(text: String, probability: Double?) {
        self.text = text
        self.probability = probability
    }
}

extension TranscriptSegment {
    /// 語句の確からしさの平均（値のある語句がなければ nil）。空白・句読点だけの語句は数えない。
    public static func meanProbability(of words: [TranscriptWord]) -> Double? {
        let values = words.compactMap { word -> Double? in
            guard !word.text.allSatisfy({ $0.isWhitespace || $0.isPunctuation }) else { return nil }
            return word.probability
        }
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }
}

public struct Transcript: Equatable, Sendable, Codable {
    public var segments: [TranscriptSegment]
    /// 認識に使った言語コード（例: "ja"）。自動判定時は判定結果。
    public var language: String?

    public init(segments: [TranscriptSegment], language: String?) {
        self.segments = segments
        self.language = language
    }

    public var isEmpty: Bool {
        segments.allSatisfy { $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
}

/// 文字起こしの言語設定（アプリの表示言語 `AppLanguage` とは別）
public enum LanguageOption: Hashable, Sendable, CaseIterable, Identifiable {
    case auto
    case japanese
    case english
    case chinese
    case korean
    case spanish
    case french
    case german

    public var id: String { code ?? "auto" }

    /// whisper.cpp に渡す言語コード。nil は自動判定。
    public var code: String? {
        switch self {
        case .auto: nil
        case .japanese: "ja"
        case .english: "en"
        case .chinese: "zh"
        case .korean: "ko"
        case .spanish: "es"
        case .french: "fr"
        case .german: "de"
        }
    }

    /// 表示名（表示言語に従う）
    public var displayName: String {
        L("whisperLanguage.\(id)")
    }

    /// macOS の音声認識に渡す地域付きの言語（自動判定は nil）
    public var localeIdentifier: String? {
        switch self {
        case .auto: nil
        case .japanese: "ja-JP"
        case .english: "en-US"
        case .chinese: "zh-CN"
        case .korean: "ko-KR"
        case .spanish: "es-ES"
        case .french: "fr-FR"
        case .german: "de-DE"
        }
    }

    public init(storageValue: String?) {
        self = Self.allCases.first { $0.id == storageValue } ?? .japanese
    }

    /// 判定された言語コードの表示名（一覧にない言語はコードをそのまま表示）
    public static func displayName(forCode code: String) -> String {
        allCases.first { $0.code == code }?.displayName ?? code
    }
}
