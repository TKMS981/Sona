import AppKit
import SwiftUI
import WhisperBatchCore
import WhisperBatchEngine

/// ライブ文字起こしのウインドウ
struct LiveTranscriptionView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.motion) private var motion

    private var live: LiveController { model.live }

    var body: some View {
        @Bindable var live = model.live
        VStack(spacing: 0) {
            LiveHeader()
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
            Divider()
            Group {
                if live.state == .idle || live.state == .preparing {
                    ScrollView { LiveSetupForm().padding(18) }
                } else {
                    LiveSessionBody()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(motion.resultAnimation, value: live.state == .idle)
            Divider()
            LiveFooter()
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
        }
        .modifier(LivePanelBackground())
        .sheet(isPresented: $live.showConfirmation) {
            LiveConfirmationSheet()
        }
        .alert(
            live.alert?.title ?? "",
            isPresented: Binding(get: { live.alert != nil }, set: { if !$0 { live.alert = nil } }),
            presenting: live.alert
        ) { _ in
            Button(L("common.ok")) {}
        } message: { info in
            Text(info.message)
        }
        .alert(
            L("live.permission.title"),
            isPresented: Binding(get: { live.permissionAlert != nil }, set: { if !$0 { live.permissionAlert = nil } }),
            presenting: live.permissionAlert
        ) { info in
            Button(L("live.permission.openSettings")) { live.openPrivacySettings(info.kind) }
            Button(L("common.cancel"), role: .cancel) {}
        } message: { info in
            Text(info.message)
        }
        .onAppear {
            live.isLiveWindowOpen = true
            live.openLiveWindow = { openWindow(id: "live") }
        }
        .onDisappear { live.isLiveWindowOpen = false }
        .frame(minWidth: 560, minHeight: 480)
    }
}

/// テーマの背景があるときは透かし、なければ標準の背景
private struct LivePanelBackground: ViewModifier {
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        if model.appearance.hasCustomBackground {
            content.background { ThemeBackground(settings: model.appearance).ignoresSafeArea() }
        } else {
            content.background(.background)
        }
    }
}

// MARK: - 上部: 状態・経過時間・操作

private struct LiveHeader: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let live = model.live
        let session = live.session
        HStack(alignment: .center, spacing: 14) {
            LiveStateBadge(state: session.state)
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(TranscriptFormatter.clock(session.elapsed(at: context.date)))
                    .appFont(.title2, weight: .medium, monospacedDigit: true)
                    .foregroundStyle(session.state == .idle ? .secondary : .primary)
                    .accessibilityLabel(L("live.elapsed.accessibility", TranscriptFormatter.clock(session.elapsed(at: context.date))))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(L("live.header.model", live.model.displayName, model.language.displayName))
                    .appFont(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(recognitionLine(session))
                    .appFont(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            LiveControls()
        }
    }

    private func recognitionLine(_ session: LiveTranscriptionSession) -> String {
        switch session.state {
        case .running:
            // 認識が追いついていないときは、待っている音声の長さを示す（古い音声を黙って捨てない）
            if session.backlogSeconds >= 3 {
                return L("live.recognition.behind", Int(session.backlogSeconds))
            }
            return session.isRecognizing ? L("live.recognition.working") : L("live.recognition.listening")
        case .pausing, .finishing: return L("live.recognition.finalizing")
        case .preparing: return L("model.loading")
        case .paused: return L("live.recognition.paused")
        case .resuming: return L("live.status.preparing")
        case .finished: return L("live.recognition.finished", session.transcript.confirmed.count)
        case .idle: return L("live.recognition.idle")
        }
    }
}

/// 状態の表示（色だけに頼らず、文字でも示す）。メインウインドウの案内でも使う。
struct LiveStateBadge: View {
    let state: LiveTranscriptionSession.State

