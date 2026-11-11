import SwiftUI
import WhisperBatchCore
import WhisperBatchEngine

/// AI による誤認識の修正・文章の整形（Vantage。別々の機能）。
///
/// - 候補を確かめる: 差分を見て、採用・却下を選んでから反映する（既定）
/// - 自動で反映: 検査を通った候補をすぐに反映する
/// どちらも原文は残り、区間ごと・今回の分をまとめて・全体を原文に戻せる。人名・地名・製品名・数字・日付・金額を変えた候補や、
/// 原文にない内容を足した候補は使わない（`RewriteGuard`）。
struct AIRewriteSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openSettings) private var openSettings
    let itemID: UUID
    let task: AITask

    @ViewState private var outcome: RewriteOutcome?
    @ViewState private var rejectedByUser: Set<Int> = []
    /// 自動で反映した区間（今回の分）
    @ViewState private var applied: [RewriteCandidate] = []
    @ViewState private var busy = false
    @ViewState private var progress = 0.0
    @ViewState private var error: String?
    @ViewState private var job: Task<Void, Never>?
    @ViewState private var showRejected = false

    var body: some View {
        @Bindable var settings = model.settings
        let item = model.queue.item(itemID)
        let language = item?.transcript?.language
        let resolution = model.resolveAI(task, languageCode: language)
        VStack(alignment: .leading, spacing: 12) {
            Text(task == .correction ? L("rewrite.correction.title") : L("rewrite.polish.title"))
                .appFont(.title2, weight: .semibold)
            Text(task == .correction ? L("rewrite.correction.message") : L("rewrite.polish.message"))
                .appFont(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                Picker(L("rewrite.mode"), selection: $settings.aiRewriteMode) {
                    ForEach(AIRewriteMode.allCases) { Text($0.shortName).tag($0) }
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .disabled(busy)
                Spacer()
                if busy {
                    ProgressView(value: progress).frame(width: 120)
                    Button(L("common.cancel")) { job?.cancel() }
                } else {
                    Button(outcome == nil ? L("rewrite.run") : L("analysis.rerun")) { run() }
                        .buttonStyle(.borderedProminent)
                        .disabled(resolution.engine == nil || item?.transcript == nil)
                }
            }
            .controlSize(.small)
            EngineLine(resolution: resolution, openSettings: { openSettings() })
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .appFont(.callout).foregroundStyle(.red).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            content
            Text(L("rewrite.rules"))
                .appFont(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                if !applied.isEmpty {
                    Button(L("rewrite.undoThisRun", applied.count)) {
                        for c in applied { model.restoreSegment(itemID, index: c.index) }
                        applied = []
                    }
                }
                Spacer()
                if let outcome, model.settings.aiRewriteMode == .review, applied.isEmpty {
                    let accepted = outcome.candidates.filter { !rejectedByUser.contains($0.index) }
                    Button(L("rewrite.applySelected", accepted.count)) {
                        model.applyRewrites(itemID, Dictionary(accepted.map { ($0.index, $0.rewritten) }, uniquingKeysWith: { a, _ in a }))
                        applied = accepted
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(accepted.isEmpty)
                }
                Button(L("common.close")) { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 680, height: 640)
        .onDisappear { job?.cancel() }
    }

    @ViewBuilder
    private var content: some View {
        if let outcome {
            let shown = applied.isEmpty ? outcome.candidates : applied
            if shown.isEmpty {
                ContentUnavailableView(L("rewrite.none"), systemImage: "checkmark.circle")
            } else {
                List {
                    ForEach(shown) { candidate in
                        CandidateRow(candidate: candidate,
                                     state: rowState(candidate),
                                     onToggle: {
                                         if rejectedByUser.contains(candidate.index) { rejectedByUser.remove(candidate.index) }
                                         else { rejectedByUser.insert(candidate.index) }
                                     },
                                     onRestore: {
                                         model.restoreSegment(itemID, index: candidate.index)
                                         applied.removeAll { $0.index == candidate.index }
                                     })
                    }
                }
                .frame(minHeight: 240)
            }
            if !outcome.rejected.isEmpty {
                DisclosureGroup(L("rewrite.rejectedByGuard", outcome.rejected.count), isExpanded: $showRejected) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(Array(outcome.rejected.enumerated()), id: \.offset) { _, r in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(r.rewritten).appFont(.callout).foregroundStyle(.secondary).strikethrough()
                                    Text(r.violations.map(\.message).joined(separator: " / "))
                                        .appFont(.caption).foregroundStyle(.orange)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 120)
                }
                .appFont(.caption)
            }
        } else {
            Spacer(minLength: 0)
        }
    }

    private func rowState(_ c: RewriteCandidate) -> CandidateRow.State {
        if applied.contains(where: { $0.index == c.index }) { return .applied }
        return rejectedByUser.contains(c.index) ? .rejected : .accepted
    }

    private func run() {
        guard let item = model.queue.item(itemID), let original = item.transcript else { return }
        error = nil
        busy = true
        progress = 0
        outcome = nil
        applied = []
        rejectedByUser = []
        let lines = LocalAIText.lines(original: original, edits: item.annotations.edits, speakerNames: [:])
        // 誤認識の修正には、確からしさが低い語を手がかりとして渡す（書き換えていない区間だけ）
        var suspicious: [Int: [String]] = [:]
        if task == .correction {
            for (i, segment) in original.segments.enumerated() where item.annotations.edits.state(at: i) == .original {
                let words = ReviewCandidateFinder.lowConfidenceSpans(in: segment, threshold: model.settings.reviewThreshold.value).map(\.text)
                if !words.isEmpty { suspicious[i] = words }
            }
        }
        let task = task
        let language = original.language
        let mode = model.settings.aiRewriteMode
        job = Task {
            defer { busy = false; job = nil }
            do {
                let generator = try await model.textGenerator(for: task, languageCode: language)
                let result = try await AITaskRunner.rewrite(task, lines: lines, suspicious: suspicious, generator: generator,
                                                            languageCode: language) { value in
                    Task { @MainActor in progress = value }
                }
                outcome = result
                if mode == .automatic, !result.candidates.isEmpty {
                    model.applyRewrites(itemID, Dictionary(result.candidates.map { ($0.index, $0.rewritten) },
                                                           uniquingKeysWith: { a, _ in a }))
                    applied = result.candidates
                }
            } catch is CancellationError {
            } catch {
                self.error = userFacingMessage(for: error)
            }
        }
    }
}

/// 候補 1 つ（差分の表示と、採用・却下・原文に戻す）
private struct CandidateRow: View {
    enum State { case accepted, rejected, applied }
    let candidate: RewriteCandidate
    let state: State
    let onToggle: () -> Void
    let onRestore: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(DiffText.attributed(candidate.diff))
                    .appFont(.body)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .opacity(state == .rejected ? 0.5 : 1)
                Text(L("editor.originalText", candidate.original))
                    .appFont(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            switch state {
            case .applied:
                Button(L("editor.restore"), action: onRestore).controlSize(.small)
            case .accepted, .rejected:
                Toggle(isOn: Binding(get: { state == .accepted }, set: { _ in onToggle() })) {
                    Text(state == .accepted ? L("rewrite.accept") : L("rewrite.reject"))
                }
                .toggleStyle(.checkbox)
                .fixedSize()
            }
        }
        .padding(.vertical, 2)
    }
}

/// 差分の表示（消えた部分は取り消し線、増えた部分は下線。色だけに頼らない）
enum DiffText {
    static func attributed(_ pieces: [TextDiff.Piece]) -> AttributedString {
        var out = AttributedString()
        for piece in pieces {
            var part = AttributedString(piece.text)
            switch piece.kind {
            case .same:
                break
            case .removed:
                part.strikethroughStyle = .single
                part.foregroundColor = .red
            case .added:
                part.underlineStyle = .single
                part.foregroundColor = .green
                part.font = .body.bold()
            }
            out += part
        }
        return out
    }
}
