import Foundation

/// オンデバイスの言語モデルに渡す文の組み立てと、返答の読み取り（AI の呼び出しそのものは Engine が行う）。
///
/// - 文字起こしは区間ごとに「#番号 [時刻] 話者: 文」の行にして渡す。
/// - 重要な発言は AI に番号を選ばせ、文は文字起こしのものをそのまま使う（AI が言い換えた文や、
///   文字起こしにない文を「発言」として出さないため）。
/// - 整文（句読点や表記を整える）は番号ごとに直した文を返させ、元の文から大きく変わったものは使わない。
/// - 音声も文字も外部へは送らない（この Mac の中のモデルだけを使う）。
public enum LocalAIText {
    /// AI に渡す 1 行
    public struct Line: Equatable, Sendable {
        /// 元の区間の番号（`Transcript.segments` の添字）
        public var index: Int
        public var start: TimeInterval
        public var speaker: String?
        public var text: String

        public var rendered: String {
            var s = "#\(index + 1) [\(TranscriptFormatter.clock(start))] "
            if let speaker { s += "\(speaker): " }
            return s + text
        }
    }

    /// 返答に使う言語
    public enum OutputLanguage: String, Sendable {
        case japanese, english

        /// 文字起こしの言語から決める（日本語以外は英語）
        public init(code: String?) {
            self = code == "ja" ? .japanese : .english
        }
    }

    /// 1 回に渡す文字数の上限（モデルの文脈の長さに収まるよう、指示と返答の分を残す）
    public static let chunkCharacters = 1_800

    /// 編集を反映した区間を行にする（削除した区間は含めない）
    public static func lines(original: Transcript, edits: TranscriptEdits, speakerNames: [Int: String]) -> [Line] {
        original.segments.enumerated().compactMap { i, segment in
            guard let text = edits.text(at: i, in: original) else { return nil }
            let clean = text.components(separatedBy: .newlines).joined(separator: " ").trimmingCharacters(in: .whitespaces)
            guard !clean.isEmpty else { return nil }
            let speaker = segment.speaker.map { SpeakerNaming.displayName($0, names: speakerNames) }
            return Line(index: i, start: segment.start, speaker: speaker, text: clean)
        }
    }

