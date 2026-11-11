import Foundation

/// 書き出し形式
public enum ExportFormat: String, CaseIterable, Identifiable, Sendable {
    case plainText
    case srt
    case vtt
    case markdown

    public var id: String { rawValue }

    public var fileExtension: String {
        switch self {
        case .plainText: "txt"
        case .srt: "srt"
        case .vtt: "vtt"
        case .markdown: "md"
        }
    }

    public var displayName: String {
        L("exportFormat.\(rawValue)")
    }
}

/// 統合ファイルに入れる 1 件分
public struct CombinedEntry: Sendable {
    public var title: String
    public var transcript: Transcript
    public var speakerNames: [Int: String]
    public init(title: String, transcript: Transcript, speakerNames: [Int: String] = [:]) {
        self.title = title
        self.transcript = transcript
        self.speakerNames = speakerNames
    }
}

/// 書き出しに添える情報（題名・話者名・要約など）。Markdown 以外では話者名だけを使う。
public struct ExportContext: Sendable {
    public var title: String?
    public var speakerNames: [Int: String]
    public var analysis: TranscriptAnalysis?
    /// 音声の長さ（秒。分かるときだけ）
    public var duration: TimeInterval?

    public init(title: String? = nil, speakerNames: [Int: String] = [:], analysis: TranscriptAnalysis? = nil,
                duration: TimeInterval? = nil) {
        self.title = title
        self.speakerNames = speakerNames
        self.analysis = analysis
        self.duration = duration
    }
}

/// 文字起こし結果を各形式の文字列にする。出力には認識結果とファイル名（と、利用者が作った話者名・要約）だけを含める。
public enum TranscriptFormatter {
    /// 発話がなかったときの本文（表示言語に従う）
    public static var noSpeechText: String { L("export.noSpeech") }

    // MARK: 単体

    public static func format(_ transcript: Transcript, as format: ExportFormat, includeTimestamps: Bool = false,
                              context: ExportContext = ExportContext()) -> String {
        switch format {
        case .plainText: plainText(transcript, includeTimestamps: includeTimestamps, speakerNames: context.speakerNames)
        case .srt: srt(transcript, speakerNames: context.speakerNames)
        case .vtt: vtt(transcript, speakerNames: context.speakerNames)
        case .markdown: markdown(transcript, includeTimestamps: includeTimestamps, context: context)
        }
    }

    /// 1 区間 1 行のテキスト。話者識別をしていれば行の頭に話者名を付ける。末尾は改行で終える。
    public static func plainText(_ transcript: Transcript, includeTimestamps: Bool = false,
                                 speakerNames: [Int: String] = [:]) -> String {
        let lines = cleanedSegments(transcript).map { seg in
            let body = speakerPrefix(seg, speakerNames) + seg.text
            return includeTimestamps ? "[\(clock(seg.start))] \(body)" : body
        }
        if lines.isEmpty { return noSpeechText + "\n" }
        return lines.joined(separator: "\n") + "\n"
    }

    public static func srt(_ transcript: Transcript, speakerNames: [Int: String] = [:]) -> String {
        var out = ""
        for (i, seg) in cleanedSegments(transcript).enumerated() {
            let (start, end) = cueTimes(seg)
            out += "\(i + 1)\n"
            out += "\(timestamp(start, separator: ",")) --> \(timestamp(end, separator: ","))\n"
            out += speakerPrefix(seg, speakerNames) + seg.text + "\n\n"
        }
        return out
    }

    public static func vtt(_ transcript: Transcript, speakerNames: [Int: String] = [:]) -> String {
        var out = "WEBVTT\n\n"
        for seg in cleanedSegments(transcript) {
            let (start, end) = cueTimes(seg)
            out += "\(timestamp(start, separator: ".")) --> \(timestamp(end, separator: "."))\n"
            // 話者は WebVTT の声のタグで示す（名前の中の記号はタグを壊さないよう除く）
            if let speaker = seg.speaker {
                let name = SpeakerNaming.displayName(speaker, names: speakerNames)
                    .filter { !"<>&".contains($0) }.replacingOccurrences(of: "-->", with: "→")
                out += "<v \(name)>"
            }
            // "-->" はキューの区切りと誤認されるため置き換える
            out += seg.text.replacingOccurrences(of: "-->", with: "→") + "\n\n"
        }
        return out
    }

    // MARK: Markdown

