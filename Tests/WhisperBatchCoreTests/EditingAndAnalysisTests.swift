import Foundation
import Testing
@testable import WhisperBatchCore

// 追加機能（編集・フィラー除去・誤認識候補・話者・Markdown・要約・ライブの品質・設定の書き出し）のテスト

private func seg(_ start: TimeInterval, _ end: TimeInterval, _ text: String, confidence: Double? = nil,
                 words: [TranscriptWord]? = nil, speaker: Int? = nil) -> TranscriptSegment {
    TranscriptSegment(start: start, end: end, text: text, confidence: confidence, words: words, speaker: speaker)
}

@Suite("区間の付加情報（確からしさ・語句・話者）")
struct SegmentMetadataTests {
    init() { TestLocalization.setUp() }

    @Test func decodesOldDataWithoutMetadata() throws {
        // 以前の版の形（start / end / text だけ）も読める
        let json = #"{"start":1,"end":2,"text":"こんにちは"}"#
        let s = try JSONDecoder().decode(TranscriptSegment.self, from: Data(json.utf8))
        #expect(s == TranscriptSegment(start: 1, end: 2, text: "こんにちは"))
        #expect(s.confidence == nil && s.words == nil && s.speaker == nil)
    }

    @Test func shiftingKeepsMetadata() {
        let s = seg(1, 2, "abc", confidence: 0.8, words: [.init(text: "abc", probability: 0.8)], speaker: 1)
        let shifted = s.shifted(by: 10)
        #expect(shifted.start == 11 && shifted.end == 12)
        #expect(shifted.confidence == 0.8 && shifted.speaker == 1 && shifted.words?.count == 1)
    }

    @Test func changingTextDropsWordsButKeepsConfidenceAndSpeaker() {
        let s = seg(0, 1, "abc", confidence: 0.8, words: [.init(text: "abc", probability: 0.8)], speaker: 2)
        let changed = s.with(text: "xyz")
        #expect(changed.words == nil && changed.confidence == 0.8 && changed.speaker == 2)
    }

    @Test func meanProbabilityIgnoresPunctuationAndMissingValues() {
        let words = [TranscriptWord(text: "今日", probability: 0.9), TranscriptWord(text: "は", probability: 0.5),
                     TranscriptWord(text: "。", probability: 0.1), TranscriptWord(text: "晴れ", probability: nil)]
        #expect(TranscriptSegment.meanProbability(of: words) == 0.7)
        #expect(TranscriptSegment.meanProbability(of: [TranscriptWord(text: "、", probability: 0.2)]) == nil)
    }

    @Test func sentenceSplitKeepsConfidenceAndSpeaker() {
        let s = seg(0, 4, "今日は晴れです。明日は雨です。", confidence: 0.6, speaker: 0)
        let parts = LiveText.splitSentences(s)
        #expect(parts.count == 2)
        #expect(parts.allSatisfy { $0.confidence == 0.6 && $0.speaker == 0 && $0.words == nil })
    }

    @Test func mergerAveragesPieceConfidence() {
        let pieces = [seg(0, 0.5, "今日は", confidence: 0.9), seg(0.5, 1, "晴れ", confidence: 0.5), seg(1, 1, "。")]
        let merged = SegmentMerger.merge(pieces)
        #expect(merged.count == 1)
        #expect(merged[0].text == "今日は晴れ。")
        #expect(merged[0].confidence == 0.7)
        #expect(merged[0].words?.map(\.text) == ["今日は", "晴れ", "。"])
    }

    @Test func mergerLeavesConfidenceEmptyWhenNotProvided() {
        let merged = SegmentMerger.merge([seg(0, 1, "Hello"), seg(1, 2, " world.")])
        #expect(merged[0].confidence == nil && merged[0].words == nil)
    }
}

@Suite("編集（部分修正・削除・原文の復元）")
struct TranscriptEditsTests {
    init() { TestLocalization.setUp() }

    let original = Transcript(segments: [seg(0, 1, "一つ目"), seg(1, 2, "二つ目"), seg(2, 3, "三つ目")], language: "ja")

