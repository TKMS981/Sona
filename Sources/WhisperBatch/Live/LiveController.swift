import AppKit
import AVFoundation
import Observation
import WhisperBatchCore
import WhisperBatchEngine

/// ライブ文字起こしの画面の状態と操作。
///
/// - 入力（ウィンドウ・システム音声・マイク）は独立してオン・オフできる。マイクは起動するたびにオフから始まる。
/// - 取り込みの前に、対象とマイクのオン・オフを確認する画面を出す。
/// - ゴーストモード（設定で明示的に有効にしたときだけ）: メニューバーの録音表示を出さず、ウインドウを隠せる。
///   隠しても取り込みの状態は変えない。Dock のメニュー・アプリのメニュー・ショートカットから、
///   いつでも状態の確認・停止・表示への復帰ができる。macOS が出す収録中の表示には一切触れない。
@MainActor
@Observable
final class LiveController {
    let session: LiveTranscriptionSession

    // MARK: 開始前の設定

    var selection = LiveSourceSelection()
    private(set) var windowChoice: ContentPicker.Choice?
    private(set) var displayChoice: ContentPicker.Choice?
    /// 音声も一時ファイルに書き、終了後に保存できるようにする（既定はオフ。起動のたびにオフ）
    var recordsAudio = false
    var showConfirmation = false
    /// ピッカーを表示中
    private(set) var isPicking = false

    // MARK: 案内

    var alert: AppModel.AlertMessage?
    /// 権限がなくて始められなかったときの案内（システム設定を開くボタンを出す）
    var permissionAlert: PermissionAlert?
    /// 直近の保存結果の案内
    var lastSaveMessage: String?
    /// 終了した結果の要約・重要な発言（新しいセッションを始めると消える）
    var analysis = TranscriptAnalysis()

    struct PermissionAlert: Identifiable {
        enum Kind { case microphone, screen }
        let id = UUID()
        var kind: Kind
        var message: String
    }

    // MARK: ゴーストモード

    /// ゴーストモードでウインドウを隠している
    private(set) var isGhostHidden = false
    @ObservationIgnored private var hiddenWindows: [NSWindow] = []

    // MARK: 依存

    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private let models: ModelManager
    @ObservationIgnored private let picker = ContentPicker()
    @ObservationIgnored private let hotKeys = GlobalHotKeys()
    /// 一括処理中か（同時に Whisper を 2 つ動かさない）
    @ObservationIgnored var isBatchRunning: () -> Bool = { false }
    /// ライブ文字起こしのウインドウを開く（SwiftUI の openWindow を画面側から受け取る）
    @ObservationIgnored var openLiveWindow: (() -> Void)?
    /// ライブ文字起こしのウインドウが開いている（隠している場合も含む）
    @ObservationIgnored var isLiveWindowOpen = false
    /// ショートカットを登録できなかったもの（設定画面に表示する）
    private(set) var failedShortcuts: Set<GlobalHotKeys.Action> = []

    init(settings: SettingsStore, models: ModelManager) {
        self.settings = settings
        self.models = models
        session = LiveTranscriptionSession(storage: models.storage)
    }

    // MARK: 参照

    var state: LiveTranscriptionSession.State { session.state }
    var isActive: Bool { session.state.isActive }

    /// メニューバーに録音中の表示を出すか（ゴーストモードでは出さない）
    var showsStatusItem: Bool { isActive && !settings.ghostMode }

    var ghostModeEnabled: Bool { settings.ghostMode }

    var model: SpeechModel { settings.liveModel }

    var installedWhisperModels: [SpeechModel] { models.installedModels(for: .whisper) }

    var micDeviceName: String { MicrophoneSource.currentDeviceName ?? L("live.source.noMicrophone") }

    /// 保存していない結果や音声がある
    var hasUnsavedResult: Bool {
        session.hasUnsavedTranscript || session.recordedAudioURL != nil
    }

    /// 開始できない理由（開始できるなら nil）
    var startBlockReason: String? {
        if isActive { return nil }
        if isBatchRunning() { return L("live.block.batchRunning") }
        if selection.isEmpty { return L("live.block.noInput") }
        if let screen = selection.screenInput {
            if screen == .system, displayChoice == nil { return L("live.block.pickDisplay") }
            if screen == .window, windowChoice == nil { return L("live.block.pickWindow") }
        }
        if !models.isInstalled(model) { return L("live.block.noModel", model.displayName) }
        return nil
    }

