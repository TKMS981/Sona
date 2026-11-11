import Foundation
import NaturalLanguage

/// AI が作った書き換えの候補を確かめる。守るべき語を変えた・原文にない内容を足した候補は使わない。
///
/// 守る語（どちらの書き換えでも、原文と同じものが同じ数だけ残っていること。書き換えに新しく現れないこと）:
/// - 数字（日付・時刻・金額・割合を含む。全角・半角は同じとみなす）と、漢数字の数量（「三百万円」「十五日」など）
/// - カタカナの語（製品名・人名・地名に多いため）
/// - 大文字を含む英字の語（文頭の語は除く。固有名詞・製品名）
/// - 敬称（さん・様・氏・社長など）の前の語（人名）
/// - 英語の人名・地名・組織名（NaturalLanguage の判定。日本語の漢字の人名・地名は判定できない）
///
/// さらに、文章の整形は「原文の語を削る・句読点を足すだけ」（原文の文字の並びの部分列であること）、
/// 誤認識の修正は「変更が小さいこと」（変えた文字が全体の 3 割以下）を求める。
public enum RewriteGuard {
    public enum Violation: Equatable, Sendable {
        /// 守る語が変わった・消えた
        case changedProtected(String)
        /// 原文にない語（数字・固有名詞など）が現れた
        case added(String)
        /// 整形で、原文にない文字・語が現れた（言い換え・追加）
        case notSubsequence
        /// 変更が大きすぎる
        case tooDifferent
        /// 空の返答
        case empty

        public var message: String {
            switch self {
            case .changedProtected(let s): L("guard.changedProtected", s)
            case .added(let s): L("guard.added", s)
            case .notSubsequence: L("guard.notSubsequence")
            case .tooDifferent: L("guard.tooDifferent")
            case .empty: L("guard.empty")
            }
        }
    }

    /// 書き換えを確かめる（問題がなければ空）
    public static func check(original: String, rewritten: String, task: AITask) -> [Violation] {
        let a = original.trimmingCharacters(in: .whitespacesAndNewlines)
        let b = rewritten.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !b.isEmpty else { return [.empty] }
        var violations: [Violation] = []
        let pa = protectedTokens(in: a), pb = protectedTokens(in: b)
        for (token, count) in pa where (pb[token] ?? 0) < count {
            violations.append(.changedProtected(token))
        }
        for (token, count) in pb where (pa[token] ?? 0) < count {
            violations.append(.added(token))
        }
        switch task {
        case .polish:
            if !isSubsequence(contentUnits(b), of: contentUnits(a)) { violations.append(.notSubsequence) }
        case .correction:
            let ua = contentUnits(a), ub = contentUnits(b)
            let changed = TextDiff.editDistance(ua, ub)
            if Double(changed) > max(3, Double(max(ua.count, 1)) * 0.3) { violations.append(.tooDifferent) }
        case .summary, .translation:
            break
        }
        return violations
    }

    // MARK: 守る語

    /// 守る語と、その数（全角の英数字は半角にそろえる）
    public static func protectedTokens(in text: String) -> [String: Int] {
        var counts: [String: Int] = [:]
        let normalized = halfwidthASCII(text)
        func add(_ s: some StringProtocol) { counts[String(s), default: 0] += 1 }
        let ns = normalized as NSString
        let range = NSRange(location: 0, length: ns.length)
        for regex in [numberRegex, kanjiNumberRegex, katakanaRegex, honorificNameRegex] {
            for m in regex.matches(in: normalized, range: range) {
                let r = m.numberOfRanges > 1 && m.range(at: 1).location != NSNotFound ? m.range(at: 1) : m.range
                add(ns.substring(with: r))
            }
        }
        for m in latinWordRegex.matches(in: normalized, range: range) {
            let word = ns.substring(with: m.range)
            guard word.contains(where: \.isUppercase) else { continue }
            // 文頭の語（大文字で始まるのは文法上の理由）と「I」は除く
            let before = ns.substring(to: m.range.location).trimmingCharacters(in: .whitespaces)
            let atSentenceStart = before.isEmpty || ".!?。！？".contains(before.last!)
            let onlyFirstUpper = word.dropFirst().allSatisfy { !$0.isUppercase }
            if word == "I" || (atSentenceStart && onlyFirstUpper) { continue }
            add(word)
        }
        // 英語の人名・地名・組織名（文頭でも守る）
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = normalized
        tagger.enumerateTags(in: normalized.startIndex ..< normalized.endIndex, unit: .word, scheme: .nameType,
                             options: [.omitWhitespace, .omitPunctuation, .joinNames]) { tag, r in
            if let tag, [.personalName, .placeName, .organizationName].contains(tag),
               normalized[r].allSatisfy({ $0.isASCII }) {
                let name = String(normalized[r])
                if counts[name] == nil { counts[name] = normalized.components(separatedBy: name).count - 1 }
            }
            return true
        }
        return counts
    }