    @Test func replaceDeleteAndRestore() {
        var edits = TranscriptEdits()
        edits.replace(0, with: "  ひとつめ ", in: original)
        edits.delete(2, in: original)
        #expect(edits.state(at: 0) == .edited && edits.state(at: 1) == .original && edits.state(at: 2) == .deleted)
        let applied = edits.apply(to: original)
        #expect(applied.segments.map(\.text) == ["ひとつめ", "二つ目"])
        #expect(applied.language == "ja")
        // 原文は変わらない
        #expect(original.segments.map(\.text) == ["一つ目", "二つ目", "三つ目"])

        edits.restore(2)
        #expect(edits.apply(to: original).segments.count == 3)
        edits.restoreAll()
        #expect(edits.isEmpty)
        #expect(edits.apply(to: original) == original)
    }

    @Test func replacingWithOriginalTextClearsTheChange() {
        var edits = TranscriptEdits()
        edits.replace(1, with: "変更", in: original)
        edits.replace(1, with: " 二つ目 ", in: original)
        #expect(edits.isEmpty)
    }

    @Test func clearingTextDeletesTheSegment() {
        var edits = TranscriptEdits()
        edits.replace(0, with: "   ", in: original)
        #expect(edits.state(at: 0) == .deleted)
        #expect(edits.text(at: 0, in: original) == nil)
    }

    @Test func outOfRangeIndexIsIgnored() {
        var edits = TranscriptEdits()
        edits.replace(5, with: "x", in: original)
        edits.delete(-1, in: original)
        #expect(edits.isEmpty)
    }

    @Test func editedSegmentLosesWordConfidence() {
        let t = Transcript(segments: [seg(0, 1, "abc", confidence: 0.4, words: [.init(text: "abc", probability: 0.4)])], language: "en")
        var edits = TranscriptEdits()
        edits.replace(0, with: "abd", in: t)
        let applied = edits.apply(to: t)
        #expect(applied.segments[0].words == nil)
        #expect(edits.editedCount == 1 && edits.deletedCount == 0)
    }

    @Test func speakerNames() {
        #expect(SpeakerNaming.displayName(0, names: [:]) == "話者 1")
        #expect(SpeakerNaming.displayName(1, names: [1: "佐藤"]) == "佐藤")
        #expect(SpeakerNaming.displayName(1, names: [1: "  "]) == "話者 2")
        #expect(SpeakerNaming.sanitized("田中\n太郎") == "田中 太郎")
        #expect(SpeakerNaming.sanitized(String(repeating: "あ", count: 100)).count == SpeakerNaming.nameLimit)
    }
}

@Suite("キュー: 結果の編集・話者・並べ替え")
struct QueueAnnotationTests {
    init() { TestLocalization.setUp() }

    private func completedQueue() throws -> (TranscriptionQueue, UUID) {
        var q = TranscriptionQueue()
        let report = q.add([FileCandidate(url: URL(fileURLWithPath: "/tmp/a.wav"), bookmark: nil)])
        let id = report.added[0]
        try q.markProcessing(id)
        try q.markCompleted(id, transcript: Transcript(segments: [seg(0, 1, "一"), seg(1, 2, "二")], language: "ja"))
        return (q, id)
    }

    @Test func editsApplyOnlyToCompletedItems() throws {
        var (q, id) = try completedQueue()
        let original = q.item(id)!.transcript!
        q.updateAnnotations(id) { $0.edits.delete(0, in: original) }
        #expect(q.item(id)?.editedTranscript?.segments.map(\.text) == ["二"])
        #expect(q.item(id)?.transcript?.segments.count == 2)

        var pending = TranscriptionQueue()
        let pid = pending.add([FileCandidate(url: URL(fileURLWithPath: "/tmp/b.wav"), bookmark: nil)]).added[0]
        pending.updateAnnotations(pid) { $0.speakerNames[0] = "x" }
        #expect(pending.item(pid)?.annotations.isEmpty == true)
    }

    @Test func retryDiscardsEdits() throws {
        var (q, id) = try completedQueue()
        q.updateAnnotations(id) { $0.speakerNames[0] = "A" }
        q.resetForRetry([id])
        #expect(q.item(id)?.annotations.isEmpty == true)
        #expect(q.item(id)?.transcript == nil)
    }

