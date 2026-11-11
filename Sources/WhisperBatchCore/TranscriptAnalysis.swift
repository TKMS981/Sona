import Foundation
import NaturalLanguage

/// 要約・重要な発言を作った方法
public enum AnalysisMethod: String, Codable, Sendable, CaseIterable, Identifiable {
    /// この Mac のオンデバイスの言語モデル（Apple Intelligence）
    case onDeviceAI
    /// この Mac に取得したローカルの言語モデル
    case localModel
    /// 文字起こしの文の中から選ぶ簡易抽出（AI は使わない）
    case extractive

    public var id: String { rawValue }
    public var displayName: String { L("analysis.method.\(rawValue)") }
}

/// 重要な発言として選んだ理由（簡易抽出では手がかりになった語の種類。AI では AI が答えた理由の種類）
public enum KeyPointReason: String, Codable, Sendable, CaseIterable {
    case decision
    case request
    case deadline
    case number
    case issue
    case emphasis
    /// 話題の中心になる語を多く含む
    case central

    public var displayName: String { L("keyPoint.reason.\(rawValue)") }
}

/// 重要な発言 1 つ。文字は文字起こしの文そのまま（言い換えない）。
public struct KeyPoint: Equatable, Sendable, Codable {
    public var text: String
    public var start: TimeInterval?
    public var speaker: Int?
    public var reasons: [KeyPointReason]

    public init(text: String, start: TimeInterval?, speaker: Int?, reasons: [KeyPointReason]) {
        self.text = text
        self.start = start
        self.speaker = speaker
        self.reasons = reasons
    }
}

/// 要約と重要な発言
public struct TranscriptAnalysis: Equatable, Sendable {
    /// 要約（1 行 1 項目）
    public var summary: [String] = []
    public var summaryMethod: AnalysisMethod?
    /// 要約に使ったもの（モデル名など。書き出しの「作成」の表示に使う）
    public var summaryEngine: String?
    public var keyPoints: [KeyPoint] = []
    public var keyPointsMethod: AnalysisMethod?
    public var keyPointsEngine: String?
    /// 翻訳（原文は変えない。訳した先の言語コードと訳文）
    public var translationLanguage: String?
    public var translation: [String] = []
    public var translationEngine: String?

    public init() {}

    public var isEmpty: Bool { summary.isEmpty && keyPoints.isEmpty && translation.isEmpty }
}

/// 文字起こしの文を、話題の中心になる語を多く含む順に評価する（AI を使わない簡易抽出の土台）。
///
/// 語の重みは「いくつの文に出てくるか」から決める（2 つ以上の文に出てくる語を話題の語とみなす）。
/// 日本語はひらがなだけの語（助詞・助動詞・相づちなど）、英語はよく使う機能語を数えない。
public struct SentenceScorer: Sendable {
    public struct Sentence: Equatable, Sendable {
        public var text: String
        public var start: TimeInterval
        public var speaker: Int?
        /// 元の区間の番号
        public var segmentIndex: Int
        public var score: Double
    }

    public let sentences: [Sentence]

    public init(segments: [TranscriptSegment], language: String?) {
        // 区間を文に分け、フィラーを除いた文で評価する
        var raw: [(text: String, start: TimeInterval, speaker: Int?, index: Int)] = []
        for (i, segment) in segments.enumerated() {
            for piece in LiveText.splitSentences(segment) {
                let text = FillerRemover.remove(from: piece.text)
                if !text.isEmpty { raw.append((text, piece.start, piece.speaker, i)) }
            }
        }
        let termSets = raw.map { Set(Self.terms(in: $0.text, language: language)) }
        var documentFrequency: [String: Int] = [:]
        for set in termSets { for term in set { documentFrequency[term, default: 0] += 1 } }
        sentences = zip(raw, termSets).map { item, terms in
            let weight = terms.reduce(0.0) { sum, term in
                let df = documentFrequency[term] ?? 0
                return sum + (df >= 2 ? log(1 + Double(df)) : 0)
            }
            let visible = item.text.filter { !$0.isWhitespace && !$0.isPunctuation }.count
            // 短すぎる文（相づちなど）は選ばれにくくする
            let lengthFactor = visible < 8 ? 0.3 : 1.0
            let score = weight / sqrt(Double(terms.count) + 1) * lengthFactor
            return Sentence(text: item.text, start: item.start, speaker: item.speaker, segmentIndex: item.index, score: score)
        }
    }

