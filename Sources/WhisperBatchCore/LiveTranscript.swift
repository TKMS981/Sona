import Foundation

/// ライブ文字起こしの音声の入力
public enum LiveInputKind: String, CaseIterable, Sendable, Identifiable, Hashable {
    /// 利用者が選んだウィンドウ（macOS は、そのウィンドウを持つアプリ全体の音声を渡す）
    case window
    /// 画面全体（すべてのアプリの音声。このアプリ自身の音は除く）
    case system
    /// マイク
    case microphone

    public var id: String { rawValue }
}

/// どの入力を使うか。3 つは独立してオン・オフできる。マイクは初期状態でオフ。
public struct LiveSourceSelection: Equatable, Sendable {
    public var window: Bool
    public var system: Bool
    public var microphone: Bool

    public init(window: Bool = true, system: Bool = false, microphone: Bool = false) {
        self.window = window
        self.system = system
        self.microphone = microphone
    }

    public var isEmpty: Bool { !window && !system && !microphone }

    /// 実際に取り込む画面側の入力。システム音声にはウィンドウの音声も含まれるので、
    /// 両方オンのときはシステム音声だけを取り込む（同じ音を二重に混ぜない）。
    public var screenInput: LiveInputKind? {
        if system { return .system }
        if window { return .window }
        return nil
    }

    /// ウィンドウの音声がシステム音声に含まれる（両方オン）
    public var windowIsCoveredBySystem: Bool { window && system }
}

/// ライブ文字起こしの結果。確定した区間と、まだ書き換わる可能性のある暫定の区間を分けて持つ。
/// 時刻はセッション開始からの秒数（一時停止していた時間は含めない）。
public struct LiveTranscript: Equatable, Sendable {
    public private(set) var confirmed: [TranscriptSegment] = []
    public private(set) var provisional: [TranscriptSegment] = []
    /// 認識に使った（自動判定時は判定した）言語コード
    public var language: String?

    public init() {}

    /// 1 回の認識結果を反映する。暫定の区間は毎回まるごと置き換える。
    /// - Parameter windowStart: 認識した音声の先頭の、セッション開始からの秒数
    public mutating func apply(_ decision: LiveCommitPolicy.Decision, windowStart: TimeInterval) {
        // 1 つの区間に複数の文が入っていれば、文の終わりで行を分けて確定する（暫定の区間は分けない。
        // 次の認識結果と比べて同じかどうかを判定するのに使うため）
        for var segment in decision.confirmed.flatMap({ LiveText.splitSentences($0.shifted(by: windowStart)) }) {
            // 直前に確定した文と同じ文字で、時刻も重なっているものは、同じ音声を読み直した重複なので足さない
            // （時刻が重ならない同じ文は、繰り返し話された文として残す）
            let isDuplicate = confirmed.suffix(2).contains {
                segment.start < $0.end - 0.2 && LiveText.normalized($0.text) == LiveText.normalized(segment.text)
            }
            if isDuplicate { continue }
            // 直前に確定した文と時刻が重なって始まり、その終わりと同じ語で始まる場合は、重なった語を除く
            // （同じ音声の一部を読み直したもの。時刻が重ならない言い直しはそのまま残す）
            if let last = confirmed.last, segment.start < last.end - 0.05,
               let trimmed = LiveText.removingOverlap(of: last.text, from: segment.text) {
                if trimmed.isEmpty { continue }
                segment = TranscriptSegment(start: segment.start, end: segment.end, text: trimmed)
            }
            confirmed.append(segment)
        }
        provisional = decision.provisional.map { $0.shifted(by: windowStart) }
    }

    public mutating func clearProvisional() {
        provisional = []
    }

    public var isEmpty: Bool { confirmed.isEmpty && provisional.isEmpty }

    /// 保存・書き出し用（確定した区間だけ）
    public var transcript: Transcript { Transcript(segments: confirmed, language: language) }

    /// 確定した文章（1 区間 1 行）
    public var confirmedText: String {
        confirmed.map(\.text).joined(separator: "\n")
    }

    /// 暫定の文章（1 行にまとめる）
    public var provisionalText: String {
        provisional.map(\.text).joined(separator: " ")
    }
}