    @Test func setSpeakersRequiresMatchingCountAndClearsNames() throws {
        var (q, id) = try completedQueue()
        q.updateAnnotations(id) { $0.speakerNames[0] = "A" }
        q.setSpeakers(id, [0])
        #expect(q.item(id)?.hasSpeakers == false)
        q.setSpeakers(id, [0, 1])
        #expect(q.item(id)?.transcript?.segments.map(\.speaker) == [0, 1])
        #expect(q.item(id)?.annotations.speakerNames.isEmpty == true)
        q.setSpeaker(id, segment: 1, speaker: 0)
        #expect(q.item(id)?.transcript?.segments.map(\.speaker) == [0, 0])
    }

    @Test func exportContextUsesFileStemAndDuration() throws {
        var (q, id) = try completedQueue()
        q.setDuration(id, 12)
        let context = q.item(id)!.exportContext
        #expect(context.title == "a")
        #expect(context.duration == 12)
        #expect(context.analysis == nil)
    }

    @Test(arguments: [
        (IndexSet([0]), 3, ["b", "c", "a"]),
        (IndexSet([2]), 0, ["c", "a", "b"]),
        (IndexSet([0, 2]), 2, ["b", "a", "c"]),
        (IndexSet([1]), 1, ["a", "b", "c"]),
    ])
    func moveReordersItems(source: IndexSet, destination: Int, expected: [String]) {
        var q = TranscriptionQueue()
        q.add(["a", "b", "c"].map { FileCandidate(url: URL(fileURLWithPath: "/tmp/\($0).wav"), bookmark: nil) })
        q.move(fromOffsets: source, toOffset: destination)
        #expect(q.items.map { ($0.displayName as NSString).deletingPathExtension } == expected)
    }

    @Test func invalidMoveIsIgnored() {
        var q = TranscriptionQueue()
        q.add(["a", "b"].map { FileCandidate(url: URL(fileURLWithPath: "/tmp/\($0).wav"), bookmark: nil) })
        let before = q.items.map(\.id)
        q.move(fromOffsets: IndexSet([5]), toOffset: 0)
        q.move(fromOffsets: IndexSet([0]), toOffset: 9)
        #expect(q.items.map(\.id) == before)
    }
}

@Suite("フィラーの除去")
struct FillerRemoverTests {
    @Test(arguments: [
        ("えー、本日はお集まりいただき", "本日はお集まりいただき"),
        ("えーと、資料を見てください。", "資料を見てください。"),
        ("えっとそれは来週です", "それは来週です"),
        ("あのー、すみません", "すみません"),
        ("あの、会議の件ですが", "会議の件ですが"),
        ("その、まあ、難しいですね", "難しいですね"),
        ("うーん、どうでしょう", "どうでしょう"),
        ("資料は、えー、三枚です", "資料は、三枚です"),
        ("今日は、あのー、雨です。", "今日は、雨です。"),
    ])
    func removesJapaneseFillers(input: String, expected: String) {
        #expect(FillerRemover.remove(from: input) == expected)
    }

    @Test(arguments: [
        "あの人は田中さんです",
        "その件は来週にします",
        "まあまあの出来です",
        "ええ、そうです",
        "ケーキを買った",
        "なんかいい感じ",
    ])
    func keepsMeaningfulWords(input: String) {
        #expect(FillerRemover.remove(from: input) == input)
    }

    @Test(arguments: [
        ("Um, so we decided to ship it.", "So we decided to ship it."),
        ("We need, uh, two more days.", "We need, two more days."),
        ("I think hmm that works", "I think that works"),
        ("Umbrella and human are words", "Umbrella and human are words"),
    ])
    func removesEnglishFillers(input: String, expected: String) {
        #expect(FillerRemover.remove(from: input) == expected)
    }

    @Test func extraWordsOnlyAtBoundaries() {
        let extra = FillerRemover.parseExtra("ですね、 なるほど\nですね")
        #expect(extra == ["ですね", "なるほど"])
        #expect(FillerRemover.remove(from: "なるほど、分かりました", extra: extra) == "分かりました")
        #expect(FillerRemover.remove(from: "なるほどね", extra: extra) == "なるほどね")
    }

