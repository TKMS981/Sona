import Foundation

/// 区間 1 つへの変更
public enum SegmentChange: Equatable, Sendable, Codable {
    /// 文字を書き換えた
    case replaced(String)
    /// 削除した
    case deleted
}

/// 区間の編集状態（画面表示用）
public enum SegmentEditState: Equatable, Sendable {
    case original
    case edited
    case deleted
}

/// 文字起こし結果への編集。認識した原文は書き換えず、区間ごとの変更として重ねて持つ。
///
/// 原文の区間の番号（`Transcript.segments` の添字）で変更を持つので、区間ごと・全体のどちらでも
/// 原文に戻せる。書き換えた文字が原文と同じになったときは、変更なしとして扱う。
public struct TranscriptEdits: Equatable, Sendable, Codable {
    public private(set) var changes: [Int: SegmentChange] = [:]

    public init() {}

    public var isEmpty: Bool { changes.isEmpty }

    /// 変更した区間の数（書き換えと削除）
    public var count: Int { changes.count }

    public var editedCount: Int { changes.values.filter { if case .replaced = $0 { true } else { false } }.count }
    public var deletedCount: Int { changes.values.filter { $0 == .deleted }.count }

    public func state(at index: Int) -> SegmentEditState {
        switch changes[index] {
        case nil: .original
        case .replaced: .edited
        case .deleted: .deleted
        }
    }

    /// 区間の文字を書き換える。前後の空白は除く。空にしたときは削除、原文と同じなら変更なしにする。
    public mutating func replace(_ index: Int, with text: String, in original: Transcript) {
        guard original.segments.indices.contains(index) else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            changes[index] = .deleted
        } else if trimmed == original.segments[index].text.trimmingCharacters(in: .whitespacesAndNewlines) {
            changes[index] = nil
        } else {
            changes[index] = .replaced(trimmed)
        }
    }

    public mutating func delete(_ index: Int, in original: Transcript) {
        guard original.segments.indices.contains(index) else { return }
        changes[index] = .deleted
    }

    /// 区間を原文に戻す
    public mutating func restore(_ index: Int) {
        changes[index] = nil
    }

    /// すべて原文に戻す
    public mutating func restoreAll() {
        changes = [:]
    }

    /// 区間の今の文字（削除していれば nil）
    public func text(at index: Int, in original: Transcript) -> String? {
        guard original.segments.indices.contains(index) else { return nil }
        switch changes[index] {
        case nil: return original.segments[index].text
        case .replaced(let text): return text
        case .deleted: return nil
        }
    }

    /// 編集を反映した文字起こし（削除した区間は含めない。書き換えた区間は語句の確からしさを外す）
    public func apply(to original: Transcript) -> Transcript {
        guard !changes.isEmpty else { return original }
        var segments: [TranscriptSegment] = []
        segments.reserveCapacity(original.segments.count)
        for (i, segment) in original.segments.enumerated() {
            switch changes[i] {
            case nil: segments.append(segment)
            case .replaced(let text): segments.append(segment.with(text: text))
            case .deleted: break
            }
        }
        return Transcript(segments: segments, language: original.language)
    }
}

/// 文字起こし結果に付ける情報（編集・話者名・要約などの分析結果）。原文とは別に持つ。
public struct TranscriptAnnotations: Equatable, Sendable {
    public var edits = TranscriptEdits()
    /// 話者の名前（番号 → 名前）。付けていない話者は「話者 1」のように表示する。
    public var speakerNames: [Int: String] = [:]
    /// 要約・重要な発言
    public var analysis = TranscriptAnalysis()

    public init() {}

    public var isEmpty: Bool { edits.isEmpty && speakerNames.isEmpty && analysis.isEmpty }
}

/// 話者の表示名
public enum SpeakerNaming {
    /// 名前を付けていれば名前、なければ「話者 1」（番号は 1 始まりで表示する）
    public static func displayName(_ speaker: Int, names: [Int: String]) -> String {
        if let name = names[speaker]?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty { return name }
        return L("speaker.default", speaker + 1)
    }

    /// 名前の最大の長さ
    public static let nameLimit = 40

    /// 入力された名前を整える（改行を除き、長さを制限する）
    public static func sanitized(_ name: String) -> String {
        let oneLine = name.components(separatedBy: .newlines).joined(separator: " ")
        return String(oneLine.trimmingCharacters(in: .whitespaces).prefix(nameLimit))
    }
}
