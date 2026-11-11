import Foundation

/// 細かく区切られた認識結果（語句・文字単位）を、読みやすい文単位の区間にまとめる。
///
/// Apple の音声認識は語句ごとに結果を返すため、そのままでは
/// SRT などの区間が細かくなりすぎる。句点などの文末か、間が空いたところ、長くなりすぎたところで区切る。
public enum SegmentMerger {
    /// 文末とみなす文字
    static let sentenceEnders: Set<Character> = ["。", "．", ".", "!", "?", "！", "？"]

    /// - Parameters:
    ///   - pieces: 時刻順の断片。text は前後の空白を含めてそのままつなげる（英語の単語間の空白を保つため）。
    ///   - maxGap: この秒数より間が空いたら区切る
    ///   - maxDuration: 1 区間の最大の長さ（秒）
    public static func merge(_ pieces: [TranscriptSegment], maxGap: TimeInterval = 1.0,
                             maxDuration: TimeInterval = 20) -> [TranscriptSegment] {
        var result: [TranscriptSegment] = []
        var current: TranscriptSegment?

        // 断片ごとの確からしさ（断片に値があるときだけ。語句としてつなげる）
        var words: [TranscriptWord] = []
        var hasConfidence = false

        func flush() {
            guard let segment = current else { return }
            current = nil
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            defer { words = []; hasConfidence = false }
            guard !text.isEmpty else { return }
            let confidence = hasConfidence ? TranscriptSegment.meanProbability(of: words) : nil
            result.append(TranscriptSegment(start: segment.start, end: max(segment.end, segment.start), text: text,
                                            confidence: confidence, words: confidence == nil ? nil : words))
        }

        func addWords(of piece: TranscriptSegment) {
            if let pieceWords = piece.words {
                words += pieceWords
                hasConfidence = hasConfidence || pieceWords.contains { $0.probability != nil }
            } else {
                words.append(TranscriptWord(text: piece.text, probability: piece.confidence))
                hasConfidence = hasConfidence || piece.confidence != nil
            }
        }

        for piece in pieces {
            if let c = current, piece.start - c.end > maxGap || piece.end - c.start > maxDuration {
                flush()
            }
            if current == nil {
                // 区間の先頭の空白は落とす
                guard !piece.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                current = piece
                addWords(of: piece)
            } else {
                current!.text += piece.text
                current!.end = max(current!.end, piece.end)
                addWords(of: piece)
            }
            let trimmed = current!.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if let last = trimmed.last, sentenceEnders.contains(last) {
                flush()
            }
        }
        flush()
        return result
    }
}