    /// 行を、文字数の上限に収まるまとまりに分ける（1 行が上限を超える場合は、その行だけで 1 つにする）
    public static func chunks(_ lines: [Line], limit: Int = chunkCharacters) -> [[Line]] {
        var result: [[Line]] = []
        var current: [Line] = []
        var size = 0
        for line in lines {
            let length = line.rendered.count + 1
            if !current.isEmpty, size + length > limit {
                result.append(current)
                current = []
                size = 0
            }
            current.append(line)
            size += length
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    // MARK: 指示

    public static func summaryInstructions(_ language: OutputLanguage) -> String {
        switch language {
        case .japanese:
            """
            あなたは会議・講義・インタビューの文字起こしを要約する担当です。
            渡された文字起こしに書かれている内容だけを使ってください。書かれていないこと（推測、一般知識、意見）は加えないでください。
            文字起こしには誤認識が含まれることがあります。意味が通らない部分は無理に解釈しないでください。
            出力は日本語の箇条書きだけにし、各行を「- 」で始めてください。前置きや結びの文は書かないでください。
            """
        case .english:
            """
            You summarize transcripts of meetings, lectures and interviews.
            Use only what the transcript says. Do not add guesses, general knowledge or opinions.
            The transcript may contain recognition errors; do not force an interpretation of parts that make no sense.
            Output only a bulleted list in English, each line starting with "- ". No introduction or closing sentence.
            """
        }
    }

    /// 1 つのまとまりを要約させる
    public static func summaryPrompt(_ chunk: [Line], part: Int, of total: Int, language: OutputLanguage) -> String {
        let body = chunk.map(\.rendered).joined(separator: "\n")
        switch language {
        case .japanese:
            let scope = total > 1 ? "（全 \(total) 部のうち第 \(part) 部）" : ""
            return "次の文字起こし\(scope)の要点を 3〜6 項目で箇条書きにしてください。\n\n\(body)"
        case .english:
            let scope = total > 1 ? " (part \(part) of \(total))" : ""
            return "List the main points of the following transcript\(scope) in 3 to 6 bullets.\n\n\(body)"
        }
    }

    /// 部分ごとの要約をまとめさせる
    public static func combinePrompt(_ partials: [[String]], language: OutputLanguage) -> String {
        let body = partials.enumerated().filter { !$0.element.isEmpty }.map { i, items in
            "[\(i + 1)]\n" + items.map { "- \($0)" }.joined(separator: "\n")
        }.joined(separator: "\n\n")
        switch language {
        case .japanese:
            return "次は 1 つの文字起こしを部分ごとに要約したものです。重複をまとめ、全体の要約を 5〜8 項目の箇条書きにしてください。\n\n\(body)"
        case .english:
            return "These are summaries of consecutive parts of one transcript. Merge duplicates and write an overall summary in 5 to 8 bullets.\n\n\(body)"
        }
    }

    public static func keyPointInstructions(_ language: OutputLanguage) -> String {
        switch language {
        case .japanese:
            """
            あなたは文字起こしから重要な発言を選ぶ担当です。各行の頭の「#番号」で発言を示します。
            決定事項・依頼や担当・期限・数値・課題や懸念・強調された点を含む発言を選んでください。
            出力は 1 行に 1 つ、「#番号: 理由」の形だけにしてください。理由は次のどれかです: 決定, 依頼, 期限, 数値, 課題, 強調。
            発言の文を書き直したり、文字起こしにない番号を書いたりしないでください。
            """
        case .english:
            """
            You select important statements from a transcript. Each line starts with "#number".
            Choose statements that contain decisions, requests or assignments, deadlines, figures, issues or concerns, or emphasized points.
            Output one per line, only in the form "#number: reason". The reason is one of: decision, request, deadline, number, issue, emphasis.
            Do not rewrite statements and do not output numbers that are not in the transcript.
            """
        }
    }

    public static func keyPointPrompt(_ chunk: [Line], maxCount: Int, language: OutputLanguage) -> String {
        let body = chunk.map(\.rendered).joined(separator: "\n")
        switch language {
        case .japanese: return "次の文字起こしから重要な発言を最大 \(maxCount) 個選んでください。\n\n\(body)"
        case .english: return "Choose up to \(maxCount) important statements from the following transcript.\n\n\(body)"
        }
    }

    public static func polishInstructions(_ language: OutputLanguage) -> String {
        switch language {
        case .japanese:
            """
            あなたは文字起こしの文を読みやすく整える担当です。各行の頭の「#番号」で文を示します。
            句読点を補い、「えー」「あのー」などのフィラーと、言い直しで重なった語だけを除いてください。
            語の言い換え・漢字の変更・要約・内容の追加はしないでください。人名・地名・製品名・数字・日付・金額は一字も変えないでください。
            判断できない文は出力しないでください（原文のまま残します）。
            直す必要がある文だけを、1 行に 1 つ「#番号: 整えた文」の形で出力してください。
            """
        case .english:
            """
            You tidy up transcript sentences. Each line starts with "#number".
            Only add punctuation and remove fillers such as "um" and "uh" and words repeated by false starts.
            Do not rephrase, replace words, summarize or add content. Never change names of people, places or products, numbers, dates or amounts.
            If you are not sure, leave the sentence out (it stays as it is).
            Output only the sentences that need changes, one per line, in the form "#number: tidied sentence".
            """
        }
    }

    public static func polishPrompt(_ chunk: [Line], language: OutputLanguage) -> String {
        // 整文では時刻と話者は不要（文だけを渡す）
        let body = chunk.map { "#\($0.index + 1) \($0.text)" }.joined(separator: "\n")
        switch language {
        case .japanese: return "次の文を整えてください。\n\n\(body)"
        case .english: return "Tidy up the following sentences.\n\n\(body)"
        }
    }

    public static func correctionInstructions(_ language: OutputLanguage) -> String {
        switch language {
        case .japanese:
            """
            あなたは音声認識の誤りを直す担当です。前後の文を手がかりに、対象の文の中の誤認識と思われる語だけを直してください。
            確信が持てない部分は元のままにしてください。内容を足したり要約したりしないでください。
            人名・地名・製品名・数字・日付・金額は推測で変えないでください。
            出力は直した文 1 行だけにしてください。直す必要がなければ元の文をそのまま出力してください。
            """
        case .english:
            """
            You fix speech recognition errors. Using the surrounding sentences as context, fix only words in the target sentence that are likely misrecognized.
            Keep anything you are not sure about unchanged. Do not add or summarize content.
            Never guess changes to names of people, places or products, numbers, dates or amounts.
            Output only the corrected sentence on one line. If nothing needs fixing, output the original sentence unchanged.
            """
        }
    }

    public static func correctionPrompt(target: String, before: [String], after: [String], suspicious: [String],
                                        language: OutputLanguage) -> String {
        switch language {
        case .japanese:
            var s = ""
            if !before.isEmpty { s += "前の文:\n" + before.joined(separator: "\n") + "\n\n" }
            s += "対象の文:\n\(target)\n\n"
            if !after.isEmpty { s += "後の文:\n" + after.joined(separator: "\n") + "\n\n" }
            if !suspicious.isEmpty { s += "認識の確からしさが低かった語: " + suspicious.joined(separator: "、") + "\n" }
            return s
        case .english:
            var s = ""
            if !before.isEmpty { s += "Previous sentences:\n" + before.joined(separator: "\n") + "\n\n" }
            s += "Target sentence:\n\(target)\n\n"
            if !after.isEmpty { s += "Following sentences:\n" + after.joined(separator: "\n") + "\n\n" }
            if !suspicious.isEmpty { s += "Words with low recognition confidence: " + suspicious.joined(separator: ", ") + "\n" }
            return s
        }
    }

    /// 誤認識の修正（まとめて）。整形とは別の処理で、句読点やフィラーは変えない。
    public static func correctionBatchInstructions(_ language: OutputLanguage) -> String {
        switch language {
        case .japanese:
            """
            あなたは音声認識の誤りを直す担当です。各行の頭の「#番号」で文を示します。
            文脈から明らかに誤認識と分かる語（同音異義語の取り違え・聞き間違い）だけを直してください。
            句読点・フィラー・言い回しは変えないでください。要約・内容の追加はしないでください。
            人名・地名・製品名・数字・日付・金額は推測で変えないでください。確信が持てない文は出力しないでください（原文のまま残します）。
            直した文だけを、1 行に 1 つ「#番号: 直した文」の形で出力してください。
            """
        case .english:
            """
            You fix speech recognition errors. Each line starts with "#number".
            Fix only words that are clearly misrecognized from context (wrong homophones, misheard words).
            Do not change punctuation, fillers or wording. Do not summarize or add content.
            Never guess changes to names of people, places or products, numbers, dates or amounts. If you are not sure, leave the sentence out (it stays as it is).
            Output only the corrected sentences, one per line, in the form "#number: corrected sentence".
            """
        }
    }

    public static func correctionBatchPrompt(_ chunk: [Line], suspicious: [Int: [String]], language: OutputLanguage) -> String {
        let body = chunk.map { line -> String in
            var s = "#\(line.index + 1) \(line.text)"
            if let words = suspicious[line.index], !words.isEmpty {
                s += language == .japanese ? "（確からしさが低い語: \(words.joined(separator: "、"))）"
                                           : " (low-confidence words: \(words.joined(separator: ", ")))"
            }
            return s
        }.joined(separator: "\n")
        switch language {
        case .japanese: return "次の文の誤認識を直してください。\n\n\(body)"
        case .english: return "Fix recognition errors in the following sentences.\n\n\(body)"
        }
    }

    /// 翻訳の指示（翻訳専用でないモデル向け）
    public static func translationInstructions(target: String) -> String {
        let name = LanguageOption.allCases.first { $0.code == target }.map { Locale(identifier: "en").localizedString(forLanguageCode: $0.code ?? target) ?? target }
            ?? (Locale(identifier: "en").localizedString(forLanguageCode: target) ?? target)
        return """
        Translate the user's text into \(name). Keep the line breaks.
        Translate faithfully: do not summarize, explain or add anything. Keep names, numbers, dates and amounts as they are.
        Output only the translation.
        """
    }

    /// 翻訳の返答を整える（モデルが行の頭に付けることがある番号「#1 」や引用符を除く）
    public static func cleanTranslation(_ text: String) -> String {
        text.components(separatedBy: .newlines).map { line -> String in
            var s = line.trimmingCharacters(in: .whitespaces)
            if let r = s.range(of: #"^[#＃]\d+[:：.]?\s*"#, options: .regularExpression) { s.removeSubrange(r) }
            return s
        }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: 返答の読み取り

    /// 箇条書きの行を取り出す（記号を除く。空行・前置きの文は除く）
    public static func parseBullets(_ response: String) -> [String] {
        response.components(separatedBy: .newlines).compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            let markers = ["- ", "・", "* ", "• ", "‐ ", "– "]
            guard let marker = markers.first(where: { line.hasPrefix($0) }) else {
                // 番号付き（「1. 」「1) 」）も受け付ける
                if let range = line.range(of: #"^\d+[.)．]\s*"#, options: .regularExpression) {
                    let text = String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                    return text.isEmpty ? nil : text
                }
                return nil
            }
            var text = String(line.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
            // 記号が重なっている（「- - 項目」「・- 項目」）ときは、残りの記号も除く
            while let more = markers.first(where: { text.hasPrefix($0) }) {
                text = String(text.dropFirst(more.count)).trimmingCharacters(in: .whitespaces)
            }
            // Markdown の強調（**語**）は記号を除く（表示・書き出しで記号がそのまま見えるため）
            text = text.replacingOccurrences(of: "**", with: "")
            return text.isEmpty ? nil : text
        }
    }

    /// 「#番号: 内容」の行を取り出す。渡した行にない番号は除く（番号は 1 始まりで表示し、区間の添字に戻す）。
    public static func parseNumbered(_ response: String, valid: Set<Int>) -> [(index: Int, text: String)] {
        var seen = Set<Int>()
        var result: [(Int, String)] = []
        for raw in response.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard let match = line.firstMatch(of: /^[-・*\s]*[#＃]\s*(\d+)\s*[:：.\-]?\s*(.*)$/),
                  let number = Int(match.1) else { continue }
            let index = number - 1
            guard valid.contains(index), seen.insert(index).inserted else { continue }
            result.append((index, String(match.2).trimmingCharacters(in: .whitespaces)))
        }
        return result
    }

    /// 理由の語を種類に直す（分からない語は nil）
    public static func reason(from text: String) -> KeyPointReason? {
        let lower = text.lowercased()
        let table: [(KeyPointReason, [String])] = [
            (.decision, ["決定", "decision", "decid"]),
            (.request, ["依頼", "担当", "request", "assign"]),
            (.deadline, ["期限", "締め切り", "deadline", "due"]),
            (.number, ["数値", "数字", "number", "figure"]),
            (.issue, ["課題", "懸念", "問題", "issue", "concern", "problem"]),
            (.emphasis, ["強調", "重要", "emphasis", "important"]),
        ]
        return table.first { _, words in words.contains { lower.contains($0) } }?.0
    }

    /// 整文の返答のうち、元の文から大きく変わっていないものだけを使う。
    /// 長さが元の半分未満・1.6 倍超になったもの、空のもの、元と同じものは使わない。
    public static func acceptedRewrites(_ parsed: [(index: Int, text: String)], originals: [Int: String]) -> [Int: String] {
        var result: [Int: String] = [:]
        for (index, text) in parsed {
            guard let original = originals[index] else { continue }
            let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty, cleaned != original else { continue }
            let a = Double(original.filter { !$0.isWhitespace }.count)
            let b = Double(cleaned.filter { !$0.isWhitespace }.count)
            guard a > 0, b / a >= 0.5, b / a <= 1.6 else { continue }
            result[index] = cleaned
        }
        return result
    }

    /// 誤認識の修正案を 1 行にする（前置き・引用符を除く）。元から大きく変わったものは nil。
    public static func acceptedCorrection(_ response: String, original: String) -> String? {
        var line = response.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
        for prefix in ["対象の文:", "修正:", "Corrected:", "Target sentence:"] where line.hasPrefix(prefix) {
            line = String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        }
        let quotes: [(Character, Character)] = [("「", "」"), ("\"", "\""), ("“", "”")]
        for (open, close) in quotes where line.first == open && line.last == close && line.count >= 2 {
            line = String(line.dropFirst().dropLast())
        }
        return acceptedRewrites([(0, line)], originals: [0: original])[0]
    }
}