extension TranscriptSegment {
    public func shifted(by offset: TimeInterval) -> TranscriptSegment {
        TranscriptSegment(start: start + offset, end: end + offset, text: text)
    }
}

/// 逐次認識で、どこまでを確定させ、どこから先を暫定として次の認識で読み直すかを決める。
///
/// - 新しい音声が `step` 秒たまるごとに、確定していない音声（最大 `maxWindow` 秒）をまとめて認識し直す。
/// - `pauseToCommit` 秒以上の無音（話の切れ目）があれば、最も後ろの切れ目までの区間を確定する。
/// - 切れ目がなくても、続けて 2 回の認識で同じ結果になり、末尾から `agreementMargin` 秒以上前に終わっている
///   区間は確定する（音楽が流れ続けている・早口で間がない場合に、確定が遅れたり 1 回の認識が長くなったりしないため）。
/// - それでも区切れないまま `maxWindow` 秒に達したら、末尾付近で切れているかもしれない区間だけを暫定に残し、
///   それより前を確定する（`ChunkPlanner` と同じ考え方）。
/// - 次の認識の始まりは、区切りの近くで最も静かな位置に合わせる（語の途中で切って、頭の音を落とさないため）。
/// - 確定した分の音声は捨てるので、保持する音声は最大でも `hardLimit` 秒に収まる。
public struct LiveCommitPolicy: Sendable, Equatable {
    /// 新しい音声がこの秒数たまったら認識し直す
    public var step: TimeInterval
    /// 末尾の無音がこの秒数以上なら、話の切れ目として確定する
    public var pauseToCommit: TimeInterval
    /// 1 回に認識し直す音声の最大の長さ（秒）
    public var maxWindow: TimeInterval
    /// `maxWindow` に達したとき、末尾からこの秒数以内に終わる区間は暫定のまま残す
    public var tailMargin: TimeInterval
    /// 認識が追いつかないときに保持する音声の上限（秒）。超えた分は古い方から捨てる。
    public var hardLimit: TimeInterval
    /// 発話のない音声は、この秒数だけ残して捨てる（話し始めの直前を残すため）
    public var silenceKeep: TimeInterval
    /// 確定後に残す無音の長さ（秒）
    public var pauseKeep: TimeInterval
    /// 2 回続けて同じ結果になった区間を確定する（切れ目がない音声のため）
    public var commitsOnAgreement: Bool
    /// 一致による確定は、末尾からこの秒数以上前に終わっている区間だけにする（続きがありうるため）
    public var agreementMargin: TimeInterval

    public init(step: TimeInterval = 1.0, pauseToCommit: TimeInterval = 0.6, maxWindow: TimeInterval = 20,
                tailMargin: TimeInterval = 3, hardLimit: TimeInterval = 60, silenceKeep: TimeInterval = 1.0,
                pauseKeep: TimeInterval = 0.3, commitsOnAgreement: Bool = true, agreementMargin: TimeInterval = 2.0) {
        precondition(maxWindow > tailMargin && tailMargin >= 0 && step > 0 && hardLimit >= maxWindow)
        self.step = step
        self.pauseToCommit = pauseToCommit
        self.maxWindow = maxWindow
        self.tailMargin = tailMargin
        self.hardLimit = hardLimit
        self.silenceKeep = silenceKeep
        self.pauseKeep = pauseKeep
        self.commitsOnAgreement = commitsOnAgreement
        self.agreementMargin = agreementMargin
    }

    public struct Decision: Equatable, Sendable {
        /// 確定した理由（測定と調査用）
        public enum Reason: String, Sendable, CaseIterable {
            /// 確定なし
            case none
            /// 話の切れ目（無音）
            case pause
            /// 2 回続けて同じ結果
            case agreement
            /// 長さの上限（`maxWindow`）
            case forced
            /// 一時停止・終了
            case final
        }

        /// 確定する区間（時刻は認識した音声の先頭からの相対秒）
        public var confirmed: [TranscriptSegment]
        /// 暫定の区間（次の認識で書き換わることがある）
        public var provisional: [TranscriptSegment]
        /// 認識した音声の先頭から捨ててよい秒数
        public var advance: TimeInterval
        public var reason: Reason

