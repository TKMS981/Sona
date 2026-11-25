import Foundation

/// 発話区間の検出（VAD）の結果から、長い無音だけを短くした音声を作り、認識結果の時刻を元の音声の時刻に戻す。
///
/// - 発話区間の前後 `keptGap / 2` ずつ（既定では 0.5 秒ずつ）の元の音声は必ず残す。
///   VAD の区間の端が語頭・語尾より内側にずれても、その分の音声は消えない。
/// - 発話と発話の間が `minSkippedGap` 以下ならそのまま残す（間の長さを変えない）。
///   それより長い無音だけを、前の発話の後ろ `keptGap / 2` と次の発話の前 `keptGap / 2` をつないだ長さにする。
///   VAD が発話とみなさなかった短い発話（雑音の中の「はい」など）も、短い間の中にあれば消えない。
/// - 無音を短くした後も 1 秒の間が残るので、Whisper は間で区間を分けたままにできる。
///   （whisper.cpp 内蔵の VAD は間を約 0.1 秒に詰めるため、複数の発話が 1 つの区間にまとまる。
///   2026-11 の確認で、1 秒以上の間があれば区間が分かれ、0.3 秒では 1 つにまとまった）
/// - 足す音や作り直す音はない。残すのはすべて元の音声のサンプルそのもの。
public struct SpeechGapPlan: Equatable, Sendable {
    /// 残す範囲 1 つ（サンプル番号）
    public struct Piece: Equatable, Sendable {
        /// 元の音声での開始位置
        public var originalStart: Int
        /// 長さ
        public var length: Int
        /// 短くした音声での開始位置
        public var compressedStart: Int
    }

    public let pieces: [Piece]
    /// 元の音声の長さ（サンプル数）
    public let originalCount: Int
    /// 短くした音声の長さ（サンプル数）
    public var compressedCount: Int { pieces.last.map { $0.compressedStart + $0.length } ?? 0 }
    /// 発話が見つからなかった（認識に渡すものがない）
    public var isEmpty: Bool { pieces.isEmpty }

