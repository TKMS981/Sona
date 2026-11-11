import Foundation

/// 確かめた方がよい区間（誤認識の候補）。根拠になる値があるものだけを挙げる。
public struct ReviewCandidate: Equatable, Sendable, Identifiable {
    public enum Reason: Equatable, Sendable {
        /// 認識方式が返した確からしさが低い語句がある（語句と、その中で最も低い値）
        case lowConfidenceWords([String], lowest: Double)
        /// 区間全体の確からしさが低い（語句ごとの値がない方式）
        case lowConfidenceSegment(Double)
        /// 同じ並びが何度も続いている（Whisper が同じ語を繰り返し続ける誤りの兆候）
        case repetition
        /// 区間の長さに対して文字が多すぎる（無音や雑音から文を作る誤認識の兆候）
        case tooDense(charactersPerSecond: Double)
    }

    public var segmentIndex: Int
    public var reasons: [Reason]
    public var id: Int { segmentIndex }

    public var message: String {
        reasons.map { reason in
            switch reason {
            case .lowConfidenceWords(let words, let lowest):
                L("review.reason.lowWords", words.prefix(3).joined(separator: L("list.separator")), Int((lowest * 100).rounded()))
            case .lowConfidenceSegment(let value):
                L("review.reason.lowSegment", Int((value * 100).rounded()))
            case .repetition:
                L("review.reason.repetition")
            case .tooDense(let cps):
                L("review.reason.tooDense", Int(cps.rounded()))
            }
        }.joined(separator: " / ")
    }
}

/// 語句（トークン）の、区間の文字の中での位置
public struct WordSpan: Equatable, Sendable {
    public var range: Range<String.Index>
    public var text: String
    public var probability: Double?
}

public enum ReviewCandidateFinder {
    /// 確からしさがこの値より低い語句・区間を候補にする（設定で変えられる）
    public static let defaultThreshold = 0.5
    /// 1 秒あたりの文字数がこれを超える区間を候補にする（日本語の早口でも 1 秒 12 文字程度。英語は空白を数えない）
    public static let maxCharactersPerSecond = 25.0

    /// 原文と編集から候補を挙げる。書き換えた区間（利用者が確かめた区間）と削除した区間は除く。
    public static func find(in original: Transcript, edits: TranscriptEdits,
                            threshold: Double = defaultThreshold) -> [ReviewCandidate] {
        original.segments.enumerated().compactMap { i, segment in
            guard edits.state(at: i) == .original else { return nil }
            let reasons = reasons(for: segment, threshold: threshold)
            return reasons.isEmpty ? nil : ReviewCandidate(segmentIndex: i, reasons: reasons)
        }
    }

    public static func reasons(for segment: TranscriptSegment, threshold: Double) -> [ReviewCandidate.Reason] {
        var reasons: [ReviewCandidate.Reason] = []
        let low = lowConfidenceSpans(in: segment, threshold: threshold)
        if !low.isEmpty {
            let lowest = low.compactMap(\.probability).min() ?? 0
            reasons.append(.lowConfidenceWords(low.map(\.text), lowest: lowest))
        } else if segment.words == nil, let confidence = segment.confidence, confidence < threshold {
            reasons.append(.lowConfidenceSegment(confidence))
        }
        if LiveText.hasRunawayRepetition(segment.text) {
            reasons.append(.repetition)
        }
        let duration = segment.end - segment.start
        let visible = segment.text.filter { !$0.isWhitespace && !$0.isPunctuation }.count
        // 短い区間は時刻の誤差が大きいので、1 秒以上・10 文字以上のときだけ調べる
        if duration >= 1, visible >= 10 {
            let cps = Double(visible) / duration
            if cps > maxCharactersPerSecond { reasons.append(.tooDense(charactersPerSecond: cps)) }
        }
        return reasons
    }

    /// 語句の位置（区間の文字の中で順に探す。見つからない語句は除く）
    public static func spans(in segment: TranscriptSegment) -> [WordSpan] {
        guard let words = segment.words else { return [] }
        let text = segment.text
        var cursor = text.startIndex
        var result: [WordSpan] = []
        for word in words {
            let piece = word.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !piece.isEmpty, let range = text.range(of: piece, range: cursor ..< text.endIndex) else { continue }
            result.append(WordSpan(range: range, text: piece, probability: word.probability))
            cursor = range.upperBound
        }
        return result
    }