    @Test func changesListOnlyAffectedAndSkipsDeleted() {
        let t = Transcript(segments: [seg(0, 1, "えー、はい"), seg(1, 2, "そうです"), seg(2, 3, "えー、削除")], language: "ja")
        var edits = TranscriptEdits()
        edits.delete(2, in: t)
        let changes = FillerRemover.changes(in: t, edits: edits)
        #expect(changes == [FillerRemover.Change(index: 0, before: "えー、はい", after: "はい")])
    }
}

@Suite("誤認識の候補")
struct ReviewCandidateTests {
    init() { TestLocalization.setUp() }

    @Test func lowConfidenceWordsAreMergedAndLocated() {
        let words = [TranscriptWord(text: " 会議", probability: 0.95), TranscriptWord(text: "は", probability: 0.9),
                     TranscriptWord(text: "金", probability: 0.3), TranscriptWord(text: "曜", probability: 0.4),
                     TranscriptWord(text: "です", probability: 0.92), TranscriptWord(text: "。", probability: 0.1)]
        let s = seg(0, 2, "会議は金曜です。", confidence: 0.7, words: words)
        let spans = ReviewCandidateFinder.lowConfidenceSpans(in: s, threshold: 0.5)
        #expect(spans.map(\.text) == ["金曜"])
        #expect(spans.first?.probability == 0.3)
        #expect(String(s.text[spans[0].range]) == "金曜")
        let reasons = ReviewCandidateFinder.reasons(for: s, threshold: 0.5)
        #expect(reasons == [.lowConfidenceWords(["金曜"], lowest: 0.3)])
    }

    @Test func segmentConfidenceUsedOnlyWithoutWords() {
        #expect(ReviewCandidateFinder.reasons(for: seg(0, 2, "テスト", confidence: 0.2), threshold: 0.5) == [.lowConfidenceSegment(0.2)])
        #expect(ReviewCandidateFinder.reasons(for: seg(0, 2, "テスト", confidence: 0.8), threshold: 0.5).isEmpty)
        // 確からしさがない区間は、確からしさを理由にしない
        #expect(ReviewCandidateFinder.reasons(for: seg(0, 2, "テスト"), threshold: 0.5).isEmpty)
    }

    @Test func repetitionAndDensity() {
        let rep = ReviewCandidateFinder.reasons(for: seg(0, 10, "ありがとうありがとうありがとうありがとう"), threshold: 0.5)
        #expect(rep.contains(.repetition))
        let dense = ReviewCandidateFinder.reasons(for: seg(0, 1, "これは一秒間にとても多くの文字を話しているおかしな区間です"), threshold: 0.5)
        #expect(dense.contains { if case .tooDense = $0 { true } else { false } })
    }

    @Test func editedAndDeletedSegmentsAreSkipped() {
        let t = Transcript(segments: [seg(0, 1, "a", confidence: 0.1), seg(1, 2, "b", confidence: 0.1),
                                      seg(2, 3, "c", confidence: 0.1)], language: "en")
        var edits = TranscriptEdits()
        edits.replace(0, with: "A", in: t)
        edits.delete(1, in: t)
        #expect(ReviewCandidateFinder.find(in: t, edits: edits).map(\.segmentIndex) == [2])
        #expect(!ReviewCandidateFinder.find(in: t, edits: edits)[0].message.isEmpty)
    }
}

@Suite("話者の割り当てと集計")
struct SpeakerAssignmentTests {
    @Test func assignsByLargestOverlapAndRenumbersByFirstAppearance() {
        let segments = [seg(0, 2, "a"), seg(2, 5, "b"), seg(5, 6, "c"), seg(20, 21, "d")]
        let turns = [SpeakerTurn(start: 0, end: 2.2, speaker: 3), SpeakerTurn(start: 2.2, end: 4.5, speaker: 1),
                     SpeakerTurn(start: 6.3, end: 8, speaker: 3)]
        // c は重なりがないが 0.3 秒後に話者 3 → 最初の話者（0）。d は近くに話者がいない
        #expect(SpeakerAssigner.assign(segments, turns: turns) == [0, 1, 0, nil])
    }

    @Test func noTurnsMeansNoSpeakers() {
        #expect(SpeakerAssigner.assign([seg(0, 1, "a")], turns: []) == [nil])
    }