    /// - Parameters:
    ///   - speech: 発話区間（サンプル番号。順序・重なりは問わない）
    ///   - originalCount: 元の音声の長さ（サンプル数）
    ///   - keptGap: 残す間の長さ（サンプル数）。発話の前後にはこの半分ずつ残す。
    ///   - minSkippedGap: 短くする無音の最短の長さ（サンプル数）。発話と発話の間がこれ以下なら、そのまま残す。
    ///     `keptGap` より短い値は `keptGap` とみなす。
    public init(speech: [Range<Int>], originalCount: Int, keptGap: Int, minSkippedGap: Int = 0) {
        self.originalCount = max(originalCount, 0)
        let half = max(keptGap, 0) / 2
        let minGap = max(minSkippedGap, keptGap, 0)
        let total = self.originalCount
        var kept: [Range<Int>] = []
        var lastSpeechEnd: Int?
        for range in speech.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            let lower = min(max(range.lowerBound - half, 0), total)
            let upper = min(max(range.upperBound + half, lower), total)
            guard upper > lower else { continue }
            defer { lastSpeechEnd = max(lastSpeechEnd ?? 0, range.upperBound) }
            if let last = kept.last, lower <= last.upperBound || range.lowerBound - (lastSpeechEnd ?? 0) <= minGap {
                kept[kept.count - 1] = last.lowerBound ..< max(last.upperBound, upper)
            } else {
                kept.append(lower ..< upper)
            }
        }
        // 音声の先頭・末尾の無音も、短ければそのまま残す
        if let first = kept.first, let firstSpeech = speech.map(\.lowerBound).min(), firstSpeech <= minGap {
            kept[0] = 0 ..< first.upperBound
        }
        if let last = kept.last, let lastSpeechEnd, total - lastSpeechEnd <= minGap {
            kept[kept.count - 1] = last.lowerBound ..< total
        }
        var offset = 0
        pieces = kept.map { range in
            defer { offset += range.count }
            return Piece(originalStart: range.lowerBound, length: range.count, compressedStart: offset)
        }
    }

    /// 短くした音声を取り出す
    public func extract(from samples: [Float]) -> [Float] {
        var out: [Float] = []
        out.reserveCapacity(compressedCount)
        for piece in pieces {
            let upper = min(piece.originalStart + piece.length, samples.count)
            guard upper > piece.originalStart else { continue }
            out.append(contentsOf: samples[piece.originalStart ..< upper])
        }
        return out
    }

    /// 短くした音声での時刻（秒）を、元の音声の時刻（秒）に戻す。
    ///
    /// 残した範囲の中では、元の音声との差は一定（伸び縮みしない）。範囲のつなぎ目の時刻は、
    /// 区間の始まり（`isEnd == false`）なら次の範囲の先頭、終わり（`isEnd == true`）なら前の範囲の末尾にする
    /// （区間の終わりが無音の後ろまで伸びたり、始まりが無音の前に戻ったりしないように）。
    public func originalTime(ofCompressed time: TimeInterval, sampleRate: Double, isEnd: Bool) -> TimeInterval {
        guard let first = pieces.first, let last = pieces.last, sampleRate > 0 else { return time }
        let x = time * sampleRate
        if x <= Double(first.compressedStart) { return Double(first.originalStart) / sampleRate }
        let lastEnd = Double(last.compressedStart + last.length)
        if x >= lastEnd { return Double(last.originalStart + last.length) / sampleRate }
        // x を含む範囲（終わりの時刻は、つなぎ目ちょうどなら前の範囲に含める）
        var lo = 0
        var hi = pieces.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            let start = Double(pieces[mid].compressedStart)
            if isEnd ? start < x : start <= x { lo = mid } else { hi = mid - 1 }
        }
        let piece = pieces[lo]
        return (Double(piece.originalStart) + (x - Double(piece.compressedStart))) / sampleRate
    }

    /// 認識結果の区間の時刻（短くした音声の先頭からの秒）を、元の音声の先頭からの秒に戻す
    public func mapToOriginal(_ segments: [TranscriptSegment], sampleRate: Double) -> [TranscriptSegment] {
        segments.map { segment in
            var mapped = segment
            let start = originalTime(ofCompressed: segment.start, sampleRate: sampleRate, isEnd: false)
            let end = originalTime(ofCompressed: segment.end, sampleRate: sampleRate, isEnd: true)
            mapped.start = start
            mapped.end = max(end, start)
            return mapped
        }
    }
}

/// バッチ文字起こしで、長い無音を飛ばす（Silero VAD）ときの決まった値。
/// 文字起こしの精度を優先して選んだ値（README の「長い無音を飛ばす」の検証結果）。
public struct VoiceActivitySettings: Sendable, Equatable {
    /// 残す間の長さ（秒）。発話の前後にはこの半分ずつ、元の音声を残す。
    /// 1.5 秒・2.0 秒も試したが、精度は良くならず（短い発話や BGM のある音声で悪くなる場合があった）、速度は遅くなった。
    public var keptGap: TimeInterval
    /// 発話とみなす確率のしきい値（Silero VAD）。whisper.cpp の既定は 0.5 だが、雑音のある音声では
    /// 短い相づち（「はい」「うん」）を発話とみなさないことが多かった（2026-11 の検証で 176 発話中 27 を見落とし、
    /// 0.1 では 2）。ここでは「確実に発話のない部分」だけを飛ばしたいので、低くして発話を取りこぼさない方に寄せる。
    public var threshold: Float
    /// 発話とみなす最短の長さ（ミリ秒）。whisper.cpp の既定の 250ms では、0.1 秒の「えっ」を発話とみなさなかった。
    public var minSpeechMilliseconds: Int
    /// 短くする無音の最短の長さ（秒）。これより短い無音は、VAD が発話を見落としていても消えないよう、そのまま残す。
    public var minSkippedSilence: TimeInterval

    public init(keptGap: TimeInterval, threshold: Float, minSpeechMilliseconds: Int, minSkippedSilence: TimeInterval) {
        self.keptGap = keptGap
        self.threshold = threshold
        self.minSpeechMilliseconds = minSpeechMilliseconds
        self.minSkippedSilence = minSkippedSilence
    }

    public static let standard = VoiceActivitySettings(keptGap: 1.0, threshold: 0.1, minSpeechMilliseconds: 100,
                                                       minSkippedSilence: 5.0)
}
