import SwiftUI
import WhisperBatchCore
import WhisperBatchEngine

/// 設定の「AI モデル」（Vantage だけ）: 使うモデルの選び方と、ローカルの言語モデルの取得・削除・更新。
///
/// - モデルの取得は、利用者がこの画面で選んで確認したときだけ行う（自動では取得しない。更新も同じ）。
/// - 取得したファイルは SHA-256 で照合してから使えるようにする。読み込む前にも照合する。
/// - 推論のときに読み込むモデルは 1 つだけ。別のモデルを使うと前のモデルを解放する。
struct AIModelSettingsTab: View {
    @Environment(AppModel.self) private var model
    @ViewState private var category: LLMCategory?
    @ViewState private var downloadTarget: LocalLLM?
    @ViewState private var deleteTarget: LocalLLM?
    @ViewState private var errorMessage: String?

    var body: some View {
        @Bindable var settings = model.settings
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Label(L("ai.settings.privacy"), systemImage: "lock.shield")
                    .appFont(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        Picker(L("ai.settings.selection"), selection: $settings.aiSelectionMode) {
                            ForEach(AISelectionMode.allCases) { Text($0.displayName).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        Text(L("ai.selection.\(settings.aiSelectionMode.rawValue).note"))
                            .appFont(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        switch settings.aiSelectionMode {
                        case .automatic:
                            EmptyView()
                        case .common:
                            ChoicePicker(title: L("ai.settings.commonModel"), task: nil, choice: $settings.aiCommonChoice)
                        case .perTask:
                            ForEach(AITask.allCases) { task in
                                ChoicePicker(title: task.displayName, task: task, choice: Binding(
                                    get: { settings.aiTaskChoices[task] ?? .automatic },
                                    set: { settings.aiTaskChoices[task] = $0 }
                                ))
                            }
                        }
                        Divider()
                        ResolutionPreview()
                        Divider()
                        Picker(L("rewrite.mode"), selection: $settings.aiRewriteMode) {
                            ForEach(AIRewriteMode.allCases) { Text($0.displayName).tag($0) }
                        }
                        .pickerStyle(.radioGroup)
                        Text(L("ai.settings.rewriteMode.note"))
                            .appFont(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        LoadedModelLine()
                    }
                    .padding(6)
                } label: {
                    Text(L("ai.settings.usage")).appFont(.headline)
                }

                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Picker(L("ai.settings.filter"), selection: $category) {
                                Text(L("ai.settings.filter.all")).tag(LLMCategory?.none)
                                ForEach(LLMCategory.allCases) { Text($0.displayName).tag(LLMCategory?.some($0)) }
                            }
                            .fixedSize()
                            Spacer()
                            Text(L("ai.settings.storage", model.models.storagePath))
                                .appFont(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        ForEach(LocalLLMCatalog.all.filter { category == nil || $0.categories.contains(category!) }) { llm in
                            LLMRow(llm: llm, downloadTarget: $downloadTarget, deleteTarget: $deleteTarget)
                            Divider()
                        }
                        if let errorMessage {
                            Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.red).appFont(.callout)
                        }
                        Text(L("ai.settings.list.note", LLMRuntime.llamaCpp.displayName))
                            .appFont(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(6)
                } label: {
                    Text(L("ai.settings.models")).appFont(.headline)
                }
            }
            .padding(20)
        }
        .frame(width: 720, height: 640)
        .onAppear { model.models.refresh() }
        .alert(L("ai.download.title"), isPresented: Binding(get: { downloadTarget != nil }, set: { if !$0 { downloadTarget = nil } }),
               presenting: downloadTarget) { target in
            Button(L("download.confirm.download")) { model.models.download(target.downloadModel) }
            Button(L("common.cancel"), role: .cancel) {}
        } message: { target in
            Text(downloadMessage(target))
        }
        .alert(L("models.delete.title"), isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } }),
               presenting: deleteTarget) { target in
            Button(L("models.delete.confirm"), role: .destructive) {
                Task {
                    do { try await model.deleteLLM(target) } catch { errorMessage = userFacingMessage(for: error) }
                }
            }
            Button(L("common.cancel"), role: .cancel) {}
        } message: { target in
            Text(L("models.delete.message", target.displayName, sizeText(target.file.sizeBytes)))
        }
    }

    private func downloadMessage(_ m: LocalLLM) -> String {
        var text = L("ai.download.message", m.displayName, sizeText(m.file.sizeBytes), "huggingface.co/\(m.repository)",
                     String(m.revision.prefix(12)), m.license.name, sizeText(m.estimatedMemoryBytes), model.models.storagePath)
        if let note = m.note { text += "\n\n" + note }
        return text
    }
}

