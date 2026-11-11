import SwiftUI
import WhisperBatchCore
import WhisperBatchEngine

/// 要約・重要な発言・翻訳（Vantage）。どれもこの Mac の中で処理する。
///
/// - AI: 設定の「AI モデル」の選び方に従って、ローカルの言語モデルか Apple Intelligence（端末内のモデル）を使う。
///   必要なモデルがなければ、取得はせずに案内する。
/// - 簡易抽出（AI なし）: 文字起こしの文から選ぶ（言い換えない）。どの Mac でも使える。
struct AnalysisSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openSettings) private var openSettings
    let target: AppModel.AnalysisTarget

    @AppStorage("analysis.useAI") private var useAI = true
    @AppStorage("analysis.translationTarget") private var translationTarget = "en"
    @ViewState private var busy: Job?
    @ViewState private var progress = 0.0
    @ViewState private var error: String?
    @ViewState private var task: Task<Void, Never>?

    enum Job: Equatable { case summary, keyPoints, translation }

    var body: some View {
        let transcript = model.analysisTranscript(target)
        let language = transcript?.language
        let summaryResolution = model.resolveAI(.summary, languageCode: language)
        let translationResolution = model.resolveAI(.translation, languageCode: language)
        let analysis = model.analysis(target)
        VStack(alignment: .leading, spacing: 12) {
            Text(L("analysis.title")).appFont(.title2, weight: .semibold)
            Picker(L("analysis.method"), selection: $useAI) {
                Text(L("analysis.method.ai")).tag(true)
                Text(AnalysisMethod.extractive.displayName).tag(false)
            }
            .pickerStyle(.segmented)
            .fixedSize()
            .disabled(busy != nil)
            EngineLine(resolution: useAI ? summaryResolution : nil, openSettings: { openSettings() })
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .appFont(.callout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    summarySection(analysis: analysis, transcript: transcript,
                                   enabled: !useAI || summaryResolution.engine != nil)
                    keyPointSection(analysis: analysis, transcript: transcript,
                                    enabled: !useAI || summaryResolution.engine != nil)
                    if model.has(.translation) {
                        translationSection(analysis: analysis, transcript: transcript, resolution: translationResolution)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Text(L("analysis.footer"))
                .appFont(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                if !analysis.isEmpty {
                    Button(L("analysis.clear"), role: .destructive) {
                        model.updateAnalysis(target) { $0 = TranscriptAnalysis() }
                    }
                    .disabled(busy != nil)
                }
                Spacer()
                Button(L("common.close")) { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 660, height: 680)
        .onDisappear { task?.cancel() }
    }

    // MARK: 要約

    private func summarySection(analysis: TranscriptAnalysis, transcript: Transcript?, enabled: Bool) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    if let made = analysis.summaryEngine ?? analysis.summaryMethod?.displayName, !analysis.summary.isEmpty {
                        Text(L("markdown.madeWith", made)).appFont(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if busy == .summary {
                        jobProgress
                    } else {
                        if !analysis.summary.isEmpty {
                            Button(L("detail.copy")) { copy(analysis.summary.map { "- \($0)" }.joined(separator: "\n")) }
                        }
                        Button(analysis.summary.isEmpty ? L("analysis.summary.run") : L("analysis.rerun")) { run(.summary) }
                            .disabled(transcript == nil || busy != nil || !enabled)
                    }
                }
                .controlSize(.small)
                if analysis.summary.isEmpty {
                    Text(L("analysis.summary.empty")).appFont(.callout).foregroundStyle(.secondary)
                } else {
                    ForEach(Array(analysis.summary.enumerated()), id: \.offset) { _, line in
                        Text("• " + line).appFont(.body).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(6)
        } label: {
            Text(L("markdown.summary")).appFont(.headline)
        }
    }

    // MARK: 重要な発言

    private func keyPointSection(analysis: TranscriptAnalysis, transcript: Transcript?, enabled: Bool) -> some View {
        let names: [Int: String] = if case .item(let id) = target { model.queue.item(id)?.annotations.speakerNames ?? [:] } else { [:] }
        return GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    if let made = analysis.keyPointsEngine ?? analysis.keyPointsMethod?.displayName, !analysis.keyPoints.isEmpty {
                        Text(L("markdown.madeWith", made)).appFont(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if busy == .keyPoints {
                        jobProgress
                    } else {
                        if !analysis.keyPoints.isEmpty {
                            Button(L("detail.copy")) {
                                copy(analysis.keyPoints.map { p in
                                    var line = "- "
                                    if let start = p.start { line += "[\(TranscriptFormatter.clock(start))] " }
                                    if let s = p.speaker { line += SpeakerNaming.displayName(s, names: names) + ": " }
                                    return line + p.text
                                }.joined(separator: "\n"))
                            }
                        }
                        Button(analysis.keyPoints.isEmpty ? L("analysis.keyPoints.run") : L("analysis.rerun")) { run(.keyPoints) }
                            .disabled(transcript == nil || busy != nil || !enabled)
                    }
                }
                .controlSize(.small)
                if analysis.keyPoints.isEmpty {
                    Text(L("analysis.keyPoints.empty")).appFont(.callout).foregroundStyle(.secondary)
                } else {
                    ForEach(Array(analysis.keyPoints.enumerated()), id: \.offset) { _, point in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(point.start.map(TranscriptFormatter.clock) ?? "")
                                .appFont(.caption, monospacedDigit: true)
                                .foregroundStyle(.secondary)
                                .frame(minWidth: 40, alignment: .leading)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    if let s = point.speaker {
                                        Text(SpeakerNaming.displayName(s, names: names))
                                            .appFont(.caption, weight: .semibold)
                                            .foregroundStyle(SpeakerPalette.color(s))
                                    }
                                    ForEach(point.reasons, id: \.self) { reason in
                                        Text(reason.displayName)
                                            .appFont(.caption)
                                            .padding(.horizontal, 5)
                                            .background(.quaternary, in: Capsule())
                                    }
                                }
                                Text(point.text).appFont(.body).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }
            .padding(6)
        } label: {
            Text(L("markdown.keyPoints")).appFont(.headline)
        }
    }

    // MARK: 翻訳（AI だけ。原文は変えない）

    private func translationSection(analysis: TranscriptAnalysis, transcript: Transcript?, resolution: AIModelResolution) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Picker(L("analysis.translation.target"), selection: $translationTarget) {
                        ForEach(LanguageOption.allCases.compactMap(\.code), id: \.self) { code in
                            Text(LanguageOption.displayName(forCode: code)).tag(code)
                        }
                    }
                    .fixedSize()
                    Spacer()
                    if busy == .translation {
                        jobProgress
                    } else {
                        if !analysis.translation.isEmpty {
                            Button(L("detail.copy")) { copy(analysis.translation.joined(separator: "\n")) }
                        }
                        Button(analysis.translation.isEmpty ? L("analysis.translation.run") : L("analysis.rerun")) { run(.translation) }
                            .disabled(transcript == nil || busy != nil || resolution.engine == nil)
                    }
                }
                .controlSize(.small)
                EngineLine(resolution: resolution, openSettings: { openSettings() })
                if analysis.translation.isEmpty {
                    Text(L("analysis.translation.empty")).appFont(.callout).foregroundStyle(.secondary)
                } else {
                    if let made = analysis.translationEngine {
                        Text(L("markdown.madeWith", made)).appFont(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(Array(analysis.translation.enumerated()), id: \.offset) { _, text in
                        Text(text).appFont(.body).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(6)
        } label: {
            Text(L("analysis.translation.title")).appFont(.headline)
        }
    }

    private var jobProgress: some View {
        HStack(spacing: 6) {
            ProgressView(value: progress).frame(width: 100)
            Button(L("common.cancel")) { task?.cancel() }
        }
    }

    // MARK: 実行

    private func run(_ job: Job) {
        guard busy == nil, let transcript = model.analysisTranscript(target) else { return }
        error = nil
        busy = job
        progress = 0
        let lines = model.analysisLines(target)
        let segments: [TranscriptSegment] = switch target {
        case .item(let id): model.queue.item(id)?.transcript?.segments ?? []
        case .live: model.live.session.transcript.confirmed
        }
        let target = target
        let useAI = job == .translation || useAI
        let translationTarget = translationTarget
        task = Task {
            defer { busy = nil; task = nil }
            let report: @Sendable (Double) -> Void = { value in Task { @MainActor in progress = value } }
            do {
                guard useAI else {
                    // 簡易抽出（AI なし）
                    if job == .summary {
                        let summary = ExtractiveSummarizer.summarize(transcript).map(\.text)
                        model.updateAnalysis(target) {
                            $0.summary = summary; $0.summaryMethod = .extractive; $0.summaryEngine = nil
                        }
                    } else {
                        let points = KeyStatementExtractor.extract(transcript)
                        model.updateAnalysis(target) {
                            $0.keyPoints = points; $0.keyPointsMethod = .extractive; $0.keyPointsEngine = nil
                        }
                    }
                    return
                }
                let aiTask: AITask = job == .translation ? .translation : .summary
                let method: AnalysisMethod = model.resolveAI(aiTask, languageCode: transcript.language) == .appleIntelligence
                    ? .onDeviceAI : .localModel
                let generator = try await model.textGenerator(for: aiTask, languageCode: transcript.language)
                switch job {
                case .summary:
                    let summary = try await AITaskRunner.summarize(lines, generator: generator, languageCode: transcript.language,
                                                                   progress: report)
                    model.updateAnalysis(target) {
                        $0.summary = summary; $0.summaryMethod = method; $0.summaryEngine = generator.displayName
                    }
                case .keyPoints:
                    let points = try await AITaskRunner.keyPoints(lines, segments: segments, generator: generator,
                                                                  languageCode: transcript.language, progress: report)
                    model.updateAnalysis(target) {
                        $0.keyPoints = points; $0.keyPointsMethod = method; $0.keyPointsEngine = generator.displayName
                    }
                case .translation:
                    let translated = try await AITaskRunner.translate(lines, generator: generator, source: transcript.language,
                                                                      target: translationTarget, progress: report)
                    model.updateAnalysis(target) {
                        $0.translation = translated; $0.translationLanguage = translationTarget
                        $0.translationEngine = generator.displayName
                    }
                }
            } catch is CancellationError {
            } catch {
                self.error = userFacingMessage(for: error)
            }
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// 使うもの（モデル）の表示。使えないときは案内と、設定を開くボタン。
struct EngineLine: View {
    let resolution: AIModelResolution?
    let openSettings: () -> Void

    var body: some View {
        switch resolution {
        case nil:
            Text(L("analysis.method.extractive.note"))
                .appFont(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        case .local(let llm):
            Label(L("ai.engine.using", AITextEngine.local(llm).displayName), systemImage: "cpu")
                .appFont(.caption)
                .foregroundStyle(.secondary)
        case .appleIntelligence:
            Label(L("ai.engine.using", AITextEngine.appleIntelligence.displayName), systemImage: "apple.intelligence")
                .appFont(.caption)
                .foregroundStyle(.secondary)
        case .unavailable(let guidance):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Label(guidance.message, systemImage: "info.circle")
                    .appFont(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                Button(L("ai.openModelSettings"), action: openSettings)
                    .controlSize(.small)
            }
        }
    }
}