        public init(confirmed: [TranscriptSegment], provisional: [TranscriptSegment], advance: TimeInterval,
                    reason: Reason = .none) {
            self.confirmed = confirmed
            self.provisional = provisional
            self.advance = advance
            self.reason = reason
        }
    }

    /// 発話のない音声をどこまで捨てるか（秒）
    public func silentAdvance(windowDuration: TimeInterval, isFinal: Bool) -> TimeInterval {
        isFinal ? windowDuration : max(windowDuration - silenceKeep, 0)
    }

    /// - Parameters:
    ///   - segments: 認識結果（時刻は認識した音声の先頭からの相対秒、昇順）
    ///   - windowDuration: 認識した音声の長さ（秒）
    ///   - pauses: 音声の中の無音の範囲（秒、昇順。末尾まで続く無音を含む）。話の切れ目の候補。
    ///   - silences: ほとんど音のない範囲。この中だけにある区間は、無音から作られた誤認識として捨てる。
    ///     nil なら `pauses` を使う。
    ///   - previous: 前回の認識の暫定の区間（時刻は今回の音声の先頭からの相対秒）
    ///   - gaps: 短い間（文と文・話者の間）。2 回一致による確定で、区間の境目に間があるかの判定に使う。nil なら `pauses`。
    ///   - quietest: 範囲の中で最も静かな位置を返す（区切りの位置を合わせる。nil なら合わせない）
    ///   - isFinal: 一時停止・終了の直前で、これ以上続きがない
    public func decide(segments: [TranscriptSegment], windowDuration: TimeInterval,
                       pauses: [ClosedRange<TimeInterval>], silences: [ClosedRange<TimeInterval>]? = nil,
                       previous: [TranscriptSegment] = [], gaps: [ClosedRange<TimeInterval>]? = nil,
                       quietest: ((ClosedRange<TimeInterval>) -> TimeInterval?)? = nil,
                       isFinal: Bool) -> Decision {
        // ほとんど音のない範囲の中だけにある区間は、Whisper が無音から作った文なので捨てる
        let dropZones = silences ?? pauses
        let segments = segments.filter { seg in
            !seg.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !dropZones.contains { seg.start >= $0.lowerBound - 0.05 && seg.end <= $0.upperBound + 0.05 }
        }
        if isFinal {
            return Decision(confirmed: segments, provisional: [], advance: windowDuration, reason: .final)
        }
        if let decision = commitAtPause(segments, windowDuration: windowDuration, pauses: pauses) {
            return decision
        }
        if commitsOnAgreement,
           let decision = commitAgreed(segments, windowDuration: windowDuration, previous: previous,
                                       pauses: gaps ?? pauses, quietest: quietest) {
            return decision
        }
        // 区切れないまま長くなった。末尾付近で切れているかもしれない区間は残して先へ進む。
        if windowDuration >= maxWindow {
            let planner = ChunkPlanner(chunkDuration: maxWindow, tailMargin: tailMargin, minimumAdvance: maxWindow / 4)
            let plan = planner.decide(segments: segments, bufferDuration: windowDuration, isFinal: false)
            let provisional = Array(segments.dropFirst(plan.accepted.count))
            var advance = plan.resumeAt
            // 次の区間の始まりで切るときは、その手前の静かな位置に合わせる（次の区間の頭を落とさない）
            if let last = plan.accepted.last, let next = provisional.first, abs(next.start - advance) < 0.01,
               let snapped = Self.snap(quietest, lower: max(last.end - 0.15, advance - 0.4), upper: advance) {
                advance = snapped
            }
            return Decision(confirmed: plan.accepted, provisional: provisional, advance: max(advance, 0),
                            reason: plan.accepted.isEmpty ? .none : .forced)
        }
        return Decision(confirmed: [], provisional: segments, advance: 0)
    }