    var body: some View {
        HStack(spacing: 6) {
            switch state {
            case .preparing, .resuming, .pausing, .finishing:
                ProgressView().controlSize(.small)
            default:
                Image(systemName: symbol)
                    .foregroundStyle(color)
                    .imageScale(.small)
            }
            Text(label)
                .appFont(.callout, weight: .semibold)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(color.opacity(0.12), in: Capsule())
        .accessibilityElement(children: .combine)
    }

    private var symbol: String {
        switch state {
        case .running: "record.circle.fill"
        case .paused: "pause.circle.fill"
        case .finished: "checkmark.circle.fill"
        default: "circle"
        }
    }

    private var color: Color {
        switch state {
        case .running, .preparing, .resuming: .red
        case .paused, .pausing: .orange
        case .finished, .finishing: .green
        case .idle: .secondary
        }
    }

    private var label: String {
        switch state {
        case .idle: L("live.state.idle")
        case .preparing: L("live.state.preparing")
        case .running: L("live.state.running")
        case .pausing: L("live.state.pausing")
        case .paused: L("live.state.paused")
        case .resuming: L("live.state.resuming")
        case .finishing: L("live.state.finishing")
        case .finished: L("live.state.finished")
        }
    }
}

/// 一時停止・再開・終了・隠す
private struct LiveControls: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let live = model.live
        HStack(spacing: 8) {
            switch live.state {
            case .running, .paused, .pausing, .resuming:
                if live.ghostModeEnabled {
                    Button {
                        live.hideWindows()
                    } label: {
                        Label(L("live.action.hide"), systemImage: "eye.slash")
                    }
                    .help(L("live.action.hide.help"))
                }
                Button {
                    live.togglePause()
                } label: {
                    if live.state == .paused {
                        Label(L("live.action.resume"), systemImage: "play.fill")
                    } else {
                        Label(L("live.action.pause"), systemImage: "pause.fill")
                    }
                }
                .disabled(live.state == .pausing || live.state == .resuming)
                .keyboardShortcut("p", modifiers: [.command, .shift])
                Button(role: .destructive) {
                    live.stop()
                } label: {
                    Label(L("live.action.stop"), systemImage: "stop.fill")
                }
                .keyboardShortcut(".", modifiers: [.command, .shift])
                .help(L("live.action.stop.help"))
            case .preparing:
                Button(L("common.cancel")) { live.stop() }
            case .finishing:
                EmptyView()
            case .idle, .finished:
                if live.state == .finished {
                    Button(L("live.action.new")) { live.newSession() }
                }
                // 確認画面で対象や入力を選び直せるので、開始できない理由があっても確認画面は開ける
                Button {
                    live.requestStart()
                } label: {
                    Label(L("live.action.start"), systemImage: "waveform")
                }
                .buttonStyle(.borderedProminent)
                .help(live.startBlockReason.map { L("live.action.start.blockedHelp", $0) } ?? L("live.action.start.help"))
            }
        }
        .controlSize(.large)
    }
}

// MARK: - 開始前の設定

private struct LiveSetupForm: View {
    @Environment(AppModel.self) private var model
    @ViewState private var showDownloadConfirmation = false