    @Test func statistics() {
        let t = Transcript(segments: [seg(0, 2, "あい う", speaker: 0), seg(2, 3, "え", speaker: 1),
                                      seg(3, 6, "お", speaker: 0), seg(6, 7, "x")], language: "ja")
        let stats = SpeakerStatistics.make(t)
        #expect(stats.map(\.speaker) == [0, 1])
        #expect(stats[0].segmentCount == 2 && stats[0].duration == 5 && stats[0].characterCount == 4)
    }
}

@Suite("Markdown と話者名の書き出し")
struct MarkdownExportTests {
    init() { TestLocalization.setUp() }

    let transcript = Transcript(segments: [seg(0, 2, "今日の議題です。", speaker: 0), seg(65, 70, "*重要* な点", speaker: 1)],
                                language: "ja")

    @Test func plainTextAndSubtitlesIncludeSpeakers() {
        let names = [1: "佐藤"]
        #expect(TranscriptFormatter.plainText(transcript, speakerNames: names) == "話者 1: 今日の議題です。\n佐藤: *重要* な点\n")
        #expect(TranscriptFormatter.srt(transcript, speakerNames: names).contains("佐藤: *重要* な点"))
        #expect(TranscriptFormatter.vtt(transcript, speakerNames: [1: "<佐藤>"]).contains("<v 佐藤>*重要* な点"))
    }

    @Test func markdownStructure() {
        var analysis = TranscriptAnalysis()
        analysis.summary = ["- 議題の確認", "重要な点の共有"]
        analysis.summaryMethod = .extractive
        analysis.keyPoints = [KeyPoint(text: "*重要* な点", start: 65, speaker: 1, reasons: [.emphasis])]
        analysis.keyPointsMethod = .onDeviceAI
        let md = TranscriptFormatter.format(transcript, as: .markdown, includeTimestamps: true,
                                            context: ExportContext(title: "定例会議", speakerNames: [1: "佐藤"],
                                                                   analysis: analysis, duration: 3700))
        #expect(md.hasPrefix("# 定例会議\n\n- 言語: 日本語\n- 長さ: 1:01:40\n- 話者: 話者 1、佐藤\n\n"))
        #expect(md.contains("## 要約\n\n- 議題の確認\n- 重要な点の共有\n\n_簡易抽出（AI なし） で作成_"))
        #expect(md.contains("## 重要な発言\n\n- [01:05] **佐藤**: \\*重要\\* な点\n"))
        #expect(md.contains("## 文字起こし\n\n**[00:00] 話者 1**: 今日の議題です。\n\n**[01:05] 佐藤**: \\*重要\\* な点\n"))
    }

    @Test func markdownWithoutSpeakersOrTimestamps() {
        let t = Transcript(segments: [seg(0, 1, "一行目"), seg(1, 2, "二行目")], language: nil)
        let md = TranscriptFormatter.markdown(t)
        #expect(md == "# 文字起こし\n\n## 文字起こし\n\n一行目\n\n二行目\n")
        #expect(TranscriptFormatter.markdown(Transcript(segments: [], language: nil)).hasSuffix("## 文字起こし\n\n" + TranscriptFormatter.noSpeechText + "\n"))
        #expect(ExportFormat.markdown.fileExtension == "md")
    }

    @Test(arguments: [
        ("# 見出し", "\\# 見出し"),
        ("- 項目", "\\- 項目"),
        ("1. 番号", "1\\. 番号"),
        ("a_b [c] <d> |e|", "a\\_b \\[c\\] \\<d\\> \\|e\\|"),
        ("普通の文", "普通の文"),
    ])
    func escaping(input: String, expected: String) {
        #expect(TranscriptFormatter.escapeMarkdown(input) == expected)
    }
}

@Suite("要約・重要な発言（AI なしの簡易抽出）")
struct ExtractiveAnalysisTests {
    init() { TestLocalization.setUp() }

    let meeting = Transcript(segments: [
        seg(0, 3, "えー、本日は新製品の発売日について話し合います。"),
        seg(3, 5, "はい。"),
        seg(5, 9, "新製品の発売日は来月の十五日に決定しました。"),
        seg(9, 12, "広告の予算は三百万円を予定しています。"),
        seg(12, 14, "そうですね。"),
        seg(14, 18, "新製品の資料は田中さんが金曜日までに用意してください。"),
        seg(18, 21, "在庫の不足が課題として残っています。"),
        seg(21, 23, "ありがとうございます。"),
    ], language: "ja")