    /// 最も後ろにある話の切れ目で区切る。切れ目（無音）が始まる前に話し始めた区間を確定し、
    /// 無音の中や後ろから始まる区間は暫定に残して、その音声を次の認識で読み直す
    /// （Whisper は切れ目の直後の語の開始時刻を無音の中に置くことがあり、確定すると二重に出るため）。
    /// 区間が切れ目をまたいでいる（Whisper が前後の文を 1 つにまとめた）場合は、そこでは区切らない。
    private func commitAtPause(_ segments: [TranscriptSegment], windowDuration: TimeInterval,
                               pauses: [ClosedRange<TimeInterval>]) -> Decision? {
        let tolerance = 0.2
        for pause in pauses.reversed() where pause.upperBound - pause.lowerBound >= pauseToCommit {
            let isTrailing = pause.upperBound >= windowDuration - 0.05
            let straddles = segments.contains {
                $0.start < pause.lowerBound - tolerance && $0.end > pause.upperBound + tolerance
            }
            if straddles { continue }
            // 切れ目より前に始まっていても、時刻の範囲の半分以上が切れ目より後ろにある区間は、音声の大半が切れ目の後ろにある
            // （Whisper が開始時刻を早めに置いた）ので確定せず、次の認識で読み直す。
            // 終わりの時刻が無音の中へ少し延びただけの普通の文は、半分以上が前にあるので確定する。
            let split = segments.firstIndex { seg in
                seg.start >= pause.lowerBound
                    || (seg.end > pause.upperBound && (pause.lowerBound - seg.start) < (seg.end - seg.start) / 2)
            } ?? segments.count
            var cut = isTrailing
                ? max(windowDuration - min((pause.upperBound - pause.lowerBound) / 2, pauseKeep), 0)
                : (pause.lowerBound + pause.upperBound) / 2
            // 暫定に残す区間の音声は捨てない（周りより静かなだけで、小さな声や歌が続いていることがある）
            if split < segments.count {
                let next = segments[split]
                // 切れ目の前から始まる区間を読み直すときは、その区間の頭まで残す
                cut = min(cut, next.start >= pause.lowerBound ? max(next.start - 0.1, pause.lowerBound) : max(next.start - 0.1, 0))
            }
            // 確定するものがなく、先へも進めないなら、この切れ目では区切らない
            if split == 0, cut < 0.05 { continue }
            return Decision(confirmed: Array(segments[..<split]), provisional: Array(segments[split...]), advance: cut,
                            reason: split > 0 ? .pause : .none)
        }
        return nil
    }

    /// 前回と今回の認識で、先頭から同じ結果になった区間を確定する。
    /// ただし確定するのは、文の終わりの記号で終わる区間か、次の区間との境目に短い間（周りより静かな部分）が
    /// ある区間まで。Whisper は文の途中で区間を区切り、続きを推測で補うことがあり、
    /// その区切りが 2 回続けて同じになることもあるため（途中で確定すると、語の重複や補った語が残る）。
    private func commitAgreed(_ segments: [TranscriptSegment], windowDuration: TimeInterval,
                              previous: [TranscriptSegment], pauses: [ClosedRange<TimeInterval>],
                              quietest: ((ClosedRange<TimeInterval>) -> TimeInterval?)?) -> Decision? {
        var agreed = 0
        while agreed < segments.count, agreed < previous.count, Self.agrees(segments[agreed], previous[agreed]),
              segments[agreed].end <= windowDuration - agreementMargin {
            agreed += 1
        }
        var n = agreed
        while n > 0, !Self.endsCleanly(segments[n - 1], next: n < segments.count ? segments[n] : nil, pauses: pauses) {
            n -= 1
        }
        guard n > 0 else { return nil }
        let lastEnd = segments[n - 1].end
        let next = n < segments.count ? segments[n].start : nil
        // 次の区間の始まりが確定する区間の終わりより大きく前にある（時刻が当てにならない）ときは確定しない。
        // そこで区切ると、確定した文の音声をもう一度読み直して重複させてしまうため。
        if let next, next < lastEnd - 0.3 { return nil }
        // 確定した区間の終わりから、次の区間の始まり（なければ 0.5 秒後）までで最も静かな位置で区切る
        let upper = min(next ?? (lastEnd + 0.5), windowDuration)
        let lower = min(lastEnd - 0.15, upper)
        var cut = Self.snap(quietest, lower: max(lower, segments[n - 1].start), upper: upper) ?? (next ?? lastEnd)
        if let next { cut = min(cut, next) }
        cut = max(cut, lastEnd - 0.3)
        return Decision(confirmed: Array(segments[..<n]), provisional: Array(segments[n...]), advance: max(cut, 0),
                        reason: .agreement)
    }

