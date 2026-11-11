import SwiftUI
import WhisperBatchCore

/// フィラーの除去: 変わる区間を確かめてから反映する（反映した後も原文に戻せる）
struct FillerSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let itemID: UUID
    @ViewState private var excluded: Set<Int> = []

    var body: some View {
        let item = model.queue.item(itemID)
        let changes = item.flatMap { item in
            item.transcript.map { FillerRemover.changes(in: $0, edits: item.annotations.edits, extra: model.settings.extraFillerWords) }
        } ?? []
        let selected = changes.filter { !excluded.contains($0.index) }
        VStack(alignment: .leading, spacing: 12) {
            Text(L("fillers.title")).appFont(.title2, weight: .semibold)
            Text(L("fillers.message"))
                .appFont(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if changes.isEmpty {
                ContentUnavailableView(L("fillers.none"), systemImage: "checkmark.circle")
            } else {
                List {
                    ForEach(changes, id: \.index) { change in
                        Toggle(isOn: Binding(
                            get: { !excluded.contains(change.index) },
                            set: { if $0 { excluded.remove(change.index) } else { excluded.insert(change.index) } }
                        )) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(change.before).strikethrough().foregroundStyle(.secondary).appFont(.caption)
                                Text(change.after).appFont(.callout)
                            }
                        }
                        .toggleStyle(.checkbox)
                    }
                }
                .frame(minHeight: 260)
            }
            Text(L("fillers.extra.note", model.settings.extraFillerWords.isEmpty
                     ? L("fillers.extra.none") : model.settings.extraFillerWords.joined(separator: L("list.separator"))))
                .appFont(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button(L("common.cancel"), role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L("fillers.apply", selected.count)) {
                    model.applyRewrites(itemID, Dictionary(selected.map { ($0.index, $0.after) }, uniquingKeysWith: { a, _ in a }))
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(selected.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 560, height: 520)
    }
}