    /// 確からしさが低い語句。隣り合う低い語句は 1 つにまとめる（日本語は 1 文字ずつのトークンが多いため）。
    /// 句読点・空白だけの語句は対象にしない。
    public static func lowConfidenceSpans(in segment: TranscriptSegment, threshold: Double) -> [WordSpan] {
        let text = segment.text
        var result: [WordSpan] = []
        for span in spans(in: segment) {
            guard let p = span.probability, p < threshold,
                  !span.text.allSatisfy({ $0.isWhitespace || $0.isPunctuation }) else { continue }
            if var last = result.last, text[last.range.upperBound ..< span.range.lowerBound].allSatisfy(\.isWhitespace) {
                last.range = last.range.lowerBound ..< span.range.upperBound
                last.text = String(text[last.range])
                last.probability = min(last.probability ?? p, p)
                result[result.count - 1] = last
            } else {
                result.append(span)
            }
        }
        return result
    }
}

/// 話者識別の結果の 1 区間（話者の番号は識別器が付けたもの）
public struct SpeakerTurn: Equatable, Sendable {
    public var start: TimeInterval
    public var end: TimeInterval
    public var speaker: Int

    public init(start: TimeInterval, end: TimeInterval, speaker: Int) {
        self.start = start
        self.end = end
        self.speaker = speaker
    }
}

/// 話者識別の結果を文字起こしの区間に割り当てる
public enum SpeakerAssigner {
    /// 区間ごとの話者。区間と最も長く重なる話者にする。重なりがなければ、`maxGap` 秒以内で最も近い話者にする。
    /// 話者の番号は、文字起こしの中で最初に話した順に 0, 1, 2… と付け直す。
    public static func assign(_ segments: [TranscriptSegment], turns: [SpeakerTurn],
                              maxGap: TimeInterval = 1.0) -> [Int?] {
        let raw = segments.map { segment -> Int? in
            var overlap: [Int: TimeInterval] = [:]
            for turn in turns {
                let o = min(segment.end, turn.end) - max(segment.start, turn.start)
                if o > 0 { overlap[turn.speaker, default: 0] += o }
            }
            if let best = overlap.max(by: { ($0.value, -$0.key) < ($1.value, -$1.key) }) { return best.key }
            // 重なりがない（区間の時刻が短すぎる・識別器が発話とみなさなかった）ときは近い話者
            let nearest = turns.map { turn -> (TimeInterval, Int) in
                let gap = turn.end < segment.start ? segment.start - turn.end : max(turn.start - segment.end, 0)
                return (gap, turn.speaker)
            }.min { $0.0 < $1.0 }
            guard let nearest, nearest.0 <= maxGap else { return nil }
            return nearest.1
        }
        var order: [Int: Int] = [:]
        return raw.map { speaker in
            guard let speaker else { return nil }
            if let mapped = order[speaker] { return mapped }
            let next = order.count
            order[speaker] = next
            return next
        }
    }
}

/// 話者ごとの発言の集計
public struct SpeakerStatistics: Equatable, Sendable, Identifiable {
    public var speaker: Int
    public var segmentCount: Int
    /// 話した時間の合計（区間の長さの合計、秒）
    public var duration: TimeInterval
    public var characterCount: Int
    public var id: Int { speaker }

    /// 話者ごとの集計（話者の番号順）。話者のない区間は含めない。
    public static func make(_ transcript: Transcript) -> [SpeakerStatistics] {
        var stats: [Int: SpeakerStatistics] = [:]
        for segment in transcript.segments {
            guard let speaker = segment.speaker else { continue }
            var s = stats[speaker] ?? SpeakerStatistics(speaker: speaker, segmentCount: 0, duration: 0, characterCount: 0)
            s.segmentCount += 1
            s.duration += max(segment.end - segment.start, 0)
            s.characterCount += segment.text.filter { !$0.isWhitespace }.count
            stats[speaker] = s
        }
        return stats.values.sorted { $0.speaker < $1.speaker }
    }
}