    /// 区間がそこで終わったとみなせるか（文の終わりの記号で終わる、または次の区間との境目に間がある）
    static func endsCleanly(_ segment: TranscriptSegment, next: TranscriptSegment?,
                            pauses: [ClosedRange<TimeInterval>]) -> Bool {
        let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let last = text.last, "。．.？?！!」』".contains(last) { return true }
        let gapStart = segment.end - 0.2
        let gapEnd = max(next?.start ?? segment.end, segment.end) + 0.2
        return pauses.contains { $0.lowerBound < gapEnd && $0.upperBound > gapStart }
    }

    /// 同じ区間とみなせるか（文字が同じで、時刻のずれが小さい）
    static func agrees(_ a: TranscriptSegment, _ b: TranscriptSegment) -> Bool {
        abs(a.start - b.start) <= 0.6 && abs(a.end - b.end) <= 0.6
            && LiveText.normalized(a.text) == LiveText.normalized(b.text) && !LiveText.normalized(a.text).isEmpty
    }

    private static func snap(_ quietest: ((ClosedRange<TimeInterval>) -> TimeInterval?)?,
                             lower: TimeInterval, upper: TimeInterval) -> TimeInterval? {
        guard let quietest, upper > lower else { return nil }
        let range = max(lower, 0) ... upper
        return quietest(range).map { min(max($0, range.lowerBound), range.upperBound) }
    }
}

/// 認識結果の文字列の扱い
public enum LiveText {
    /// 比べるための形（空白と句読点・記号を除き、小文字にする）
    public static func normalized(_ text: String) -> String {
        let drop = CharacterSet.punctuationCharacters.union(.symbols).union(.whitespacesAndNewlines)
        return String(String.UnicodeScalarView(text.lowercased().unicodeScalars.filter { !drop.contains($0) }))
    }

    /// 1 つの区間に複数の文が入っているとき、文の終わり（「。」「？」「！」、英語などの「. 」「? 」「! 」）で分ける。
    /// 時刻は文字数で按分する（目安）。分けた後の文が 2 文字未満になる位置では分けない。
    public static func splitSentences(_ segment: TranscriptSegment) -> [TranscriptSegment] {
        let chars = Array(segment.text)
        var pieces: [String] = []
        var current = ""
        for (i, c) in chars.enumerated() {
            current.append(c)
            let next: Character? = i + 1 < chars.count ? chars[i + 1] : nil
            // 「！？」や閉じかっこが続くときは、その後ろで分ける
            let closesMore = next.map { "。？！?!」』）)".contains($0) } ?? false
            // 半角の「?」「!」「.」は、後ろが空白か日本語などの文字のときだけ文の終わりとみなす（小数点や略語を除く）
            let nextIsWide = next.map { !$0.isASCII && !closesMore } ?? false
            let ends = ("。？！".contains(c) && !closesMore)
                || ("?!.".contains(c) && ((next?.isWhitespace ?? false) || nextIsWide))
            if ends, i + 1 < chars.count {
                let rest = String(chars[(i + 1)...])
                if visibleCount(current) >= 2, visibleCount(rest) >= 2 {
                    pieces.append(current)
                    current = ""
                }
            }
        }
        pieces.append(current)
        let texts = pieces.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard texts.count > 1 else { return [segment] }
        let total = Double(texts.map(visibleCount).reduce(0, +))
        let duration = segment.end - segment.start
        var start = segment.start
        var result: [TranscriptSegment] = []
        for (i, text) in texts.enumerated() {
            let end = i == texts.count - 1 ? segment.end : start + duration * Double(visibleCount(text)) / total
            result.append(TranscriptSegment(start: start, end: end, text: text))
            start = end
        }
        return result
    }

    private static func visibleCount(_ text: String) -> Int {
        text.filter { !$0.isWhitespace && !$0.isPunctuation }.count
    }