    var body: some View {
        @Bindable var live = model.live
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text(L("live.setup.title"))
                    .appFont(.title3, weight: .semibold)
                Text(L("live.setup.message"))
                    .appFont(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            GroupBox {
                LiveSourceRows(showsNotes: true)
                    .padding(8)
            } label: {
                Text(L("live.setup.inputs")).appFont(.headline)
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    LabeledContent(L("settings.model")) {
                        Picker(L("settings.model"), selection: Binding(
                            get: { model.settings.liveModelID },
                            set: { model.settings.liveModelID = $0 }
                        )) {
                            ForEach(ModelCatalog.models(for: .whisper)) { m in
                                Text(modelLabel(m)).tag(m.id)
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 360)
                        .accessibilityLabel(L("settings.model.accessibility"))
                    }
                    LabeledContent(L("settings.language")) {
                        Picker(L("settings.language"), selection: $model.language) {
                            ForEach(SpeechEngine.whisper.languageOptions) { Text($0.displayName).tag($0) }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 200)
                        .accessibilityLabel(L("settings.language.accessibility"))
                    }
                    if !model.models.isInstalled(live.model) {
                        HStack(spacing: 8) {
                            Label(L("live.model.notInstalled"), systemImage: "arrow.down.circle")
                                .foregroundStyle(.orange)
                                .appFont(.callout)
                            Button(L("model.download")) { showDownloadConfirmation = true }
                                .controlSize(.small)
                        }
                    }
                    VocabularyHintField()
                    RecordAudioToggle()
                    Label(L("live.music.note"), systemImage: "music.note")
                        .appFont(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(8)
            } label: {
                Text(L("live.setup.recognition")).appFont(.headline)
            }

            if let reason = live.startBlockReason {
                Label(reason, systemImage: "info.circle")
                    .appFont(.callout)
                    .foregroundStyle(.secondary)
            }
            if let error = live.session.startError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .appFont(.callout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: 640, alignment: .leading)
        .frame(maxWidth: .infinity)
        .disabled(live.state == .preparing)
        // モデルの取得前の確認（メインウインドウと同じ内容）
        .alert(DownloadConfirmation.title(for: live.model), isPresented: $showDownloadConfirmation) {
            Button(L("download.confirm.download")) { model.models.download(live.model) }
            Button(L("common.cancel"), role: .cancel) {}
        } message: {
            Text(DownloadConfirmation.message(for: live.model, model: model))
        }
    }

    private func modelLabel(_ m: SpeechModel) -> String {
        let mark = model.models.isInstalled(m) ? "✓ " : ""
        let name = m.isDefaultForEngine ? L("model.recommendedName", m.displayName) : m.displayName
        return "\(mark)\(name) — \(m.sizeText)"
    }
}

/// 3 つの入力（ウィンドウ・システム音声・マイク）のオン・オフと対象の選択。開始前の画面と確認画面で共通。
private struct LiveSourceRows: View {
    @Environment(AppModel.self) private var model
    /// 入力ごとの説明を出す（確認画面では短くするため、制約に関わる説明だけにする）
    let showsNotes: Bool

    var body: some View {
        @Bindable var live = model.live
        VStack(alignment: .leading, spacing: showsNotes ? 14 : 10) {
            SourceRow(
                isOn: $live.selection.window,
                title: L("live.input.window"),
                note: showsNotes ? L("live.input.window.note") : L("live.input.window.shortNote"),
                choice: live.windowChoice.map { c in c.detail.map { "\(c.title) — \($0)" } ?? c.title },
                pickTitle: live.windowChoice == nil ? L("live.pick.window") : L("live.pick.change"),
                pick: { live.pick(.window) },
                dimmed: live.selection.windowIsCoveredBySystem
            )
            if live.selection.windowIsCoveredBySystem {
                Label(L("live.input.window.covered"), systemImage: "info.circle")
                    .appFont(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 24)
            }
            Divider()
            SourceRow(
                isOn: $live.selection.system,
                title: L("live.input.system"),
                note: showsNotes ? L("live.input.system.note") : L("live.confirm.systemScope"),
                choice: live.displayChoice.map { L("live.source.systemLabel", $0.title) },
                pickTitle: live.displayChoice == nil ? L("live.pick.display") : L("live.pick.change"),
                pick: { live.pick(.system) },
                dimmed: false
            )
            Divider()
            SourceRow(
                isOn: $live.selection.microphone,
                title: L("live.input.microphone"),
                note: showsNotes ? L("live.input.microphone.note") : L("live.input.microphone.shortNote"),
                choice: live.selection.microphone ? live.micDeviceName : nil,
                pickTitle: nil,
                pick: nil,
                dimmed: false
            )
        }
    }
}

/// 「音声も保存する」（既定はオフ）
private struct RecordAudioToggle: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var live = model.live
        Toggle(isOn: $live.recordsAudio) {
            VStack(alignment: .leading, spacing: 2) {
                Text(L("live.recordAudio"))
                Text(L("live.recordAudio.note"))
                    .appFont(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .toggleStyle(.checkbox)
    }
}

/// 語彙のヒント（任意）。固有名詞や専門用語を書くと、認識の手がかりとして Whisper に渡す。
private struct VocabularyHintField: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var live = model.live
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent(L("live.hint.title")) {
                TextField(L("live.hint.placeholder"), text: $live.vocabularyHint, axis: .vertical)
                    .lineLimit(1 ... 3)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 360)
                    .accessibilityLabel(L("live.hint.title"))
            }
            Text(L("live.hint.note", live.vocabularyHint.count, LivePromptBuilder.hintLimit))
                .appFont(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// 入力 1 つ分（チェックボックス・説明・選んだ対象・選ぶボタン）
private struct SourceRow: View {
    @Binding var isOn: Bool
    let title: String
    let note: String
    let choice: String?
    let pickTitle: String?
    let pick: (() -> Void)?
    let dimmed: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Toggle(isOn: $isOn) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).appFont(.body, weight: .medium)
                    Text(note)
                        .appFont(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let choice {
                        Label(choice, systemImage: "checkmark.circle.fill")
                            .appFont(.callout)
                            .foregroundStyle(dimmed ? .secondary : .primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
            .toggleStyle(.checkbox)
            Spacer(minLength: 8)
            if let pickTitle, let pick {
                Button(pickTitle, action: pick)
                    .fixedSize()
            }
        }
        .opacity(dimmed ? 0.7 : 1)
    }
}

// MARK: - 確認画面

private struct LiveConfirmationSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let live = model.live
        let selection = live.selection
        VStack(alignment: .leading, spacing: 14) {
            Text(L("live.confirm.title"))
                .appFont(.title3, weight: .semibold)
            Text(L("live.confirm.message"))
                .appFont(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // 取り込む入力と対象（ここでオン・オフや対象の選び直しができる）
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    LiveSourceRows(showsNotes: false)
                    if selection.screenInput == .window, let app = live.windowChoice?.detail {
                        Label(L("live.confirm.windowApp", app), systemImage: "exclamationmark.circle")
                            .appFont(.caption)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(6)
            } label: {
                Text(L("live.setup.inputs")).appFont(.headline)
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    RecordAudioToggle()
                    Text(live.recordsAudio ? L("live.confirm.audioSaved") : L("live.confirm.audioNotSaved"))
                        .appFont(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Divider()
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                        GridRow {
                            Text(L("live.confirm.recognition")).foregroundStyle(.secondary)
                            Text(L("live.header.model", live.model.displayName, model.language.displayName))
                        }
                        GridRow {
                            Text(L("live.hint.title")).foregroundStyle(.secondary)
                            Text(live.vocabularyHint.isEmpty ? L("live.confirm.hintNone") : live.vocabularyHint)
                                .lineLimit(2)
                                .truncationMode(.tail)
                        }
                    }
                    .appFont(.callout)
                }
                .padding(6)
            } label: {
                Text(L("live.confirm.audioAndRecognition")).appFont(.headline)
            }

            VStack(alignment: .leading, spacing: 6) {
                Label(L("live.confirm.osIndicator"), systemImage: "menubar.rectangle")
                Label(L("settings.privacy"), systemImage: "lock.shield")
                Label(L("live.confirm.consent"), systemImage: "person.2")
            }
            .appFont(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            if live.hasUnsavedResult {
                Label(L("live.confirm.unsaved"), systemImage: "exclamationmark.triangle")
                    .appFont(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(alignment: .firstTextBaseline, spacing: 10) {
                // 開始できない理由（開始ボタンを無効にしている理由）
                if let reason = live.startBlockReason {
                    Label(reason, systemImage: "info.circle")
                        .appFont(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Button(L("common.cancel"), role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(L("live.confirm.start")) {
                    Task { await live.confirmStart() }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(live.startBlockReason != nil)
                .help(live.startBlockReason ?? L("live.action.start.help"))
            }
        }
        .padding(22)
        .frame(width: 540)
    }
}

// MARK: - 取り込み中・終了後

private struct LiveSessionBody: View {
    @Environment(AppModel.self) private var model
    @Environment(\.appTypography) private var typography
    @Environment(\.hasCustomBackground) private var hasCustomBackground
    @AppStorage("live.showTimestamps") private var showTimestamps = false

    var body: some View {
        let session = model.live.session
        VStack(alignment: .leading, spacing: 0) {
            LiveInputsStrip()
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
            Divider()
            ZStack {
                LiveTranscriptTextView(
                    confirmed: session.transcript.confirmed,
                    provisional: session.transcript.provisionalText,
                    showTimestamps: showTimestamps,
                    font: typography.nsFont(size: NSFont.systemFontSize + 2),
                    showsBackground: !model.appearance.hasCustomBackground
                )
                if session.transcript.isEmpty {
                    Text(session.state == .running ? L("live.waiting") : L("live.noText"))
                        .appFont(.callout)
                        .foregroundStyle(.secondary)
                        .allowsHitTesting(false)
                }
            }
            HStack(spacing: 12) {
                Label(L("live.provisional.legend"), systemImage: "text.cursor")
                    .appFont(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer(minLength: 8)
                Toggle(L("detail.showTimestamps"), isOn: $showTimestamps)
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
                    .fixedSize()
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 8)
        }
    }
}

/// 入力ごとの名前・状態・音量
private struct LiveInputsStrip: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let session = model.live.session
        VStack(alignment: .leading, spacing: 6) {
            ForEach(session.inputs) { input in
                HStack(spacing: 10) {
                    Image(systemName: icon(input.kind))
                        .frame(width: 18)
                        .foregroundStyle(input.isActive ? .primary : .tertiary)
                    Text(input.label)
                        .appFont(.callout)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                    if input.isActive, input.kind == .window, !input.isVisible {
                        Text(L("live.input.notVisible"))
                            .appFont(.caption)
                            .foregroundStyle(.orange)
                    }
                    Text(input.isActive ? L("live.input.active") : L("live.input.inactive"))
                        .appFont(.caption)
                        .foregroundStyle(.secondary)
                    LevelMeter(level: input.level)
                        .frame(width: 90, height: 6)
                        .opacity(input.isActive ? 1 : 0.3)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    private func icon(_ kind: LiveInputKind) -> String {
        switch kind {
        case .window: "macwindow"
        case .system: "display"
        case .microphone: "mic"
        }
    }
}

/// 音量の目安（-60 dB〜0 dB）
private struct LevelMeter: View {
    let level: Float

    var body: some View {
        let db = 20 * log10(max(Double(level), 1e-6))
        let fraction = min(max((db + 60) / 60, 0), 1)
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(Color.accentColor.opacity(0.8))
                    .frame(width: proxy.size.width * fraction)
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - 下部: 知らせ・保存

private struct LiveFooter: View {
    @Environment(AppModel.self) private var model
    @AppStorage("live.showTimestamps") private var showTimestamps = false

    var body: some View {
        let live = model.live
        let session = live.session
        VStack(alignment: .leading, spacing: 6) {
            ForEach(session.notices.suffix(3)) { notice in
                Label(notice.message, systemImage: icon(notice.level))
                    .appFont(.caption)
                    .foregroundStyle(color(notice.level))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            if session.droppedSeconds > 0 {
                Label(L("live.dropped.total", Int(session.droppedSeconds.rounded(.up))), systemImage: "exclamationmark.triangle")
                    .appFont(.caption)
                    .foregroundStyle(.orange)
            }
            HStack(spacing: 10) {
                Label(session.isRecordingAudio ? L("live.footer.recording") : L("settings.privacy"),
                      systemImage: session.isRecordingAudio ? "waveform.circle" : "lock.shield")
                    .appFont(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                if let message = live.lastSaveMessage {
                    Text(message)
                        .appFont(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                if session.state == .finished {
                    if session.recordedAudioURL != nil {
                        Menu {
                            Button(L("live.audio.save")) { live.saveAudio() }
                            Button(L("live.audio.discard"), role: .destructive) { live.discardAudio() }
                        } label: {
                            Label(L("live.audio.menu"), systemImage: "waveform")
                        }
                        .fixedSize()
                    }
                    Menu {
                        ForEach(ExportFormat.allCases) { format in
                            Button(L("common.ellipsis", format.displayName)) {
                                live.saveTranscript(format: format, includeTimestamps: showTimestamps)
                            }
                        }
                    } label: {
                        Label(L("live.save"), systemImage: "square.and.arrow.down")
                    }
                    .fixedSize()
                    .disabled(session.transcript.confirmed.isEmpty)
                    .accessibilityLabel(L("live.save.accessibility"))
                }
            }
        }
    }

    private func icon(_ level: LiveTranscriptionSession.Notice.Level) -> String {
        switch level {
        case .info: "info.circle"
        case .warning: "exclamationmark.triangle"
        case .error: "exclamationmark.octagon"
        }
    }

    private func color(_ level: LiveTranscriptionSession.Notice.Level) -> Color {
        switch level {
        case .info: .secondary
        case .warning: .orange
        case .error: .red
        }
    }
}

// MARK: - 文字起こしの表示

/// 確定した文と暫定の文を表示する読み取り専用のテキスト。
///
/// 長時間でも軽く動くよう、確定した文は末尾に足すだけにし、暫定の文の部分だけを毎回置き換える。
/// 暫定の文は灰色の斜体で、前に「認識中」の印を付ける（色だけに頼らない）。
/// 末尾を見ているときだけ自動でスクロールする。
struct LiveTranscriptTextView: NSViewRepresentable {
    let confirmed: [TranscriptSegment]
    let provisional: String
    let showTimestamps: Bool
    let font: NSFont
    var showsBackground = true

    final class Coordinator {
        var renderedCount = 0
        var provisionalRange = NSRange(location: 0, length: 0)
        var showTimestamps = false
        var font: NSFont?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let textView = scroll.documentView as! NSTextView
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.textContainerInset = NSSize(width: 16, height: 14)
        textView.backgroundColor = .textBackgroundColor
        textView.setAccessibilityLabel(L("live.text.accessibility"))
        textView.unregisterDraggedTypes()
        update(scroll, context: context)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        update(scroll, context: context)
    }

    private func update(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? NSTextView, let storage = textView.textStorage else { return }
        scroll.drawsBackground = showsBackground
        textView.drawsBackground = showsBackground
        let c = context.coordinator
        let atBottom = textView.visibleRect.maxY >= textView.bounds.height - 40

        storage.beginEditing()
        if confirmed.count < c.renderedCount || c.showTimestamps != showTimestamps || c.font != font {
            storage.setAttributedString(NSAttributedString())
            c.renderedCount = 0
            c.provisionalRange = NSRange(location: 0, length: 0)
            c.showTimestamps = showTimestamps
            c.font = font
        }
        // 暫定の文を外してから、新しく確定した文を足し、暫定の文を付け直す
        storage.deleteCharacters(in: c.provisionalRange)
        if c.renderedCount < confirmed.count {
            let lines = confirmed[c.renderedCount...].map { line(for: $0) }.joined()
            storage.append(NSAttributedString(string: lines, attributes: confirmedAttributes))
            c.renderedCount = confirmed.count
        }
        let start = storage.length
        if !provisional.isEmpty {
            storage.append(NSAttributedString(string: L("live.provisional.marker") + " ", attributes: markerAttributes))
            storage.append(NSAttributedString(string: provisional, attributes: provisionalAttributes))
        }
        c.provisionalRange = NSRange(location: start, length: storage.length - start)
        storage.endEditing()

        if atBottom { textView.scrollToEndOfDocument(nil) }
    }

    private func line(for segment: TranscriptSegment) -> String {
        showTimestamps ? "[\(TranscriptFormatter.clock(segment.start))] \(segment.text)\n" : "\(segment.text)\n"
    }

    private var paragraph: NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 5
        style.paragraphSpacing = 6
        return style
    }

    private var confirmedAttributes: [NSAttributedString.Key: Any] {
        [.font: font, .foregroundColor: NSColor.textColor, .paragraphStyle: paragraph]
    }

    private var provisionalAttributes: [NSAttributedString.Key: Any] {
        let italic = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
        return [.font: italic, .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: paragraph]
    }

    private var markerAttributes: [NSAttributedString.Key: Any] {
        [.font: NSFont.systemFont(ofSize: max(font.pointSize - 3, 10), weight: .semibold),
         .foregroundColor: NSColor.tertiaryLabelColor, .paragraphStyle: paragraph]
    }
}