    /// 全角の英数字・記号（U+FF01〜FF5E）だけを半角にする（カタカナや句読点は変えない）
    static func halfwidthASCII(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.map { scalar in
            (0xFF01 ... 0xFF5E).contains(scalar.value) ? Unicode.Scalar(scalar.value - 0xFEE0)! : scalar
        }))
    }

    static let numberRegex = try! NSRegularExpression(pattern: #"[0-9]+(?:[.,:/][0-9]+)*"#)
    /// 単位の付いた漢数字（「三百万円」「十五日」「二時」「三割」など）
    static let kanjiNumberRegex = try! NSRegularExpression(
        pattern: #"[〇一二三四五六七八九十百千万億兆]+(?=[円人日月年時分秒割個件回台名歳%％ドル])"#)
    static let katakanaRegex = try! NSRegularExpression(pattern: #"[ァ-ヴヵヶ][ァ-ヴヵヶー・]+"#)
    /// 敬称の前の語（人名）
    static let honorificNameRegex = try! NSRegularExpression(
        pattern: #"([一-龯々ァ-ヴーA-Za-z]{1,8})(?=さん|様|さま|氏|君|くん|ちゃん|先生|社長|部長|課長|教授)"#)
    static let latinWordRegex = try! NSRegularExpression(pattern: #"[A-Za-z][A-Za-z0-9\-.']*[A-Za-z0-9]|[A-Za-z]"#)

    // MARK: 比べる単位

    /// 比べる単位: 英語などは語（小文字）、日本語などは文字。句読点・空白・記号は除く。
    static func contentUnits(_ text: String) -> [String] {
        let spaced = text.contains(" ") && text.contains(where: { $0.isASCII && $0.isLetter })
        if spaced {
            return text.lowercased().split(whereSeparator: { $0.isWhitespace })
                .map { $0.filter { $0.isLetter || $0.isNumber } }
                .filter { !$0.isEmpty }
        }
        return text.filter { !$0.isWhitespace && !$0.isPunctuation && !$0.isSymbol }.map(String.init)
    }

    static func isSubsequence(_ small: [String], of large: [String]) -> Bool {
        var i = 0
        for unit in large where i < small.count && small[i] == unit { i += 1 }
        return i == small.count
    }
}

/// 文字（英語などは語）の単位の差分。書き換えの確認の表示と、変更の大きさの判定に使う。
public enum TextDiff {
    public struct Piece: Equatable, Sendable {
        public enum Kind: Sendable { case same, removed, added }
        public var kind: Kind
        public var text: String
    }

    /// 差分（同じ部分・消えた部分・増えた部分）。長すぎる文は全体の置き換えとして扱う。
    public static func diff(_ a: String, _ b: String) -> [Piece] {
        let spaced = (a + b).contains(" ") && (a + b).contains(where: { $0.isASCII && $0.isLetter })
        let ua = units(a, spaced: spaced), ub = units(b, spaced: spaced)
        guard ua.count * ub.count <= 1_000_000 else {
            return [Piece(kind: .removed, text: a), Piece(kind: .added, text: b)]
        }
        // 最長共通部分列
        let n = ua.count, m = ub.count
        var table = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                table[i][j] = ua[i] == ub[j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
            }
        }
        var pieces: [Piece] = []
        func push(_ kind: Piece.Kind, _ text: String) {
            if let last = pieces.last, last.kind == kind {
                pieces[pieces.count - 1].text += text
            } else {
                pieces.append(Piece(kind: kind, text: text))
            }
        }
        var i = 0, j = 0
        while i < n || j < m {
            if i < n, j < m, ua[i] == ub[j] {
                push(.same, ua[i]); i += 1; j += 1
            } else if i < n, j == m || table[i + 1][j] >= table[i][j + 1] {
                // 置き換えは「消えた部分 → 増えた部分」の順に並べる
                push(.removed, ua[i]); i += 1
            } else {
                push(.added, ub[j]); j += 1
            }
        }
        return pieces
    }

    /// 単位の並びの編集距離（置き換え・挿入・削除の数）
    public static func editDistance(_ a: [String], _ b: [String]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0 ... b.count)
        for (i, x) in a.enumerated() {
            var current = [i + 1]
            for (j, y) in b.enumerated() {
                current.append(min(previous[j + 1] + 1, current[j] + 1, previous[j] + (x == y ? 0 : 1)))
            }
            previous = current
        }
        return previous[b.count]
    }

    /// 文字単位（英語などは空白も含めて語単位）に分ける
    static func units(_ text: String, spaced: Bool) -> [String] {
        guard spaced else { return text.map(String.init) }
        var result: [String] = []
        var current = ""
        for c in text {
            if c.isWhitespace {
                if !current.isEmpty { result.append(current); current = "" }
                result.append(String(c))
            } else {
                current.append(c)
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }
}