private func sizeText(_ bytes: Int64) -> String { ByteCountFormatter.fileSize.string(fromByteCount: bytes) }

/// 使うものを選ぶ（自動・Apple Intelligence・ローカルのモデル）
private struct ChoicePicker: View {
    @Environment(AppModel.self) private var model
    let title: String
    /// 用途（nil は言語共通）
    let task: AITask?
    @Binding var choice: AIModelChoice

    var body: some View {
        let installed = model.installedLLMIDs
        let models = LocalLLMCatalog.all.filter { m in
            guard let task else { return !m.isTranslationOnly }
            return m.tasks.contains(task)
        }
        LabeledContent(title) {
            Picker(title, selection: $choice) {
                Text(L("ai.choice.automatic")).tag(AIModelChoice.automatic)
                if task != .translation {
                    Text(L("ai.choice.apple")).tag(AIModelChoice.appleIntelligence)
                }
                Divider()
                ForEach(models) { m in
                    Text((installed.contains(m.id) ? "✓ " : "") + m.displayName).tag(AIModelChoice.model(m.id))
                }
            }
            .labelsHidden()
            .frame(maxWidth: 300)
        }
    }
}

/// 今の設定で、言語と用途ごとに使われるもの（ないときは案内）
private struct ResolutionPreview: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let languages = Array(Set(["ja", "en", model.language.code].compactMap { $0 })).sorted()
        VStack(alignment: .leading, spacing: 4) {
            Text(L("ai.settings.preview")).appFont(.caption, weight: .semibold)
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 3) {
                ForEach(languages, id: \.self) { lang in
                    GridRow {
                        Text(LanguageOption.displayName(forCode: lang)).foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            ForEach(AITask.allCases) { task in
                                let r = model.resolveAI(task, languageCode: lang)
                                HStack(alignment: .firstTextBaseline, spacing: 4) {
                                    Text(task.displayName + ":").foregroundStyle(.secondary)
                                    switch r {
                                    case .local(let m): Text(m.displayName)
                                    case .appleIntelligence: Text(AITextEngine.appleIntelligence.displayName)
                                    case .unavailable(let g): Text(g.message).foregroundStyle(.orange)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .appFont(.caption)
        }
    }
}

/// 読み込んでいるローカルのモデル（解放のボタン）
private struct LoadedModelLine: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 8) {
            if let id = model.loadedAIModelID, let m = LocalLLMCatalog.model(id: id) {
                Label(L("ai.settings.loaded", m.displayName), systemImage: "memorychip")
                    .appFont(.caption)
                Button(L("ai.settings.release")) { model.releaseAIModel() }
                    .controlSize(.small)
            } else {
                Label(L("ai.settings.notLoaded"), systemImage: "memorychip")
                    .appFont(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// ローカルの言語モデル 1 つ（用途・容量・量子化・ライセンス・配布元・動作の確認と、取得・削除・更新）
private struct LLMRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    let llm: LocalLLM
    @Binding var downloadTarget: LocalLLM?
    @Binding var deleteTarget: LocalLLM?

    var body: some View {
        let state = model.models.state(for: llm.downloadModel)
        let installation = model.models.llmInstallation(llm)
        let fits = LocalLLMCatalog.fitsInMemory(llm)
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(llm.displayName).appFont(.body, weight: .medium)
                    ForEach(LLMCategory.allCases.filter { llm.categories.contains($0) }) { c in
                        Text(c.displayName)
                            .appFont(.caption2, weight: .semibold)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color.accentColor.opacity(0.12), in: Capsule())
                    }
                }
                Text(L("ai.row.details", llm.publisher, llm.parameters, llm.quantization, sizeText(llm.file.sizeBytes),
                       sizeText(llm.estimatedMemoryBytes)))
                    .appFont(.caption)
                    .foregroundStyle(.secondary)
                Text(L("ai.row.tasks", AITask.allCases.filter { llm.tasks.contains($0) }.map(\.displayName)
                        .joined(separator: L("list.separator"))))
                    .appFont(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    Button(L("ai.row.license", llm.license.name)) { openURL(llm.license.url) }
                        .buttonStyle(.link)
                    Button(L("ai.row.source", llm.repository, String(llm.revision.prefix(7)))) { openURL(llm.sourceURL) }
                        .buttonStyle(.link)
                }
                .appFont(.caption)
                Text(llm.runtime.displayName + " · " + llm.verification.displayName)
                    .appFont(.caption2)
                    .foregroundStyle(llm.verification == .verified ? Color.secondary : Color.orange)
                if let note = llm.note {
                    Text(note).appFont(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if !fits {
                    Text(L("ai.guidance.tooLarge", llm.displayName)).appFont(.caption).foregroundStyle(.orange)
                }
                stateLine(state, installation: installation)
            }
            Spacer(minLength: 8)
            actions(state, installation: installation, fits: fits)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func stateLine(_ state: ModelManager.State, installation: ModelInstallation) -> some View {
        switch state {
        case .downloading(let received, let total):
            let fraction = total > 0 ? Double(received) / Double(total) : 0
            ProgressView(value: fraction) {
                EmptyView()
            } currentValueLabel: {
                Text(L("models.row.progress", Int(fraction * 100), sizeText(received), sizeText(total))).monospacedDigit()
            }
            .controlSize(.small)
            .frame(maxWidth: 320)
        case .verifying:
            Text(L("models.state.verifyingShort")).appFont(.caption).foregroundStyle(.secondary)
        case .failed(let message, _):
            Text(message).appFont(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
        default:
            switch installation {
            case .current:
                Label(L("ai.row.installed"), systemImage: "checkmark.circle.fill").appFont(.caption).foregroundStyle(.green)
            case .outdated(_, let revision):
                Label(L("ai.row.updateAvailable", String(revision.prefix(7)), String(llm.revision.prefix(7))),
                      systemImage: "arrow.triangle.2.circlepath").appFont(.caption).foregroundStyle(.orange)
            case .notInstalled:
                Text(L("model.state.notInstalled")).appFont(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func actions(_ state: ModelManager.State, installation: ModelInstallation, fits: Bool) -> some View {
        VStack(alignment: .trailing, spacing: 6) {
            switch state {
            case .downloading:
                Button(L("model.stop")) { model.models.cancelDownload(llm.downloadModel) }
            case .verifying:
                EmptyView()
            case .failed(_, let canResume):
                if canResume {
                    Button(L("model.resume")) { model.models.download(llm.downloadModel) }
                    Button(L("ai.row.restart")) {
                        model.models.discardResume(llm.downloadModel)
                        downloadTarget = llm
                    }
                } else {
                    Button(L("model.retry")) { downloadTarget = llm }
                }
            default:
                switch installation {
                case .notInstalled:
                    Button(L("model.download")) { downloadTarget = llm }
                        .disabled(!fits)
                case .outdated:
                    // 更新は利用者が選んだときだけ（以前のリビジョンは更新するまで使える）
                    Button(L("ai.row.update")) { downloadTarget = llm }
                    Button(L("models.delete")) { deleteTarget = llm }
                case .current:
                    Button(L("models.delete")) { deleteTarget = llm }
                }
            }
        }
        .controlSize(.small)
    }
}
