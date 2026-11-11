import SwiftUI
import WhisperBatchCore
import WhisperBatchEngine

/// 話者識別: 実行・話者名の変更・話者ごとの発言一覧
struct SpeakerSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let itemID: UUID
    @AppStorage("speakers.count") private var speakerCount = 0
    @ViewState private var expanded: Set<Int> = []
    @ViewState private var confirmClear = false
    @ViewState private var showDownloadConfirmation = false

    var body: some View {
        let item = model.queue.item(itemID)
        VStack(alignment: .leading, spacing: 12) {
            Text(L("speakers.title")).appFont(.title2, weight: .semibold)
            if let item {
                Text(item.displayName).appFont(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                setup(item)
                Divider()
                if item.hasSpeakers, let transcript = item.transcript {
                    speakerList(item: item, transcript: transcript)
                } else {
                    Text(L("speakers.notYet"))
                        .appFont(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            Text(L("speakers.note"))
                .appFont(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                if item?.hasSpeakers == true {
                    Button(L("speakers.clear"), role: .destructive) { confirmClear = true }
                }
                Spacer()
                Button(L("common.close")) { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 600, height: 600)
        // モデルの取得前の確認（取得先・サイズ・保存先を示す。メインウインドウと同じ内容）
        .alert(DownloadConfirmation.title(for: ModelCatalog.speakerDiarization), isPresented: $showDownloadConfirmation) {
            Button(L("download.confirm.download")) { model.models.download(ModelCatalog.speakerDiarization) }
            Button(L("common.cancel"), role: .cancel) {}
        } message: {
            Text(DownloadConfirmation.message(for: ModelCatalog.speakerDiarization, model: model))
        }
        .onAppear { model.models.refresh() }
        .alert(L("speakers.clear.confirm"), isPresented: $confirmClear) {
            Button(L("speakers.clear"), role: .destructive) { model.clearSpeakers(itemID) }
            Button(L("common.cancel"), role: .cancel) {}
        }
    }

    /// モデルの取得・話者の数・実行
    @ViewBuilder
    private func setup(_ item: QueueItem) -> some View {
        let diarModel = ModelCatalog.speakerDiarization
        let state = model.models.state(for: diarModel)
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                switch state {
                case .installed:
                    HStack(spacing: 10) {
                        Picker(L("speakers.count"), selection: $speakerCount) {
                            Text(L("speakers.count.auto")).tag(0)
                            ForEach(2 ... 8, id: \.self) { Text(L("speakers.count.n", $0)).tag($0) }
                        }
                        .fixedSize()
                        Spacer(minLength: 0)
                        if model.speakerJobs[itemID] != nil {
                            ProgressView().controlSize(.small)
                            Button(L("common.cancel")) { model.cancelSpeakerIdentification(itemID) }
                        } else {
                            Button(item.hasSpeakers ? L("speakers.rerun") : L("speakers.run")) {
                                model.identifySpeakers(itemID, speakerCount: speakerCount == 0 ? nil : speakerCount)
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                    Text(L("speakers.count.note")).appFont(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if item.hasSpeakers, model.speakerJobs[itemID] == nil {
                        Text(L("speakers.rerun.note")).appFont(.caption).foregroundStyle(.secondary)
                    }
                case .downloading(let received, let total):
                    ProgressView(value: total > 0 ? Double(received) / Double(total) : 0) {
                        Text(L("speakers.model.downloading"))
                    }
                    Button(L("model.stop")) { model.models.cancelDownload(diarModel) }.controlSize(.small)
                case .verifying:
                    ProgressView { Text(L("model.verifying")) }
                case .failed(let message, _):
                    Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.red).appFont(.callout)
                    Button(L("model.download")) { showDownloadConfirmation = true }
                default:
                    Text(L("speakers.model.needed", diarModel.sizeText))
                        .appFont(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(L("model.download")) { showDownloadConfirmation = true }
                }
            }
            .padding(6)
        }
    }

    /// 話者ごとの集計・名前・発言一覧
    private func speakerList(item: QueueItem, transcript: Transcript) -> some View {
        let stats = SpeakerStatistics.make(transcript)
        let total = max(stats.map(\.duration).reduce(0, +), 0.001)
        let edits = item.annotations.edits
        return List {
            ForEach(stats) { s in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Circle().fill(SpeakerPalette.color(s.speaker)).frame(width: 10, height: 10)
                        TextField(L("speakers.name.placeholder", s.speaker + 1), text: Binding(
                            get: { item.annotations.speakerNames[s.speaker] ?? "" },
                            set: { model.setSpeakerName(itemID, speaker: s.speaker, name: $0) }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 200)
                        .accessibilityLabel(L("speakers.name.accessibility", s.speaker + 1))
                        Text(L("speakers.stats", s.segmentCount, TranscriptFormatter.clock(s.duration),
                               Int((s.duration / total * 100).rounded())))
                            .appFont(.caption, monospacedDigit: true)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                    }
                    Button {
                        if expanded.contains(s.speaker) { expanded.remove(s.speaker) } else { expanded.insert(s.speaker) }
                    } label: {
                        Label(L("speakers.statements"), systemImage: expanded.contains(s.speaker) ? "chevron.down" : "chevron.right")
                            .appFont(.caption)
                    }
                    .buttonStyle(.borderless)
                    if expanded.contains(s.speaker) {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(transcript.segments.indices.filter { transcript.segments[$0].speaker == s.speaker }, id: \.self) { i in
                                if let text = edits.text(at: i, in: transcript) {
                                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                                        Text(TranscriptFormatter.clock(transcript.segments[i].start))
                                            .appFont(.caption, monospacedDigit: true)
                                            .foregroundStyle(.secondary)
                                        Text(text).appFont(.callout).textSelection(.enabled)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                            }
                        }
                        .padding(.leading, 18)
                        .padding(.vertical, 4)
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .frame(minHeight: 260)
    }
}
