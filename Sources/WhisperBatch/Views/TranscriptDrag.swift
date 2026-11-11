import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WhisperBatchCore
import WhisperBatchEngine

/// 結果をファイルとしてドラッグで書き出す取っ手（Finder やほかのアプリへドロップできる）。
/// 書き出す形式は右の小さなメニューで選ぶ。編集・話者名・要約を反映する。
struct TranscriptDragHandle: View {
    let item: QueueItem
    let includeTimestamps: Bool
    @AppStorage("drag.format") private var formatRaw = ExportFormat.plainText.rawValue

    private var format: ExportFormat { ExportFormat(rawValue: formatRaw) ?? .plainText }

    var body: some View {
        HStack(spacing: 0) {
            Label(L("drag.handle", format.fileExtension), systemImage: "doc.text")
                .appFont(.caption)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 5))
                .onDrag { TranscriptDragProvider.provider(for: item, format: format, includeTimestamps: includeTimestamps) }
                .help(L("drag.handle.help"))
                .accessibilityLabel(L("drag.handle.accessibility"))
            Menu {
                ForEach(ExportFormat.allCases) { f in
                    Button {
                        formatRaw = f.rawValue
                    } label: {
                        if f == format { Label(f.displayName, systemImage: "checkmark") } else { Text(f.displayName) }
                    }
                }
            } label: {
                EmptyView()
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help(L("drag.format.help"))
            .accessibilityLabel(L("drag.format.help"))
        }
        .fixedSize()
    }
}

enum TranscriptDragProvider {
    /// ドロップされたときに、一時フォルダにファイルを作って渡す
    @MainActor
    static func provider(for item: QueueItem, format: ExportFormat, includeTimestamps: Bool) -> NSItemProvider {
        let provider = NSItemProvider()
        guard let transcript = item.editedTranscript else { return provider }
        let text = TranscriptFormatter.format(transcript, as: format, includeTimestamps: includeTimestamps,
                                              context: item.exportContext)
        let name = ExportNaming.baseName(for: item.displayName, format: format)
        provider.suggestedName = name
        let type = ExportService.contentType(for: format)
        provider.registerFileRepresentation(forTypeIdentifier: type.identifier, fileOptions: [], visibility: .all) { completion in
            do {
                completion(try DragExportWorkspace.write(text, fileName: name), false, nil)
            } catch {
                completion(nil, false, error)
            }
            return nil
        }
        return provider
    }
}
