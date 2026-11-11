import Foundation

/// フィラー（「えー」「あのー」「um」など）を取り除く。
///
/// 意味のある語を消さないよう、控えめな規則にしている。
/// - 日本語: 「えー」「えーと」「えっと」「うーん」などは、文の頭・句読点・空白の後にあるときだけ消す。
///   「あの」「その」「まあ」は、後ろに「ー」「、」「,」・空白が続くときだけ消す（「あの人」「その件」は残す）。
/// - 英語: 単語として独立した「um」「uh」「erm」「hmm」などを消す（「like」「you know」は意味を持つことが多いので消さない）。
/// - 利用者が追加した語は、前後が区切り（文の頭・句読点・空白・文の終わり）のときだけ消す。
public enum FillerRemover {
    /// 単独で消す日本語のフィラー（長いものから順に試す）
    static let japaneseFillers = [
        "えーっと", "ええっと", "えーとー", "えーと", "ええと", "えっと", "えーー", "ええー", "えー",
        "うーんと", "うーん", "うーむ", "んーと", "んー", "あーー", "あー", "あのー", "あのう", "そのー", "まあー", "まぁー",
    ]
    /// 後ろに区切りがあるときだけ消す日本語の語
    static let japaneseConditionalFillers = ["あの", "その", "まあ", "まぁ", "なんか", "えと"]
    static let englishFillers = ["um", "umm", "uh", "uhh", "uhm", "erm", "er", "hmm", "hm", "mm"]

    /// 区切りとみなす文字
    static let boundary: Set<Character> = ["、", "。", "，", "．", ",", ".", "!", "?", "！", "？", " ", "　", "「", "」", "…", "・"]

    /// フィラーを取り除いた文字。取り除いた結果、区切りが重なったり文頭に残ったりしたものも整える。
    /// - Parameter extra: 利用者が追加したフィラー（前後が区切りのときだけ消す）
    public static func remove(from text: String, extra: [String] = []) -> String {
        var result = removeJapanese(from: text, extra: extra)
        result = removeEnglish(from: result)
        return tidy(result, original: text)
    }

    /// 区間ごとの変更の候補（変わらない区間は含めない）
    public struct Change: Equatable, Sendable {
        public var index: Int
        public var before: String
        public var after: String
    }

    /// 文字起こし全体で、フィラーを除くと変わる区間を挙げる。削除済みの区間は対象にしない。
    public static func changes(in original: Transcript, edits: TranscriptEdits, extra: [String] = []) -> [Change] {
        original.segments.indices.compactMap { i in
            guard let current = edits.text(at: i, in: original) else { return nil }
            let after = remove(from: current, extra: extra)
            return after == current ? nil : Change(index: i, before: current, after: after)
        }
    }

    /// 利用者が追加する語を整える（空白で区切った語・重複を除く・長さの上限）
    public static func parseExtra(_ text: String) -> [String] {
        var seen = Set<String>()
        return text.components(separatedBy: CharacterSet(charactersIn: ",、\n").union(.whitespaces))
            .map { String($0.trimmingCharacters(in: .whitespaces).prefix(20)) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
            .prefix(50)
            .map { $0 }
    }

    // MARK: private

    private static func removeJapanese(from text: String, extra: [String]) -> String {
        let chars = Array(text)
        var out: [Character] = []
        var i = 0
        let unconditional = (japaneseFillers + extra.filter { !$0.allSatisfy(\.isASCII) })
            .sorted { $0.count > $1.count }.map(Array.init)
        let conditional = japaneseConditionalFillers.sorted { $0.count > $1.count }.map(Array.init)
        let extraSet = Set(extra)
        while i < chars.count {
            let atBoundary = i == 0 || boundary.contains(chars[i - 1]) || out.last.map { boundary.contains($0) } ?? true
            var matched = 0
            if atBoundary {
                for filler in unconditional where matches(chars, at: i, filler) {
                    let after = i + filler.count
                    // 利用者の語は後ろも区切りのときだけ消す（用意した語は、文の頭や句読点の後なら後ろに語が続いても消す）
                    let followedByBoundary = after >= chars.count || boundary.contains(chars[after])
                    if extraSet.contains(String(filler)) && !followedByBoundary { continue }
                    matched = filler.count
                    break
                }
                if matched == 0 {
                    for word in conditional where matches(chars, at: i, word) {
                        let after = i + word.count
                        var end = after
                        while end < chars.count, chars[end].isLongVowelMark { end += 1 }
                        let followed = end > after || (end < chars.count && "、，,  　".contains(chars[end]))
                        if followed { matched = end - i; break }
                    }
                }
            }
            if matched > 0 {
                i += matched
                // 消した語の後ろの「ー」と読点・空白も消す
                while i < chars.count, chars[i].isLongVowelMark { i += 1 }
                while i < chars.count, "、，, 　".contains(chars[i]) { i += 1 }
            } else {
                out.append(chars[i])
                i += 1
            }
        }
        return String(out)
    }

    private static func matches(_ chars: [Character], at index: Int, _ word: [Character]) -> Bool {
        guard index + word.count <= chars.count else { return false }
        return Array(chars[index ..< index + word.count]) == word
    }

    private static let englishRegex: NSRegularExpression = {
        let words = englishFillers.joined(separator: "|")
        // 単語として独立したフィラーと、直後の読点・空白
        return try! NSRegularExpression(pattern: "(?<![A-Za-z'])(?:" + words + ")(?![A-Za-z'])[,.…]?\\s*",
                                        options: [.caseInsensitive])
    }()

    private static func removeEnglish(from text: String) -> String {
        guard text.contains(where: { $0.isASCII && $0.isLetter }) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        var result = englishRegex.stringByReplacingMatches(in: text, range: range, withTemplate: "")
        // 文頭が小文字になったら大文字にする（元の文の頭が大文字だった場合だけ）
        if result != text, let first = text.first(where: \.isLetter), first.isUppercase,
           let index = result.firstIndex(where: \.isLetter), result[index].isLowercase {
            result.replaceSubrange(index ... index, with: String(result[index]).uppercased())
        }
        return result
    }

    /// 取り除いた後に残った区切りを整える
    private static func tidy(_ text: String, original: String) -> String {
        guard text != original else { return text }
        var result = text
        // 文頭の読点・空白
        while let first = result.first, "、，, 　".contains(first) { result.removeFirst() }
        // 読点の重なり
        for (from, to) in [("、、", "、"), ("、。", "。"), (",,", ","), (", .", "."), (" ,", ","), ("  ", " ")] {
            while result.contains(from) { result = result.replacingOccurrences(of: from, with: to) }
        }
        return result.trimmingCharacters(in: .whitespaces)
    }
}

private extension Character {
    var isLongVowelMark: Bool { self == "ー" || self == "〜" || self == "～" }
}