    /// `next` の頭が `previous` の終わりと同じ語なら、その部分を除いた文字を返す。重なりがなければ nil。
    /// 英語などの空白で区切る文は単語単位（1 語以上）、日本語などは文字単位（比べるための形で 2 文字以上）で比べる
    /// （単語の一部だけが一致したものを除かないため）。
    public static func removingOverlap(of previous: String, from next: String) -> String? {
        let spaced = next.contains(" ") && next.contains(where: { $0.isASCII && $0.isLetter })
        if spaced {
            let a = previous.split(separator: " ").map { normalized(String($0)) }.filter { !$0.isEmpty }
            let words = next.split(separator: " ")
            let b = words.map { normalized(String($0)) }
            var k = min(a.count, b.count)
            while k >= 1, Array(a.suffix(k)) != Array(b.prefix(k)) { k -= 1 }
            guard k >= 1 else { return nil }
            return words.dropFirst(k).joined(separator: " ")
        }
        let a = Array(normalized(previous)), b = Array(normalized(next))
        var k = min(a.count, b.count)
        while k >= 2, Array(a.suffix(k)) != Array(b.prefix(k)) { k -= 1 }
        guard k >= 2 else { return nil }
        // 元の文字（句読点や空白を含む）から、比べるための形で k 文字分を頭から除く
        var remaining = k
        var index = next.startIndex
        while index < next.endIndex, remaining > 0 {
            if !normalized(String(next[index])).isEmpty { remaining -= 1 }
            index = next.index(after: index)
        }
        return String(next[index...].drop { $0.isWhitespace || $0.isPunctuation })
    }

    /// 同じ並び（1〜10 文字）が 4 回以上続く部分がある（Whisper が同じ語を繰り返し続ける誤りの兆候）
    public static func hasRunawayRepetition(_ text: String, minRepeats: Int = 4) -> Bool {
        let chars = Array(normalized(text))
        guard chars.count >= minRepeats else { return false }
        for unit in 1 ... 10 {
            // 1 文字の繰り返し（「0000」や「ーー」など）は普通の文にもあるので、6 回以上を兆候とする
            let needed = unit == 1 ? max(minRepeats, 6) : minRepeats
            guard unit * needed <= chars.count else { continue }
            var run = 1
            var i = unit
            while i + unit <= chars.count {
                if chars[i ..< i + unit] == chars[i - unit ..< i] {
                    run += 1
                    if run >= needed { return true }
                    i += unit
                } else {
                    run = 1
                    i += 1
                }
            }
        }
        return false
    }
}

/// Whisper に渡す手がかりの文（初期プロンプト）を作る。
///
/// - 利用者が入力した語彙のヒント（固有名詞・専門用語など）を、長さに上限を設けて渡す。
/// - 直前に確定した文を手がかりに足すこともできるが、既定では使わない。合成音声での測定で、精度は上がらず、
///   Whisper が複数の文を 1 区間にまとめたり、区間の終わりで続きを推測して補ったりすることが増えたため
///   （README の「認識の精度について」）。使う場合も暫定の文は使わず、繰り返しの兆候があるとき・
///   時間が空いたときは使わない（前の誤認識を手がかりにして同じ誤りを繰り返し続けないため）。
public struct LivePromptBuilder: Sendable, Equatable {
    /// 語彙のヒントの最大文字数
    public static let hintLimit = 100
    /// 直前の文の最大文字数
    public var contextLimit: Int
    /// 直前の文として使うのは、認識する音声の始まりからこの秒数以内に終わった区間だけ
    public var contextMaxAge: TimeInterval
    /// 直前の文を手がかりにする（既定はしない）
    public var usesContext: Bool

    public init(contextLimit: Int = 60, contextMaxAge: TimeInterval = 20, usesContext: Bool = false) {
        self.contextLimit = contextLimit
        self.contextMaxAge = contextMaxAge
        self.usesContext = usesContext
    }

    /// 入力されたヒントを整える（改行や連続した空白を 1 つの空白にし、上限の文字数で切る）
    public static func sanitizedHint(_ hint: String) -> String {
        let collapsed = hint.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        return String(collapsed.prefix(hintLimit))
    }

