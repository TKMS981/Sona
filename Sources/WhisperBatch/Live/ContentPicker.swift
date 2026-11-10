import AppKit
import ScreenCaptureKit
import WhisperBatchCore

/// macOS 標準の共有ピッカー（ウィンドウや画面を選ぶ画面）で、取り込む対象を利用者に選んでもらう。
///
/// ピッカーで選んだ対象は、画面収録の許可を事前に求めずに取り込める（選ぶ操作そのものが利用者の同意になる）。
/// このアプリ自身のウィンドウは候補から外す。
@MainActor
final class ContentPicker: NSObject {
    /// 選ばれた対象（ウィンドウ・画面）
    struct Choice {
        let kind: LiveInputKind
        let filter: SCContentFilter
        /// 対象の名前（ウィンドウのタイトルや画面の名前）
        let title: String
        /// 補足（ウィンドウを持つアプリの名前など）
        let detail: String?
        /// ウィンドウの番号（閉じられたことの検知に使う）
        let windowID: CGWindowID?
    }

    enum Outcome {
        case picked(Choice)
        case cancelled
        case failed(String)
    }

    private var pendingKind: LiveInputKind?
    private var completion: ((Outcome) -> Void)?

    var isAvailable: Bool { SCContentSharingPicker.shared.isAvailable }

    /// ピッカーを表示する。`kind` は .window（ウィンドウを 1 つ）か .system（画面を 1 つ）。
    func present(_ kind: LiveInputKind, completion: @escaping (Outcome) -> Void) {
        let picker = SCContentSharingPicker.shared
        var config = SCContentSharingPickerConfiguration()
        config.allowedPickerModes = kind == .window ? .singleWindow : .singleDisplay
        config.excludedBundleIDs = [Bundle.main.bundleIdentifier].compactMap { $0 }
        config.allowsChangingSelectedContent = false
        picker.defaultConfiguration = config
        picker.add(self)
        picker.isActive = true
        pendingKind = kind
        self.completion = completion
        picker.present(using: kind == .window ? .window : .display)
    }

    private func finish(_ outcome: Outcome) {
        let picker = SCContentSharingPicker.shared
        picker.remove(self)
        let completion = completion
        self.completion = nil
        pendingKind = nil
        completion?(outcome)
    }

    fileprivate func received(_ filter: SCContentFilter) {
        guard let kind = pendingKind else { return }
        finish(.picked(Self.describe(filter, as: kind)))
    }

    static func describe(_ filter: SCContentFilter, as kind: LiveInputKind) -> Choice {
        if kind == .window, let window = filter.includedWindows.first {
            let app = window.owningApplication?.applicationName
            let title = (window.title?.isEmpty == false ? window.title : nil) ?? app ?? L("live.source.untitledWindow")
            return Choice(kind: kind, filter: filter, title: title, detail: app, windowID: window.windowID)
        }
        let display = filter.includedDisplays.first
        let screen = display.flatMap { d in
            NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == d.displayID }
        }
        let name = screen?.localizedName ?? L("live.source.display")
        return Choice(kind: kind, filter: filter, title: name, detail: nil, windowID: nil)
    }
}

extension ContentPicker: SCContentSharingPickerObserver {
    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        DispatchQueue.main.async { MainActor.assumeIsolated { self.finish(.cancelled) } }
    }

    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for stream: SCStream?) {
        nonisolated(unsafe) let filter = filter
        DispatchQueue.main.async { MainActor.assumeIsolated { self.received(filter) } }
    }

    nonisolated func contentSharingPickerStartDidFailWithError(_ error: any Error) {
        let message = (error as NSError).localizedDescription
        DispatchQueue.main.async { MainActor.assumeIsolated { self.finish(.failed(message)) } }
    }
}