    /// 見出し・情報・要約・重要な発言・本文の順の Markdown。要約と重要な発言は、作ってあるときだけ入れる。
    public static func markdown(_ transcript: Transcript, includeTimestamps: Bool = false,
                                context: ExportContext = ExportContext()) -> String {
        var out = "# \(escapeMarkdown(context.title ?? L("markdown.defaultTitle")))\n\n"
        var info: [String] = []
        if let lang = transcript.language {
            info.append(L("markdown.language", LanguageOption.displayName(forCode: lang)))
        }
        if let duration = context.duration, duration > 0 {
            info.append(L("markdown.duration", clock(duration)))
        }
        let segments = cleanedSegments(transcript)
        let speakers = Array(Set(segments.compactMap(\.speaker))).sorted()
        if !speakers.isEmpty {
            let names = speakers.map { escapeMarkdown(SpeakerNaming.displayName($0, names: context.speakerNames)) }
            info.append(L("markdown.speakers", names.joined(separator: L("list.separator"))))
        }
        if !info.isEmpty { out += info.map { "- \($0)" }.joined(separator: "\n") + "\n\n" }

        if let analysis = context.analysis {
            if !analysis.summary.isEmpty {
                out += "## \(L("markdown.summary"))\n\n"
                out += analysis.summary.map { "- \(escapeMarkdown(stripBullet($0)))" }.joined(separator: "\n") + "\n\n"
                if let made = analysis.summaryEngine ?? analysis.summaryMethod?.displayName { out += "_\(L("markdown.madeWith", made))_\n\n" }
            }
            if !analysis.keyPoints.isEmpty {
                out += "## \(L("markdown.keyPoints"))\n\n"
                for point in analysis.keyPoints {
                    var line = "- "
                    if let start = point.start { line += "[\(clock(start))] " }
                    if let speaker = point.speaker {
                        line += "**\(escapeMarkdown(SpeakerNaming.displayName(speaker, names: context.speakerNames)))**: "
                    }
                    line += escapeMarkdown(point.text)
                    out += line + "\n"
                }
                out += "\n"
                if let made = analysis.keyPointsEngine ?? analysis.keyPointsMethod?.displayName { out += "_\(L("markdown.madeWith", made))_\n\n" }
            }
            if !analysis.translation.isEmpty, let lang = analysis.translationLanguage {
                out += "## \(L("markdown.translation", LanguageOption.displayName(forCode: lang)))\n\n"
                out += analysis.translation.map(escapeMarkdown).joined(separator: "\n\n") + "\n\n"
                if let made = analysis.translationEngine { out += "_\(L("markdown.madeWith", made))_\n\n" }
            }
        }

        out += "## \(L("markdown.transcript"))\n\n"
        if segments.isEmpty {
            out += noSpeechText + "\n"
            return out
        }
        let paragraphs = segments.map { seg -> String in
            var head: [String] = []
            if includeTimestamps { head.append("[\(clock(seg.start))]") }
            if let speaker = seg.speaker {
                head.append(escapeMarkdown(SpeakerNaming.displayName(speaker, names: context.speakerNames)))
            }
            let text = escapeMarkdown(seg.text)
            return head.isEmpty ? text : "**\(head.joined(separator: " "))**: \(text)"
        }
        out += paragraphs.joined(separator: "\n\n") + "\n"
        return out
    }

    /// Markdown の記号として解釈されないようにする（文字はそのまま見えるように、記号の前に \\ を付ける）
    public static func escapeMarkdown(_ text: String) -> String {
        var out = ""
        for c in text {
            if "\\`*_[]<>|".contains(c) { out.append("\\") }
            out.append(c)
        }
        // 行頭の見出し・引用・箇条書き・番号付きの記号
        if let first = out.first, "#+-".contains(first) || out.range(of: #"^\d+[.)]\s"#, options: .regularExpression) != nil {
            if first.isNumber, let dot = out.firstIndex(where: { $0 == "." || $0 == ")" }) {
                out.insert("\\", at: dot)
            } else {
                out.insert("\\", at: out.startIndex)
            }
        }
        return out
    }

    /// 先頭の箇条書きの記号を除く（AI が付けて返すことがあるため）
    static func stripBullet(_ line: String) -> String {
        var s = line.trimmingCharacters(in: .whitespaces)
        for bullet in ["- ", "・", "* ", "• ", "‐ "] where s.hasPrefix(bullet) {
            s.removeFirst(bullet.count)
            break
        }
        return s.trimmingCharacters(in: .whitespaces)
    }

    /// 話者識別をしていれば「話者名: 」
    static func speakerPrefix(_ segment: TranscriptSegment, _ names: [Int: String]) -> String {
        guard let speaker = segment.speaker else { return "" }
        return SpeakerNaming.displayName(speaker, names: names) + ": "
    }

    // MARK: 統合

    /// 複数の結果を 1 つのテキストにまとめる。順序は entries の順。
    public static func combinedPlainText(_ entries: [CombinedEntry], includeTimestamps: Bool = false) -> String {
        let total = entries.count
        let rule = String(repeating: "=", count: 40)
        var blocks: [String] = []
        for (i, entry) in entries.enumerated() {
            var block = "\(rule)\n[\(i + 1)/\(total)] \(entry.title)\n\(rule)\n\n"
            block += plainText(entry.transcript, includeTimestamps: includeTimestamps, speakerNames: entry.speakerNames)
            blocks.append(block)
        }
        return blocks.joined(separator: "\n")
    }

    // MARK: 時刻表記

    /// 00:01:02,345 / 00:01:02.345
    public static func timestamp(_ seconds: TimeInterval, separator: String) -> String {
        let totalMs = Int((max(seconds, 0) * 1000).rounded())
        let h = totalMs / 3_600_000
        let m = (totalMs / 60_000) % 60
        let s = (totalMs / 1000) % 60
        let ms = totalMs % 1000
        return String(format: "%02d:%02d:%02d%@%03d", h, m, s, separator, ms)
    }

    /// 1:02:03 / 02:03（画面・テキスト用）
    public static func clock(_ seconds: TimeInterval) -> String {
        let t = Int(max(seconds, 0).rounded(.down))
        let h = t / 3600, m = (t / 60) % 60, s = t % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }

    // MARK: private

    /// 前後の空白を除き、空の区間と改行を整理する
    public static func cleanedSegments(_ transcript: Transcript) -> [TranscriptSegment] {
        transcript.segments.compactMap { seg in
            let text = seg.text
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            guard !text.isEmpty else { return nil }
            var cleaned = seg
            cleaned.text = text
            return cleaned
        }
    }

    /// 字幕の表示時間が 0 以下にならないようにする
    private static func cueTimes(_ seg: TranscriptSegment) -> (TimeInterval, TimeInterval) {
        let start = max(seg.start, 0)
        let end = max(seg.end, start + 0.5)
        return (start, end)
    }
}
