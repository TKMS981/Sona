import AppKit
import SwiftUI
import WhisperBatchCore
import WhisperBatchEngine

@main
struct SonaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("Sona", id: "main") {
            ContentView()
                .modifier(MotionProvider())
                .modifier(AppearanceProvider(settings: appDelegate.model.appearance, appliesBackground: true))
                .environment(appDelegate.model)
                // 表示言語を切り替えたら画面を作り直して、すべての文字列を新しい言語にする
                .id(appDelegate.model.appLanguage)
                .environment(\.locale, appDelegate.model.appLanguage.locale)
                .frame(minWidth: 720, minHeight: 500)
        }
        .defaultSize(width: 1080, height: 720)
        .windowResizability(.contentMinSize)
        .commands { AppCommands(model: appDelegate.model) }

        // ライブ文字起こし（画面やマイクの音声をリアルタイムに文字起こしする）
        Window(L("live.window.title"), id: "live") {
            LiveTranscriptionView()
                .modifier(MotionProvider())
                .modifier(AppearanceProvider(settings: appDelegate.model.appearance))
                .environment(appDelegate.model)
                .id(appDelegate.model.appLanguage)
                .environment(\.locale, appDelegate.model.appLanguage.locale)
        }
        .defaultSize(width: 760, height: 680)
        .windowResizability(.contentMinSize)

        // 取り込み中の表示（ゴーストモードでは出さない）
        MenuBarExtra(isInserted: Binding(get: { appDelegate.model.live.showsStatusItem }, set: { _ in })) {
            LiveStatusMenu()
                .environment(appDelegate.model)
        } label: {
            Label(L("live.statusItem.label"), systemImage: "waveform.badge.mic")
        }

        Settings {
            SettingsView()
                .modifier(AppearanceProvider(settings: appDelegate.model.appearance))
                .environment(appDelegate.model)
                .id(appDelegate.model.appLanguage)
                .environment(\.locale, appDelegate.model.appLanguage.locale)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor let model = AppModel()


    /// ライブ文字起こしが続いている・保存していない結果があるときは、ウインドウを閉じても終了しない
    @MainActor
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !(model.live.isActive || model.live.hasUnsavedResult || model.live.isGhostHidden)
    }

    /// Dock のアイコンを押したとき、ゴーストモードで隠したウインドウを表示に戻す
    @MainActor
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if model.live.isGhostHidden {
            model.live.showWindows()
            return false
        }
        return true
    }

    /// Dock のアイコンのメニュー: ライブ文字起こしの状態と、停止・表示への復帰（ゴーストモード中も使える）
    @MainActor
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let live = model.live
        guard live.isActive || live.isGhostHidden else { return nil }
        let menu = NSMenu()
        let status = NSMenuItem(title: live.statusText(), action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())
        if live.state == .running || live.state == .paused {
            menu.addItem(ClosureMenuItem(title: live.state == .paused ? L("live.action.resume") : L("live.action.pause")) {
                live.togglePause()
            })
        }
        if live.isActive {
            menu.addItem(ClosureMenuItem(title: L("live.action.stop")) { live.stop() })
        }
        menu.addItem(ClosureMenuItem(title: L("live.action.show")) { live.showWindows() })
        return menu
    }

    /// Finder でアプリのアイコンにドロップされた・「このアプリで開く」が選ばれたファイルをキューに追加する
    @MainActor
    func application(_ application: NSApplication, open urls: [URL]) {
        model.addFiles(urls)
    }

    /// 処理中・変換中・ダウンロード中なら確認し、モデルの解放と一時ファイルの削除を終えてから終了する
    @MainActor
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let live = model.live
        guard model.hasActiveWork || model.models.hasActiveDownloads || live.hasUnsavedResult else { return .terminateNow }
        // 隠したウインドウがあれば、確認の前に表示に戻す
        if live.isGhostHidden { live.showWindows() }
        let alert = NSAlert()
        if live.isActive {
            alert.messageText = L("quit.live.title")
            alert.informativeText = L("quit.live.message")
        } else if model.hasActiveWork {
            alert.messageText = L("quit.running.title")
            alert.informativeText = L("quit.running.message")
        } else if model.models.hasActiveDownloads {
            alert.messageText = L("quit.download.title")
            alert.informativeText = L("quit.download.message")
        } else {
            alert.messageText = L("quit.liveUnsaved.title")
            alert.informativeText = L("quit.liveUnsaved.message")
        }
        alert.addButton(withTitle: L("quit.confirm"))
        alert.addButton(withTitle: L("common.cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        Task { @MainActor in
            await model.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    @MainActor
    func applicationWillTerminate(_ notification: Notification) {
        // このプロセスの変換用・ライブ文字起こし用の一時ファイルを残さない（ほかのプロセスのものは消さない）
        ConversionWorkspace.removeOwnFiles()
        LiveRecordingWorkspace.removeOwnFiles()
    }
}

/// 押したときにクロージャを実行するメニュー項目（Dock のメニュー用）
@MainActor
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func run() { handler() }
}

struct AppCommands: Commands {
    let model: AppModel

    var body: some Commands {
        // 表示言語が変わったらメニューの文字列も作り直す
        let _ = model.appLanguage
        CommandGroup(replacing: .newItem) {
            Button(L("menu.addFiles")) { model.showFileImporter = true }
                .keyboardShortcut("o")
        }
        CommandMenu(L("menu.transcription")) {
            Button(L("action.start")) { model.start() }
                .keyboardShortcut("r")
                .disabled(!model.canStart)
            Button(L("action.cancel")) { model.cancel() }
                .keyboardShortcut(".")
                .disabled(!model.isRunning)
            Divider()
            Button(L("action.combine")) { model.showCombineSheet = true }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(!model.hasCompletedItems)
            Divider()
            Button(L("action.manageModels")) { model.showModelManager = true }
                .keyboardShortcut("m", modifiers: [.command, .option])
        }
        CommandMenu(L("menu.live")) {
            LiveCommands(model: model)
        }
    }
}

/// メニューバーの「ライブ」メニュー。ゴーストモードでウインドウを隠していても、ここから状態の確認・停止・表示ができる。
private struct LiveCommands: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let live = model.live
        Text(live.statusText())
        Divider()
        Button(L("menu.live.open")) {
            if live.isGhostHidden { live.showWindows() } else { openWindow(id: "live") }
        }
        .keyboardShortcut("l", modifiers: [.command, .shift])
        Button(live.state == .paused ? L("live.action.resume") : L("live.action.pause")) { live.togglePause() }
            .disabled(live.state != .running && live.state != .paused)
        Button(L("live.action.stop")) { live.stop() }
            .disabled(!live.isActive)
        Divider()
        Button(L("live.menu.hide")) { live.hideWindows() }
            .keyboardShortcut("h", modifiers: [.command, .control])
            .disabled(!live.ghostModeEnabled || !live.isActive || live.isGhostHidden)
        Button(L("live.action.show")) { live.showWindows() }
            .disabled(!live.isGhostHidden)
    }
}

/// メニューバーの録音中の表示（ゴーストモードでは出さない）
struct LiveStatusMenu: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let live = model.live
        Text(live.statusText())
        Divider()
        Button(live.state == .paused ? L("live.action.resume") : L("live.action.pause")) { live.togglePause() }
            .disabled(live.state != .running && live.state != .paused)
        Button(L("live.action.stop")) { live.stop() }
        Divider()
        Button(L("live.action.show")) {
            openWindow(id: "live")
            NSApp.activate()
        }
    }
}