    /// 状態の短い説明（メニューや Dock のメニュー用）
    func statusText(at date: Date = Date()) -> String {
        let time = TranscriptFormatter.clock(session.elapsed(at: date))
        switch session.state {
        case .idle: return L("live.status.idle")
        case .preparing: return L("live.status.preparing")
        case .running, .resuming:
            return isGhostHidden ? L("live.status.runningHidden", time) : L("live.status.running", time)
        case .pausing, .paused:
            return isGhostHidden ? L("live.status.pausedHidden", time) : L("live.status.paused", time)
        case .finishing: return L("live.status.finishing")
        case .finished: return L("live.status.finished", time)
        }
    }

    // MARK: 対象の選択

    /// macOS 標準のピッカーでウィンドウ（.window）または画面（.system）を選ぶ
    func pick(_ kind: LiveInputKind) {
        guard !isPicking, !isActive else { return }
        isPicking = true
        picker.present(kind) { [weak self] outcome in
            guard let self else { return }
            isPicking = false
            switch outcome {
            case .picked(let choice):
                apply(choice)
            case .cancelled:
                break
            case .failed(let message):
                alert = .init(title: L("live.pick.failed.title"), message: message)
            }
        }
    }

    /// 選んだ対象を使う（選んだ入力はオンにする）
    func apply(_ choice: ContentPicker.Choice) {
        if choice.kind == .window {
            windowChoice = choice
            selection.window = true
        } else {
            displayChoice = choice
            selection.system = true
        }
    }

    // MARK: 開始・一時停止・終了

    /// 確認画面を出す。確認画面で入力・対象・音声の保存を確かめて変えられるので、
    /// まだ対象を選んでいないなど開始できない状態でも出す（開始ボタンは理由を添えて無効にする）。
    func requestStart() {
        guard session.state == .idle || session.state == .finished, !isPicking else { return }
        showConfirmation = true
    }

    /// メインウインドウの「ライブ文字起こし」: ライブ文字起こしのウインドウを前に出し、
    /// 開始前なら確認画面を出す。取り込み中・終了後は、そのウインドウを表示するだけ（状態は変えない）。
    func openFromMainWindow() {
        if isGhostHidden {
            showWindows()
            return
        }
        openLiveWindow?()
        NSApp.activate()
        if session.state == .idle { requestStart() }
    }

    /// 語彙のヒント（設定に保存。認識の手がかりとして Whisper に渡す）
    var vocabularyHint: String {
        get { settings.liveVocabularyHint }
        set { settings.liveVocabularyHint = newValue }
    }

    /// 確認画面で「開始」を押した。マイクを使う場合は、ここで macOS の許可を求める。
    func confirmStart() async {
        showConfirmation = false
        guard startBlockReason == nil else { return }
        if selection.microphone {
            guard await ensureMicrophoneAccess() else { return }
        }
        var sources: [any LiveAudioSource] = []
        var labels: [LiveInputKind: String] = [:]
        var windowID: CGWindowID?
        switch selection.screenInput {
        case .window:
            if let choice = windowChoice {
                sources.append(ScreenAudioSource(kind: .window, filter: choice.filter))
                labels[.window] = choice.detail.map { "\(choice.title) — \($0)" } ?? choice.title
                windowID = choice.windowID
            }
        case .system:
            if let choice = displayChoice {
                sources.append(ScreenAudioSource(kind: .system, filter: choice.filter))
                labels[.system] = L("live.source.systemLabel", choice.title)
            }
        default:
            break
        }
        if selection.microphone {
            sources.append(MicrophoneSource())
            labels[.microphone] = micDeviceName
        }
        lastSaveMessage = nil
        analysis = TranscriptAnalysis()
        await session.start(.init(model: model, language: settings.language, sources: sources, labels: labels,
                                  windowID: windowID, recordsAudio: recordsAudio,
                                  vocabularyHint: settings.liveVocabularyHint))
        if let error = session.startError {
            if error == LiveCaptureError.screenCaptureDenied.errorDescription {
                permissionAlert = .init(kind: .screen, message: error)
            } else if error == LiveCaptureError.microphoneDenied.errorDescription {
                permissionAlert = .init(kind: .microphone, message: error)
            } else {
                alert = .init(title: L("live.start.failed.title"), message: error)
            }
        }
        updateHotKeys()
    }

    func pause() {
        Task { await session.pause() }
    }

    func resume() {
        Task { await session.resume() }
    }

    func togglePause() {
        switch session.state {
        case .running: pause()
        case .paused: resume()
        default: break
        }
    }