    /// 内容を表す語（小文字）
    static func terms(in text: String, language: String?) -> [String] {
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        if let language { tokenizer.setLanguage(NLLanguage(rawValue: language)) }
        var result: [String] = []
        tokenizer.enumerateTokens(in: text.startIndex ..< text.endIndex) { range, _ in
            let token = text[range].lowercased()
            if Self.isContentWord(token) { result.append(token) }
            return true
        }
        return result
    }

    static func isContentWord(_ token: String) -> Bool {
        let scalars = token.unicodeScalars
        guard !scalars.isEmpty else { return false }
        // 数字や記号だけの語は数えない
        if scalars.allSatisfy({ CharacterSet.decimalDigits.contains($0) || CharacterSet.punctuationCharacters.contains($0)
            || CharacterSet.symbols.contains($0) }) { return false }
        // ひらがなだけの語（助詞・助動詞・相づちなど）
        if scalars.allSatisfy({ (0x3040 ... 0x309F).contains($0.value) || $0.value == 0x30FC }) { return false }
        let isASCII = scalars.allSatisfy(\.isASCII)
        if isASCII {
            return token.count >= 3 && !englishStopWords.contains(token)
        }
        return true
    }

    static let englishStopWords: Set<String> = [
        "the", "and", "for", "are", "but", "not", "you", "all", "any", "can", "had", "her", "was", "one", "our", "out",
        "has", "have", "him", "his", "how", "its", "may", "who", "did", "get", "got", "she", "too", "use", "that",
        "this", "with", "from", "they", "them", "then", "than", "there", "their", "what", "when", "where", "which",
        "will", "would", "could", "should", "about", "into", "just", "like", "also", "been", "were", "your", "yours",
        "very", "some", "more", "most", "such", "only", "over", "much", "well", "yeah", "okay", "really", "actually",
        "going", "know", "think", "thing", "things", "lot", "let", "say", "said", "because", "these", "those", "here",
        "being", "does", "doing", "done", "each", "other", "after", "before", "again", "right", "now", "gonna", "want",
    ]
}

/// AI を使わない要約。話題の中心になる語を多く含む文を、元の順序のまま選ぶ（文は言い換えない）。
public enum ExtractiveSummarizer {
    /// - Returns: 選んだ文（時刻順）
    public static func summarize(_ transcript: Transcript, maxSentences: Int? = nil) -> [SentenceScorer.Sentence] {
        let scorer = SentenceScorer(segments: transcript.segments, language: transcript.language)
        let all = scorer.sentences
        guard !all.isEmpty else { return [] }
        let limit = maxSentences ?? min(max(Int((Double(all.count) * 0.15).rounded()), 3), 8)
        if all.count <= limit { return all }
        var chosen: [SentenceScorer.Sentence] = []
        for sentence in all.enumerated().sorted(by: { ($0.element.score, -$0.offset) > ($1.element.score, -$1.offset) }).map(\.element) {
            if chosen.count >= limit { break }
            let key = LiveText.normalized(sentence.text)
            if key.isEmpty || chosen.contains(where: { LiveText.normalized($0.text) == key }) { continue }
            chosen.append(sentence)
        }
        return chosen.sorted { ($0.start, $0.segmentIndex) < ($1.start, $1.segmentIndex) }
    }
}