    /// Whisper がヒントを丸写ししただけの区間か（文字がヒント全体と同じで、ヒントが 2 語以上）。
    /// 音声が聞き取りにくいとき、Whisper は渡された手がかりの文をそのまま出すことがあるため、その区間は捨てる。
    /// 1 語だけのヒントと同じ区間は、実際にその語だけが話されたこともありうるので捨てない。
    public static func isHintEcho(_ text: String, hint: String) -> Bool {
        let hint = sanitizedHint(hint)
        // 語の区切りは読点・カンマなど。英字を含まないヒント（日本語など）は空白でも区切る
        // （英語の「Northwind Labs」のような 1 語の中の空白では区切らない）
        var terms = hint.split(whereSeparator: { "、,，;；/／".contains($0) })
        if terms.count < 2, !hint.contains(where: { $0.isASCII && $0.isLetter }) {
            terms = hint.split(separator: " ")
        }
        guard terms.filter({ !$0.trimmingCharacters(in: .whitespaces).isEmpty }).count >= 2 else { return false }
        let normalized = LiveText.normalized(text)
        return !normalized.isEmpty && normalized == LiveText.normalized(hint)
    }

    /// - Parameters:
    ///   - hint: 利用者が入力した語彙のヒント
    ///   - confirmed: 確定した区間（時刻はセッションの開始からの秒数）
    ///   - windowStart: これから認識する音声の始まり（セッションの開始からの秒数）
    /// - Returns: 手がかりがなければ nil
    public func prompt(hint: String, confirmed: [TranscriptSegment], windowStart: TimeInterval) -> String? {
        var parts: [String] = []
        let hint = Self.sanitizedHint(hint)
        if !hint.isEmpty { parts.append(hint) }
        if usesContext, let context = context(confirmed, windowStart: windowStart) { parts.append(context) }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    func context(_ confirmed: [TranscriptSegment], windowStart: TimeInterval) -> String? {
        guard contextLimit > 0, let last = confirmed.last, windowStart - last.end <= contextMaxAge else { return nil }
        var picked: [String] = []
        var length = 0
        var previousText: String?
        for seg in confirmed.reversed() {
            guard windowStart - seg.end <= contextMaxAge else { break }
            let text = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty { continue }
            // 繰り返しの兆候があれば、直前の文は使わない
            if LiveText.hasRunawayRepetition(text) { return nil }
            if let previousText, LiveText.normalized(previousText) == LiveText.normalized(text) { return nil }
            previousText = text
            if length + text.count > contextLimit {
                if picked.isEmpty { picked.append(String(text.suffix(contextLimit))) }
                break
            }
            picked.append(text)
            length += text.count
        }
        let joined = picked.reversed().joined(separator: " ")
        return joined.isEmpty ? nil : joined
    }
}

/// 確定していない音声を保持する、長さに上限のあるバッファ。
///
/// 位置はセッション開始からのサンプル数（タイムライン）で表す。一時停止していた時間は含めない。
public struct LiveAudioWindow: Sendable {
    public let sampleRate: Double
    /// 保持する最大のサンプル数
    public let capacity: Int
    /// 保持しているサンプル。先頭はタイムラインの `startFrame` の位置。
    public private(set) var samples: [Float] = []
    public private(set) var startFrame = 0
    /// 上限を超えて捨てたサンプルの合計
    public private(set) var droppedFrames = 0

    public init(sampleRate: Double, capacity: TimeInterval) {
        precondition(capacity > 0)
        self.sampleRate = sampleRate
        self.capacity = Int(capacity * sampleRate)
    }

    public var endFrame: Int { startFrame + samples.count }
    public var duration: TimeInterval { Double(samples.count) / sampleRate }
    public var startTime: TimeInterval { Double(startFrame) / sampleRate }
    public var endTime: TimeInterval { Double(endFrame) / sampleRate }

    /// 末尾に足す。上限を超えたら古い方から捨て、捨てたサンプル数を返す。
    @discardableResult
    public mutating func append(_ new: [Float]) -> Int {
        samples.append(contentsOf: new)
        let over = samples.count - capacity
        guard over > 0 else { return 0 }
        samples.removeFirst(over)
        startFrame += over
        droppedFrames += over
        return over
    }

    /// タイムラインの `frame` より前を捨てる（既に捨てた位置なら何もしない）
    public mutating func discard(before frame: Int) {
        let n = min(max(frame - startFrame, 0), samples.count)
        guard n > 0 else { return }
        samples.removeFirst(n)
        startFrame += n
    }

    /// 保持している音声をすべて捨てる（一時停止・終了で確定し終えたとき）
    public mutating func discardAll() {
        startFrame = endFrame
        samples.removeAll()
    }
}