    @Test func summaryPicksTopicSentencesInOrder() {
        let summary = ExtractiveSummarizer.summarize(meeting, maxSentences: 3)
        #expect(summary.count == 3)
        #expect(summary.map(\.start) == summary.map(\.start).sorted())
        // 相づちは選ばない
        #expect(!summary.contains { $0.text == "はい。" || $0.text == "そうですね。" })
        #expect(summary.allSatisfy { $0.text.contains("新製品") })
    }

    @Test func keyStatementsUseCueWords() {
        let points = KeyStatementExtractor.extract(meeting, maxCount: 4)
        let texts = points.map(\.text)
        #expect(texts.contains("新製品の発売日は来月の十五日に決定しました。"))
        #expect(texts.contains("新製品の資料は田中さんが金曜日までに用意してください。"))
        #expect(texts.contains("在庫の不足が課題として残っています。"))
        #expect(texts.contains("広告の予算は三百万円を予定しています。") == false || points.count == 4)
        let decided = points.first { $0.text.contains("決定") }
        #expect(decided?.reasons.contains(.decision) == true)
        let request = points.first { $0.text.contains("用意") }
        #expect(request?.reasons.contains(.request) == true && request?.reasons.contains(.deadline) == true)
    }

    @Test func reasonsInEnglish() {
        #expect(KeyStatementExtractor.reasons(in: "We decided to launch on Friday.") == [.decision])
        #expect(KeyStatementExtractor.reasons(in: "Could you send the report by next week?").contains(.request))
        #expect(KeyStatementExtractor.reasons(in: "The budget is 300 dollars.") == [.number])
        #expect(KeyStatementExtractor.reasons(in: "The bus arrived.").isEmpty)
    }

    @Test func greetingsAreNotRequests() {
        #expect(KeyStatementExtractor.reasons(in: "はい、よろしくお願いします。").isEmpty)
        #expect(KeyStatementExtractor.reasons(in: "本日はよろしくお願いいたします").isEmpty)
        #expect(KeyStatementExtractor.reasons(in: "資料の準備をお願いします。") == [.request])
    }

    @Test func fallsBackToCentralSentencesWithoutCues() {
        let t = Transcript(segments: [seg(0, 2, "猫の話をしましょう、猫はかわいい"), seg(2, 4, "猫は毎日よく眠る動物です"),
                                      seg(4, 6, "犬も散歩が好きな動物です")], language: "ja")
        let points = KeyStatementExtractor.extract(t, maxCount: 2)
        #expect(points.count == 2)
        #expect(points.allSatisfy { $0.reasons == [.central] })
    }

    @Test func emptyTranscript() {
        let t = Transcript(segments: [], language: "ja")
        #expect(ExtractiveSummarizer.summarize(t).isEmpty)
        #expect(KeyStatementExtractor.extract(t).isEmpty)
    }
}

@Suite("ライブ文字起こしの品質と遅れ")
struct LiveQualityTests {
    @Test func recordsLatencyConfidenceAndProcessing() {
        var meter = LiveQualityMeter()
        #expect(meter.status(backlog: 0, recentlyDropped: false) == .measuring)
        meter.recordRecognition(processingSeconds: 0.4)
        meter.recordRecognition(processingSeconds: 0.6)
        meter.recordConfirmed([seg(0, 2, "a", confidence: 0.9), seg(2, 4, "b")], elapsed: 5)
        let snap = meter.snapshot
        #expect(snap.lastLatency == 1 && snap.averageLatency == 2 && snap.maxLatency == 3)
        #expect(snap.averageProcessing == 0.5)
        #expect(snap.averageConfidence == 0.9)
        #expect(meter.status(backlog: 0, recentlyDropped: false) == .good)
        #expect(meter.status(backlog: 3, recentlyDropped: false) == .behind)
        #expect(meter.status(backlog: 0, recentlyDropped: true) == .behind)
    }

    @Test func delayedWhenLatencyIsHigh() {
        var meter = LiveQualityMeter()
        meter.recordConfirmed([seg(0, 1, "a")], elapsed: 7)
        #expect(meter.status(backlog: 0, recentlyDropped: false) == .delayed)
    }