    /// 取り込みを止めて終える（ショートカット・Dock・メニューから）
    func stop() {
        Task {
            await session.finish()
            updateHotKeys()
        }
    }

    /// 結果を消して開始前に戻る（保存していない結果があれば確認する）
    func newSession() {
        guard !isActive else { return }
        if hasUnsavedResult {
            let alert = NSAlert()
            alert.messageText = L("live.new.confirm.title")
            alert.informativeText = L("live.new.confirm.message")
            alert.addButton(withTitle: L("live.new.confirm.discard"))
            alert.addButton(withTitle: L("common.cancel"))
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        session.reset()
        lastSaveMessage = nil
        analysis = TranscriptAnalysis()
    }

    func shutdown() async {
        hotKeys.unregisterAll()
        await session.shutdown()
    }

    // MARK: 権限

    /// マイクの使用を確かめる。まだ決めていなければ macOS の確認を出す。
    private func ensureMicrophoneAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            if await AVCaptureDevice.requestAccess(for: .audio) { return true }
        default:
            break
        }
        permissionAlert = .init(kind: .microphone, message: LiveCaptureError.microphoneDenied.errorDescription ?? "")
        return false
    }

    /// システム設定の該当するプライバシーの画面を開く
    func openPrivacySettings(_ kind: PermissionAlert.Kind) {
        let anchor = kind == .microphone ? "Privacy_Microphone" : "Privacy_ScreenCapture"
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: 保存

    func saveTranscript(format: ExportFormat, includeTimestamps: Bool) {
        Task {
            let outcome = await ExportService.exportLive(session.transcript.transcript, startedAt: session.startedAt,
                                                         format: format, includeTimestamps: includeTimestamps,
                                                         analysis: analysis)
            if case .saved(let message) = outcome {
                session.markTranscriptSaved()
                lastSaveMessage = message
            } else if case .failed(let message) = outcome {
                alert = .init(title: L("export.failed.title"), message: message)
            }
        }
    }

    func saveAudio() {
        guard session.recordedAudioURL != nil else { return }
        Task {
            guard let destination = await ExportService.chooseLiveAudioDestination(startedAt: session.startedAt) else { return }
            do {
                try session.moveRecordedAudio(to: destination)
                lastSaveMessage = L("live.audio.saved", destination.lastPathComponent)
            } catch {
                alert = .init(title: L("live.audio.failed.title"),
                              message: userFacingMessage(for: error, during: .writing(fileName: destination.lastPathComponent)))
            }
        }
    }

    func discardAudio() {
        session.discardRecordedAudio()
    }

    // MARK: ゴーストモード

    /// ゴーストモードを有効にする（設定画面で説明を読んで確認したとき）
    func enableGhostMode() {
        settings.ghostMode = true
    }

    /// ゴーストモードを無効にする。隠しているウインドウがあれば表示に戻す。
    func disableGhostMode() {
        settings.ghostMode = false
        if isGhostHidden { showWindows() }
    }

    /// このアプリのウインドウを隠す（ゴーストモードが有効で、セッションが続いているときだけ）。
    /// 取り込みはそのまま続ける。
    func hideWindows() {
        guard settings.ghostMode, isActive, !isGhostHidden else { return }
        hiddenWindows = NSApp.windows.filter { $0.isVisible && $0.canBecomeMain }
        for window in hiddenWindows { window.orderOut(nil) }
        isGhostHidden = true
        // 前に使っていたアプリに操作を戻す（Dock のアイコンは残る）
        NSApp.hide(nil)
    }

    /// 隠したウインドウを表示に戻す（ライブ文字起こしのウインドウがなければ開く）
    func showWindows() {
        let windows = hiddenWindows
        hiddenWindows = []
        isGhostHidden = false
        NSApp.unhide(nil)
        for window in windows { window.makeKeyAndOrderFront(nil) }
        if !isLiveWindowOpen { openLiveWindow?() }
        NSApp.activate()
    }

    // MARK: ショートカット

    /// 取り込み中・一時停止中だけショートカットを登録する
    func updateHotKeys() {
        guard isActive else {
            hotKeys.unregisterAll()
            failedShortcuts = []
            return
        }
        hotKeys.register(.stop, shortcut: settings.liveStopShortcut) { [weak self] in self?.stop() }
        hotKeys.register(.show, shortcut: settings.liveShowShortcut) { [weak self] in self?.showWindows() }
        failedShortcuts = hotKeys.failed
    }
}
