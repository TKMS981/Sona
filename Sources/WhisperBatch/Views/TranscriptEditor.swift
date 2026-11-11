import AppKit
import SwiftUI
import WhisperBatchCore
import WhisperBatchEngine

/// 話者ごとの色（色だけに頼らず、名前も必ず一緒に表示する）
enum SpeakerPalette {
    static let colors: [NSColor] = [.systemBlue, .systemOrange, .systemGreen, .systemPink,
                                    .systemPurple, .systemTeal, .systemBrown, .systemIndigo]

    static func nsColor(_ speaker: Int) -> NSColor { colors[abs(speaker) % colors.count] }
    static func color(_ speaker: Int) -> Color { Color(nsColor: nsColor(speaker)) }
}

/// 結果の表示方法
enum TranscriptViewMode: String, CaseIterable, Identifiable {
    /// 読み取り専用のテキスト（検索・選択・コピー向け）
    case text
    /// 区間ごとの一覧（編集・削除・話者の変更）
    case segments

    var id: String { rawValue }
    var label: String { L("editor.mode.\(rawValue)") }
}

/// 完了した項目の結果（表示と編集）
struct CompletedTranscriptView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.appTypography) private var typography
    @Environment(\.hasCustomBackground) private var hasCustomBackground
    let item: QueueItem
    let original: Transcript
    let showTimestamps: Bool
    @AppStorage("editor.viewMode") private var modeRaw = TranscriptViewMode.text.rawValue
    @ViewState private var speakerFilter: Int?
    @ViewState private var reviewOnly = false
    @ViewState private var showDeleted = true

    private var mode: TranscriptViewMode { TranscriptViewMode(rawValue: modeRaw) ?? .text }

    var body: some View {
        let annotations = item.annotations
        // 誤認識の候補（要確認）は Vantage だけ
        let candidates = model.has(.reviewCandidates)
            ? ReviewCandidateFinder.find(in: original, edits: annotations.edits, threshold: model.settings.reviewThreshold.value)
            : []
        VStack(spacing: 0) {
            EditorToolbar(item: item, mode: Binding(get: { mode }, set: { modeRaw = $0.rawValue }),
                          reviewCount: candidates.count)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            if let job = model.speakerJobs[item.id] {
                SpeakerJobBanner(itemID: item.id, job: job)
            }
            Divider()
            switch mode {
            case .text:
                TranscriptTextView(
                    text: "",
                    font: typography.nsFont(size: NSFont.systemFontSize + 1),
                    showsBackground: !hasCustomBackground,
                    attributed: TranscriptRendering.attributed(
                        item: item, includeTimestamps: showTimestamps,
                        font: typography.nsFont(size: NSFont.systemFontSize + 1),
                        lowConfidenceThreshold: model.settings.showsConfidence ? model.settings.reviewThreshold.value : nil)
                )
            case .segments:
                VStack(spacing: 0) {
                    // 絞り込みの対象（話者・要確認・削除した区間）がなければ、絞り込みの行は出さない
                    if original.segments.contains(where: { $0.speaker != nil }) || !candidates.isEmpty
                        || annotations.edits.deletedCount > 0 {
                    SegmentFilterBar(original: original, names: annotations.speakerNames, speakerFilter: $speakerFilter,
                                     reviewOnly: $reviewOnly, showDeleted: $showDeleted, reviewCount: candidates.count,
                                     deletedCount: annotations.edits.deletedCount)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                    Divider()
                    }
                    SegmentList(item: item, original: original, candidates: candidates, speakerFilter: speakerFilter,
                                reviewOnly: reviewOnly, showDeleted: showDeleted)
                }
            }
        }
    }
}

/// 表示方法の切り替えと、話者・フィラー・要約などの操作
private struct EditorToolbar: View {
    @Environment(AppModel.self) private var model
    let item: QueueItem
    @Binding var mode: TranscriptViewMode
    let reviewCount: Int
    @ViewState private var confirmRestore = false