    @Test func keepsOnlyRecentValues() {
        var meter = LiveQualityMeter()
        for i in 0 ..< 50 { meter.recordRecognition(processingSeconds: Double(i)) }
        #expect(meter.processingTimes.count == LiveQualityMeter.window)
        #expect(meter.processingTimes.first == 30)
        meter.recordRecognition(processingSeconds: .nan)
        #expect(meter.processingTimes.count == LiveQualityMeter.window)
    }

    @Test func noConfidenceWhenNotProvided() {
        var meter = LiveQualityMeter()
        meter.recordConfirmed([seg(0, 1, "a")], elapsed: 1.5)
        #expect(meter.snapshot.averageConfidence == nil)
    }
}

@Suite("設定の書き出しと読み込み")
@MainActor
struct SettingsTransferTests {
    init() { TestLocalization.setUp() }

    private func store() -> (SettingsStore, UserDefaults) {
        let name = "SettingsTransferTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return (SettingsStore(defaults: defaults), defaults)
    }

    @Test func roundTrip() throws {
        let (a, defaultsA) = store()
        a.language = .english
        a.autoStartOnAdd = true
        a.whisperDecoding = .greedy
        a.liveVocabularyHint = "Sona, whisper.cpp"
        a.notifyBatchFinished = true
        a.notificationSound = true
        a.reviewThreshold = .loose
        a.extraFillers = "なるほど"
        a.showsConfidence = false
        a.ghostMode = true
        defaultsA.set(true, forKey: SettingsStore.DisplayKeys.showTimestamps)
        var appearance = SettingsSnapshot.Appearance()
        appearance.fontSize = "large"
        let data = try a.makeSnapshot(appearance: appearance).encoded()

        let decoded = try SettingsSnapshot.decode(data)
        #expect(decoded.appearance?.fontSize == "large")
        let (b, defaultsB) = store()
        let report = b.apply(decoded)
        #expect(report.skipped.isEmpty)
        #expect(report.applied > 15)
        #expect(b.language == .english && b.autoStartOnAdd && b.whisperDecoding == .greedy)
        #expect(b.liveVocabularyHint == "Sona, whisper.cpp")
        #expect(b.notifyBatchFinished && b.notificationSound && !b.notifyDownloads && b.notifyOnlyWhenInactive)
        #expect(b.reviewThreshold == .loose && b.extraFillers == "なるほど" && !b.showsConfidence)
        #expect(defaultsB.bool(forKey: SettingsStore.DisplayKeys.showTimestamps))
        // ゴーストモードは書き出さない・読み込まない
        #expect(!String(decoding: data, as: UTF8.self).contains("ghost"))
        #expect(b.ghostMode == false)
    }

    @Test func invalidValuesAreSkippedOthersApplied() throws {
        let json = """
        {"format":"Sona.settings","version":1,
         "general":{"transcriptionLanguage":"xx","modelID":"no-such-model","autoStartOnAdd":true},
         "live":{"modelID":"reazonspeech-k2-v2","stopShortcut":"controlOptionCommandL"},
         "editing":{"reviewThreshold":"strict"}}
        """
        let (s, _) = store()
        let report = s.apply(try SettingsSnapshot.decode(Data(json.utf8)))
        #expect(Set(report.skipped) == ["general.transcriptionLanguage", "general.modelID", "live.modelID", "live.stopShortcut"])
        #expect(report.applied == 2)
        #expect(s.autoStartOnAdd && s.reviewThreshold == .strict)
        #expect(s.language == .japanese)
    }