/// AI を使わない重要な発言の抽出。決定・依頼・期限・数値・課題・強調を表す語を手がかりに選び、
/// 手がかりがない場合は話題の中心になる文を選ぶ。文は文字起こしのまま使う。
public enum KeyStatementExtractor {
    static let patterns: [(KeyPointReason, NSRegularExpression)] = [
        (.decision, try! NSRegularExpression(pattern: #"決定|決め|決まり|決まっ|合意|結論|方針|採用|確定|ことにしま|ことにな|(?i:\bdecid|\bagree|\bconclu|\bsettled\b|\bwe(?:'ll| will) go with)"#)),
        (.request, try! NSRegularExpression(pattern: #"お願い|ください|下さい|してほしい|して欲しい|頼み|依頼|担当|宿題|(?i:\bplease\b|\bcould you\b|\bcan you\b|\bwould you\b|\baction items?\b|\bassign)"#)),
        (.deadline, try! NSRegularExpression(pattern: #"までに|締め切り|締切|期限|納期|今日中|明日まで|来週まで|月末|[0-9０-９]+月[0-9０-９]+日|(?i:\bdeadline\b|\bdue\b|\bby (?:monday|tuesday|wednesday|thursday|friday|saturday|sunday|tomorrow|next week|the end of))"#)),
        (.number, try! NSRegularExpression(pattern: #"[0-9０-９]+(?:[.,][0-9]+)?\s*(?:円|%|％|件|人|名|時|分|秒|万|億|個|台|回|割|ドル|年|ヶ月|か月|日|(?i:dollars?|percent|people|hours?|minutes?|days?|weeks?|months?|years?|million|billion|thousand))"#)),
        (.issue, try! NSRegularExpression(pattern: #"問題|課題|懸念|リスク|困って|不具合|障害|遅れ|遅延|(?i:\bissues?\b|\bproblems?\b|\brisks?\b|\bconcerns?\b|\bblockers?\b|\bbugs?\b)"#)),
        (.emphasis, try! NSRegularExpression(pattern: #"重要|大事|大切|ポイント|必ず|絶対|注意|(?i:\bimportant\b|\bcritical\b|\bkey point|\bmust\b|\bneed to\b)"#)),
    ]

    /// 手がかりにしない決まり文句（あいさつの「よろしくお願いします」は依頼ではない）
    static let setPhrases = ["よろしくお願いいたします", "よろしくお願い致します", "よろしくお願いします", "宜しくお願いします",
                             "お願いいたします", "お願いします"]

    /// 文の中の手がかり（重複なし、定義順）
    public static func reasons(in text: String) -> [KeyPointReason] {
        // 決まり文句だけの文（「はい、よろしくお願いします。」など）は依頼とみなさない。
        // 「資料をお願いします」のように前に内容がある文は、依頼として残す。
        var text = text
        let core = text.filter { !$0.isWhitespace && !$0.isPunctuation }
        for phrase in setPhrases where core.hasSuffix(phrase) {
            let rest = core.dropLast(phrase.count)
            if rest.isEmpty || ["はい", "では", "それでは", "じゃあ", "本日は", "今日は", "どうぞ"].contains(String(rest)) {
                text = String(rest)
            }
            break
        }
        let range = NSRange(text.startIndex..., in: text)
        return patterns.compactMap { reason, regex in regex.firstMatch(in: text, range: range) != nil ? reason : nil }
    }

    public static func extract(_ transcript: Transcript, maxCount: Int? = nil) -> [KeyPoint] {
        let sentences = SentenceScorer(segments: transcript.segments, language: transcript.language).sentences
        guard !sentences.isEmpty else { return [] }
        let limit = maxCount ?? min(max(Int((Double(sentences.count) * 0.1).rounded()), 3), 10)
        let maxScore = max(sentences.map(\.score).max() ?? 0, 0.0001)
        let scored = sentences.enumerated().map { offset, sentence -> (offset: Int, sentence: SentenceScorer.Sentence, reasons: [KeyPointReason], score: Double) in
            let found = reasons(in: sentence.text)
            let visible = sentence.text.filter { !$0.isWhitespace && !$0.isPunctuation }.count
            // 短すぎる文は手がかりがあっても選ばない（「お願いします」だけの文など）
            let usable = visible >= 6
            let score = usable ? Double(found.count) * 2 + sentence.score / maxScore : -1
            return (offset, sentence, usable ? found : [], score)
        }
        var cued = scored.filter { !$0.reasons.isEmpty }
        if cued.isEmpty {
            cued = scored.filter { $0.score >= 0 }.map { ($0.offset, $0.sentence, [KeyPointReason.central], $0.score) }
        }
        var chosen: [(offset: Int, sentence: SentenceScorer.Sentence, reasons: [KeyPointReason], score: Double)] = []
        for item in cued.sorted(by: { ($0.score, -$0.offset) > ($1.score, -$1.offset) }) {
            if chosen.count >= limit { break }
            let key = LiveText.normalized(item.sentence.text)
            if chosen.contains(where: { LiveText.normalized($0.sentence.text) == key }) { continue }
            chosen.append(item)
        }
        return chosen.sorted { $0.offset < $1.offset }.map {
            KeyPoint(text: $0.sentence.text, start: $0.sentence.start, speaker: $0.sentence.speaker, reasons: $0.reasons)
        }
    }
}