    var body: some View {
        HStack(spacing: 8) {
            Picker(L("editor.mode"), selection: $mode) {
                ForEach(TranscriptViewMode.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help(L("editor.mode.help"))

            ViewThatFits(in: .horizontal) {
                tools(showTitles: true)
                tools(showTitles: false)
            }
            Spacer(minLength: 0)
            if !item.annotations.edits.isEmpty {
                Button {
                    confirmRestore = true
                } label: {
                    Label(L("editor.restoreAll"), systemImage: "arrow.uturn.backward")
                }
                .labelStyle(.iconOnly)
                .help(L("editor.restoreAll.help", item.annotations.edits.count))
                .accessibilityLabel(L("editor.restoreAll"))
            }
        }
        .controlSize(.small)
        .alert(L("editor.restoreAll.confirm.title"), isPresented: $confirmRestore) {
            Button(L("editor.restoreAll"), role: .destructive) { model.restoreAllSegments(item.id) }
            Button(L("common.cancel"), role: .cancel) {}
        } message: {
            Text(L("editor.restoreAll.confirm.message", item.annotations.edits.editedCount, item.annotations.edits.deletedCount))
        }
    }

    @ViewBuilder
    private func tools(showTitles: Bool) -> some View {
        HStack(spacing: 6) {
            // AI の機能は Vantage だけ（Air では表示しない）
            if model.has(.speakerIdentification) {
                tool(L("editor.speakers"), icon: "person.2", help: L("editor.speakers.help"), showTitles: showTitles) {
                    model.speakerSheet = .init(id: item.id)
                }
            }
            if model.has(.aiCorrection) {
                tool(L("editor.aiCorrection"), icon: "wand.and.stars", help: L("editor.aiCorrection.help"), showTitles: showTitles) {
                    model.rewriteSheet = .init(itemID: item.id, task: .correction)
                }
            }
            if model.has(.aiPolish) {
                tool(L("editor.aiPolish"), icon: "text.badge.checkmark", help: L("editor.aiPolish.help"), showTitles: showTitles) {
                    model.rewriteSheet = .init(itemID: item.id, task: .polish)
                }
            }
            if model.has(.fillerRemoval) {
                tool(L("editor.fillers"), icon: "eraser", help: L("editor.fillers.help"), showTitles: showTitles) {
                    model.fillerSheet = .init(id: item.id)
                }
            }
            if model.has(.summary) {
                tool(L("editor.analysis"), icon: "sparkles", help: L("editor.analysis.help"), showTitles: showTitles) {
                    model.analysisSheet = .item(item.id)
                }
            }
            if reviewCount > 0 {
                Label(L("editor.reviewCount", reviewCount), systemImage: "exclamationmark.bubble")
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(.orange)
                    .appFont(.caption)
                    .help(L("editor.reviewCount.help"))
                    .fixedSize()
            }
        }
    }

    private func tool(_ title: String, icon: String, help: String, showTitles: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            if showTitles { Label(title, systemImage: icon) } else { Label(title, systemImage: icon).labelStyle(.iconOnly) }
        }
        .help(help)
        .accessibilityLabel(title)
        .fixedSize()
    }
}

/// 話者識別の進み具合
private struct SpeakerJobBanner: View {
    @Environment(AppModel.self) private var model
    let itemID: UUID
    let job: AppModel.SpeakerJob