    @Test func rejectsOtherFiles() {
        #expect(throws: SettingsTransferError.notSettingsFile) { try SettingsSnapshot.decode(Data("not json".utf8)) }
        #expect(throws: SettingsTransferError.notSettingsFile) { try SettingsSnapshot.decode(Data(#"{"format":"x","version":1}"#.utf8)) }
        #expect(throws: SettingsTransferError.unsupportedVersion(99)) {
            try SettingsSnapshot.decode(Data(#"{"format":"Sona.settings","version":99}"#.utf8))
        }
        #expect(throws: SettingsTransferError.tooLarge) { try SettingsSnapshot.decode(Data(count: SettingsSnapshot.maxFileSize + 1)) }
    }

    @Test func newSettingsDefaults() {
        let (s, _) = store()
        #expect(!s.anyNotificationEnabled && s.notifyOnlyWhenInactive && !s.notificationSound)
        #expect(s.reviewThreshold == .standard && s.showsConfidence && s.extraFillers.isEmpty)
        s.extraFillers = String(repeating: "あ", count: 600)
        #expect(s.extraFillers.count == SettingsStore.extraFillersLimit)
    }
}

@Suite("ローカル AI に渡す文と返答の読み取り")
struct LocalAITextTests {
    init() { TestLocalization.setUp() }

    let transcript = Transcript(segments: [seg(0, 1, "一つ目", speaker: 0), seg(61, 62, "二つ目"), seg(62, 63, "三つ目")],
                                language: "ja")

    @Test func linesSkipDeletedAndUseEdits() {
        var edits = TranscriptEdits()
        edits.delete(1, in: transcript)
        edits.replace(2, with: "みっつめ", in: transcript)
        let lines = LocalAIText.lines(original: transcript, edits: edits, speakerNames: [0: "司会"])
        #expect(lines.map(\.rendered) == ["#1 [00:00] 司会: 一つ目", "#3 [01:02] みっつめ"])
    }

    @Test func chunksRespectLimit() {
        let lines = (0 ..< 10).map { LocalAIText.Line(index: $0, start: 0, speaker: nil, text: String(repeating: "あ", count: 30)) }
        let chunks = LocalAIText.chunks(lines, limit: 100)
        #expect(chunks.flatMap { $0 }.count == 10)
        #expect(chunks.allSatisfy { $0.map { $0.rendered.count + 1 }.reduce(0, +) <= 100 })
        // 1 行が上限を超えても失わない
        #expect(LocalAIText.chunks([LocalAIText.Line(index: 0, start: 0, speaker: nil, text: String(repeating: "a", count: 500))],
                                   limit: 100).count == 1)
    }

    @Test func parsesBullets() {
        let response = "要約は次のとおりです。\n- 一つ目\n・二つ目\n* 三つ目\n1. 四つ目\n\n-  \n• - 五つ目\n- - 六つ目"
        #expect(LocalAIText.parseBullets(response) == ["一つ目", "二つ目", "三つ目", "四つ目", "五つ目", "六つ目"])
    }

    @Test func parsesNumberedLinesAndIgnoresUnknownNumbers() {
        let response = "#1: 決定\n#9: 依頼\n＃3：期限\n- #1: 重複\nその他"
        let parsed = LocalAIText.parseNumbered(response, valid: [0, 2])
        #expect(parsed.map(\.index) == [0, 2])
        #expect(parsed.map(\.text) == ["決定", "期限"])
        #expect(LocalAIText.reason(from: "決定") == .decision)
        #expect(LocalAIText.reason(from: "deadline") == .deadline)
        #expect(LocalAIText.reason(from: "その他") == nil)
    }

    @Test func rewritesThatChangeTooMuchAreRejected() {
        let originals = [0: "えー今日は晴れです", 1: "明日は雨", 2: "変えない"]
        let parsed = [(index: 0, text: "今日は晴れです。"), (index: 1, text: "明日は雨が降るでしょうと気象庁が発表しました"),
                      (index: 2, text: "変えない"), (index: 5, text: "x")]
        #expect(LocalAIText.acceptedRewrites(parsed, originals: originals) == [0: "今日は晴れです。"])
        #expect(LocalAIText.acceptedCorrection("「会議は金曜です」\n説明", original: "会議は禁曜です") == "会議は金曜です")
        #expect(LocalAIText.acceptedCorrection("会議は禁曜です", original: "会議は禁曜です") == nil)
    }

    @Test func outputLanguage() {
        #expect(LocalAIText.OutputLanguage(code: "ja") == .japanese)
        #expect(LocalAIText.OutputLanguage(code: "fr") == .english)
        #expect(LocalAIText.OutputLanguage(code: nil) == .english)
        #expect(LocalAIText.summaryPrompt([], part: 2, of: 3, language: .japanese).contains("第 2 部"))
    }
}