    var body: some View {
        HStack(spacing: 8) {
            ProgressView(value: job.phase == .analyzing || job.phase == .converting ? job.progress : nil)
                .frame(maxWidth: 160)
            Text(phaseLabel)
                .appFont(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Button(L("common.cancel")) { model.cancelSpeakerIdentification(itemID) }
                .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var phaseLabel: String {
        switch job.phase {
        case .converting: L("speakers.phase.converting")
        case .reading: L("speakers.phase.reading")
        case .analyzing: L("speakers.phase.analyzing")
        }
    }
}

/// 区間の一覧の絞り込み（話者・要確認・削除した区間）
private struct SegmentFilterBar: View {
    let original: Transcript
    let names: [Int: String]
    @Binding var speakerFilter: Int?
    @Binding var reviewOnly: Bool
    /// 誤認識の候補を使えるエディション（Vantage）
    var showsReview: Bool { SonaRuntime.features.contains(.reviewCandidates) }
    @Binding var showDeleted: Bool
    let reviewCount: Int
    let deletedCount: Int

    var body: some View {
        let stats = SpeakerStatistics.make(original)
        HStack(spacing: 12) {
            if !stats.isEmpty {
                Picker(L("editor.filter.speaker"), selection: $speakerFilter) {
                    Text(L("editor.filter.allSpeakers")).tag(Int?.none)
                    ForEach(stats) { s in
                        Text(L("editor.filter.speakerItem", SpeakerNaming.displayName(s.speaker, names: names), s.segmentCount))
                            .tag(Int?.some(s.speaker))
                    }
                }
                .fixedSize()
            }
            if showsReview {
                Toggle(L("editor.filter.reviewOnly", reviewCount), isOn: $reviewOnly)
                    .toggleStyle(.checkbox)
                    .disabled(reviewCount == 0 && !reviewOnly)
                    .fixedSize()
            }
            if deletedCount > 0 {
                Toggle(L("editor.filter.showDeleted", deletedCount), isOn: $showDeleted)
                    .toggleStyle(.checkbox)
                    .fixedSize()
            }
            Spacer(minLength: 0)
        }
        .controlSize(.small)
        .appFont(.caption)
    }
}

/// 区間ごとの一覧（長い結果でも軽く動くよう、見えている行だけを作る）
private struct SegmentList: View {
    @Environment(AppModel.self) private var model
    @Environment(\.hasCustomBackground) private var hasCustomBackground
    let item: QueueItem
    let original: Transcript
    let candidates: [ReviewCandidate]
    let speakerFilter: Int?
    let reviewOnly: Bool
    let showDeleted: Bool

    var body: some View {
        let edits = item.annotations.edits
        let flagged = Dictionary(candidates.map { ($0.segmentIndex, $0) }, uniquingKeysWith: { a, _ in a })
        let indices = original.segments.indices.filter { i in
            if let speakerFilter, original.segments[i].speaker != speakerFilter { return false }
            if reviewOnly, flagged[i] == nil { return false }
            if !showDeleted, edits.state(at: i) == .deleted { return false }
            return true
        }
        let speakers = Array(Set(original.segments.compactMap(\.speaker))).sorted()
        Group {
            if indices.isEmpty {
                ContentUnavailableView(L("editor.filter.empty"), systemImage: "line.3.horizontal.decrease.circle")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(indices, id: \.self) { i in
                            SegmentRow(itemID: item.id, index: i, segment: original.segments[i],
                                       state: edits.state(at: i), current: edits.text(at: i, in: original),
                                       names: item.annotations.speakerNames, knownSpeakers: speakers,
                                       candidate: flagged[i], context: context(around: i, edits: edits),
                                       language: original.language)
                            Divider().padding(.leading, 12)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .background(hasCustomBackground ? AnyShapeStyle(.clear) : AnyShapeStyle(.background))
            }
        }
        .accessibilityLabel(L("editor.list.accessibility"))
    }

    /// AI の修正案に渡す前後の文
    private func context(around i: Int, edits: TranscriptEdits) -> (before: [String], after: [String]) {
        let before = original.segments.indices.filter { $0 < i }.suffix(2).compactMap { edits.text(at: $0, in: original) }
        let after = original.segments.indices.filter { $0 > i }.prefix(2).compactMap { edits.text(at: $0, in: original) }
        return (before, after)
    }
}

/// 区間 1 行（時刻・話者・文・確からしさ・操作）
private struct SegmentRow: View {
    @Environment(AppModel.self) private var model
    let itemID: UUID
    let index: Int
    let segment: TranscriptSegment
    let state: SegmentEditState
    let current: String?
    let names: [Int: String]
    let knownSpeakers: [Int]
    let candidate: ReviewCandidate?
    let context: (before: [String], after: [String])
    let language: String?

    @ViewState private var draft: String?
    @ViewState private var showSuggestion = false
    @FocusState private var focused: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(TranscriptFormatter.clock(segment.start))
                .appFont(.caption, monospacedDigit: true)
                .foregroundStyle(.secondary)
                .frame(minWidth: 44, alignment: .leading)
            SpeakerChip(itemID: itemID, index: index, speaker: segment.speaker, names: names, knownSpeakers: knownSpeakers)
            VStack(alignment: .leading, spacing: 4) {
                if let draft {
                    TextField(L("editor.edit.placeholder"), text: Binding(get: { draft }, set: { self.draft = $0 }), axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(1 ... 6)
                        .focused($focused)
                        .onSubmit(commit)
                        .onExitCommand { self.draft = nil }
                        .accessibilityLabel(L("editor.edit.accessibility", TranscriptFormatter.clock(segment.start)))
                    HStack(spacing: 6) {
                        Button(L("editor.edit.done"), action: commit).keyboardShortcut(.defaultAction)
                        Button(L("common.cancel")) { self.draft = nil }
                        Text(L("editor.edit.hint")).appFont(.caption).foregroundStyle(.secondary)
                    }
                    .controlSize(.small)
                } else {
                    textView
                        .onTapGesture(count: 2) { startEditing() }
                    if state == .edited {
                        Text(L("editor.originalText", segment.text))
                            .appFont(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .lineLimit(2)
                    }
                    if let candidate, state == .original {
                        Label(candidate.message, systemImage: "exclamationmark.bubble")
                            .appFont(.caption)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            badges
            actions
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .opacity(state == .deleted ? 0.6 : 1)
        .contextMenu { menu }
        .accessibilityElement(children: .contain)
    }

    private var textView: some View {
        let text: Text
        switch state {
        case .deleted:
            text = Text(segment.text).strikethrough()
        case .edited:
            text = Text(current ?? "")
        case .original:
            text = Text(highlighted)
        }
        return text
            .appFont(.body)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// 確からしさが低い語句に下線と色を付ける（設定で表示する場合）
    private var highlighted: AttributedString {
        var attributed = AttributedString(segment.text)
        guard model.settings.showsConfidence else { return attributed }
        for span in ReviewCandidateFinder.lowConfidenceSpans(in: segment, threshold: model.settings.reviewThreshold.value) {
            let lower = segment.text.distance(from: segment.text.startIndex, to: span.range.lowerBound)
            let upper = segment.text.distance(from: segment.text.startIndex, to: span.range.upperBound)
            let start = attributed.characters.index(attributed.startIndex, offsetBy: lower)
            let end = attributed.characters.index(attributed.startIndex, offsetBy: upper)
            attributed[start ..< end].foregroundColor = .orange
            attributed[start ..< end].underlineStyle = .single
        }
        return attributed
    }

    @ViewBuilder
    private var badges: some View {
        switch state {
        case .edited:
            StatusBadge(text: L("editor.state.edited"), color: .blue)
        case .deleted:
            StatusBadge(text: L("editor.state.deleted"), color: .secondary)
        case .original:
            if model.settings.showsConfidence, let c = segment.confidence {
                ConfidenceBadge(value: c, threshold: model.settings.reviewThreshold.value)
            }
        }
    }

    private var actions: some View {
        HStack(spacing: 2) {
            if state == .original, candidate != nil, model.has(.aiCorrection),
               model.resolveAI(.correction, languageCode: language).engine != nil {
                Button { showSuggestion = true } label: { Image(systemName: "wand.and.stars") }
                    .help(L("editor.suggest.help"))
                    .accessibilityLabel(L("editor.suggest"))
                    .popover(isPresented: $showSuggestion, arrowEdge: .bottom) {
                        SuggestionPopover(itemID: itemID, index: index, segment: segment, context: context,
                                          language: language, suspicious: suspiciousWords)
                    }
            }
            switch state {
            case .original:
                Button { startEditing() } label: { Image(systemName: "pencil") }
                    .help(L("editor.edit"))
                    .accessibilityLabel(L("editor.edit"))
                Button { model.deleteSegment(itemID, index: index) } label: { Image(systemName: "trash") }
                    .help(L("editor.delete"))
                    .accessibilityLabel(L("editor.delete"))
            case .edited:
                Button { startEditing() } label: { Image(systemName: "pencil") }
                    .help(L("editor.edit"))
                    .accessibilityLabel(L("editor.edit"))
                Button { model.restoreSegment(itemID, index: index) } label: { Image(systemName: "arrow.uturn.backward") }
                    .help(L("editor.restore"))
                    .accessibilityLabel(L("editor.restore"))
            case .deleted:
                Button { model.restoreSegment(itemID, index: index) } label: { Image(systemName: "arrow.uturn.backward") }
                    .help(L("editor.restore"))
                    .accessibilityLabel(L("editor.restore"))
            }
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
    }

    @ViewBuilder
    private var menu: some View {
        Button(L("editor.edit")) { startEditing() }
        if state != .deleted { Button(L("editor.delete")) { model.deleteSegment(itemID, index: index) } }
        if state != .original { Button(L("editor.restore")) { model.restoreSegment(itemID, index: index) } }
        Divider()
        Button(L("detail.copy")) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(current ?? segment.text, forType: .string)
        }
    }

    private var suspiciousWords: [String] {
        ReviewCandidateFinder.lowConfidenceSpans(in: segment, threshold: model.settings.reviewThreshold.value).map(\.text)
    }

    private func startEditing() {
        draft = current ?? segment.text
        focused = true
    }

    private func commit() {
        guard let draft else { return }
        model.replaceSegment(itemID, index: index, text: draft)
        self.draft = nil
    }
}

/// 話者の表示と変更（識別の結果を手で直す）。
/// macOS のメニューのラベルは色を表示しないので、色付きの名前を押すと選択肢を出す。
private struct SpeakerChip: View {
    @Environment(AppModel.self) private var model
    let itemID: UUID
    let index: Int
    let speaker: Int?
    let names: [Int: String]
    let knownSpeakers: [Int]
    @ViewState private var showChoices = false

    var body: some View {
        if knownSpeakers.isEmpty && speaker == nil {
            EmptyView()
        } else {
            let name = speaker.map { SpeakerNaming.displayName($0, names: names) } ?? L("speakers.unknown")
            Button {
                showChoices = true
            } label: {
                HStack(spacing: 4) {
                    Circle()
                        .fill(speaker.map(SpeakerPalette.color) ?? .secondary.opacity(0.4))
                        .frame(width: 8, height: 8)
                    Text(name)
                        .appFont(.caption, weight: .semibold)
                        .foregroundStyle(speaker.map(SpeakerPalette.color) ?? .secondary)
                        .lineLimit(1)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background((speaker.map(SpeakerPalette.color) ?? .secondary).opacity(0.12), in: Capsule())
            }
            .buttonStyle(.plain)
            .fixedSize()
            .help(L("speakers.change.help"))
            .accessibilityLabel(L("speakers.change.accessibility", name))
            .popover(isPresented: $showChoices, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(knownSpeakers, id: \.self) { s in
                        choice(SpeakerNaming.displayName(s, names: names), color: SpeakerPalette.color(s), selected: s == speaker) {
                            model.setSegmentSpeaker(itemID, index: index, speaker: s)
                        }
                    }
                    choice(L("speakers.new"), color: SpeakerPalette.color((knownSpeakers.max() ?? -1) + 1), selected: false) {
                        model.setSegmentSpeaker(itemID, index: index, speaker: (knownSpeakers.max() ?? -1) + 1)
                    }
                    Divider()
                    choice(L("speakers.none.item"), color: .secondary, selected: speaker == nil) {
                        model.setSegmentSpeaker(itemID, index: index, speaker: nil)
                    }
                }
                .padding(8)
                .frame(minWidth: 160)
            }
        }
    }

    private func choice(_ title: String, color: Color, selected: Bool, action: @escaping () -> Void) -> some View {
        Button {
            action()
            showChoices = false
        } label: {
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 8, height: 8)
                Text(title)
                Spacer(minLength: 8)
                if selected { Image(systemName: "checkmark") }
            }
            .contentShape(Rectangle())
            .padding(.vertical, 3)
        }
        .buttonStyle(.plain)
    }
}

/// 確からしさの表示（数値を必ず添え、色だけに頼らない）
struct ConfidenceBadge: View {
    let value: Double
    let threshold: Double

    var body: some View {
        let percent = Int((value * 100).rounded())
        Text(L("common.percentShort", percent))
            .appFont(.caption, monospacedDigit: true)
            .foregroundStyle(value < threshold ? .orange : .secondary)
            .help(L("confidence.help", percent))
            .accessibilityLabel(L("confidence.accessibility", percent))
    }
}

private struct StatusBadge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .appFont(.caption, weight: .medium)
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(color.opacity(0.12), in: Capsule())
            .fixedSize()
    }
}

/// オンデバイスの AI による修正案（採用するまで何も変えない）
private struct SuggestionPopover: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let itemID: UUID
    let index: Int
    let segment: TranscriptSegment
    let context: (before: [String], after: [String])
    let language: String?
    let suspicious: [String]

    @ViewState private var suggestion: String?
    @ViewState private var engineName: String?
    @ViewState private var isLoading = true
    @ViewState private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("editor.suggest.title")).appFont(.headline)
            Text(L("editor.suggest.original", segment.text))
                .appFont(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if isLoading {
                ProgressView().controlSize(.small)
            } else if let error {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).appFont(.callout)
            } else if let suggestion {
                Text(suggestion)
                    .appFont(.body)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(8)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
            } else {
                Text(L("editor.suggest.none")).appFont(.callout).foregroundStyle(.secondary)
            }
            if let engineName {
                Text(L("ai.engine.using", engineName)).appFont(.caption).foregroundStyle(.secondary)
            }
            Text(L("editor.suggest.note")).appFont(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button(L("common.close")) { dismiss() }
                Button(L("editor.suggest.apply")) {
                    if let suggestion { model.replaceSegment(itemID, index: index, text: suggestion) }
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(suggestion == nil)
            }
            .controlSize(.small)
        }
        .padding(14)
        .frame(width: 380)
        .task {
            do {
                let generator = try await model.textGenerator(for: .correction, languageCode: language)
                engineName = generator.displayName
                suggestion = try await AITaskRunner.suggestCorrection(
                    target: segment.text, before: context.before, after: context.after, suspicious: suspicious,
                    generator: generator, languageCode: language)
            } catch is CancellationError {
            } catch {
                self.error = userFacingMessage(for: error)
            }
            isLoading = false
        }
    }
}

/// テキスト表示の文字列（時刻・色付きの話者名・確からしさが低い語句の下線）
enum TranscriptRendering {
    @MainActor
    static func attributed(item: QueueItem, includeTimestamps: Bool, font: NSFont,
                           lowConfidenceThreshold: Double?) -> NSAttributedString {
        let out = NSMutableAttributedString()
        guard let transcript = item.editedTranscript else { return out }
        let names = item.annotations.speakerNames
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 4
        style.paragraphSpacing = 4
        let base: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.textColor, .paragraphStyle: style]
        let bold = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
        let segments = TranscriptFormatter.cleanedSegments(transcript)
        if segments.isEmpty {
            return NSAttributedString(string: TranscriptFormatter.noSpeechText, attributes: base)
        }
        for segment in segments {
            if includeTimestamps {
                var attrs = base
                attrs[.foregroundColor] = NSColor.secondaryLabelColor
                out.append(NSAttributedString(string: "[\(TranscriptFormatter.clock(segment.start))] ", attributes: attrs))
            }
            if let speaker = segment.speaker {
                var attrs = base
                attrs[.font] = bold
                attrs[.foregroundColor] = SpeakerPalette.nsColor(speaker)
                out.append(NSAttributedString(string: SpeakerNaming.displayName(speaker, names: names) + ": ", attributes: attrs))
            }
            let text = NSMutableAttributedString(string: segment.text, attributes: base)
            if let threshold = lowConfidenceThreshold {
                for span in ReviewCandidateFinder.lowConfidenceSpans(in: segment, threshold: threshold) {
                    let range = NSRange(span.range, in: segment.text)
                    text.addAttributes([.underlineStyle: NSUnderlineStyle.single.rawValue | NSUnderlineStyle.patternDot.rawValue,
                                        .underlineColor: NSColor.systemOrange], range: range)
                }
            }
            out.append(text)
            out.append(NSAttributedString(string: "\n", attributes: base))
        }
        return out
    }
}
