import AppKit
import Foundation
import Observation
import UserNotifications
import WhisperBatchCore

/// macOS の通知を出す。設定でオンにした種類だけ出し、許可は通知をオンにしたときに求める。
///
/// 通知の本文には、ファイル名や処理の結果だけを入れる（文字起こしの文は入れない）。
@MainActor
@Observable
final class NotificationService {
    static let shared = NotificationService()

    enum Permission: Equatable {
        case unknown
        case notDetermined
        case allowed
        case denied
        /// アプリとして起動していない（開発時の実行など）ので使えない
        case unsupported
    }

    private(set) var permission: Permission = .unknown

    /// .app として起動しているときだけ使える（UNUserNotificationCenter はバンドルが必要）
    var isSupported: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app"
    }

    private var center: UNUserNotificationCenter? { isSupported ? .current() : nil }

    /// 今の許可の状態を読み直す
    func refreshPermission() async {
        guard let center else { permission = .unsupported; return }
        let settings = await center.notificationSettings()
        permission = switch settings.authorizationStatus {
        case .notDetermined: .notDetermined
        case .denied: .denied
        case .authorized, .provisional: .allowed
        @unknown default: .unknown
        }
    }

    /// 通知をオンにしたとき: まだ決めていなければ macOS の確認を出す
    func requestPermissionIfNeeded() async {
        guard let center else { permission = .unsupported; return }
        await refreshPermission()
        guard permission == .notDetermined else { return }
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
        await refreshPermission()
    }

    /// システム設定の通知の画面を開く
    func openSystemSettings() {
        let id = Bundle.main.bundleIdentifier ?? ""
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)") {
            NSWorkspace.shared.open(url)
        }
    }

    /// 通知を出す（このアプリが前面にあるときは、設定に従って出さない）
    func post(title: String, body: String, settings: SettingsStore) {
        guard let center else { return }
        if settings.notifyOnlyWhenInactive, NSApp.isActive { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if settings.notificationSound { content.sound = .default }
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        center.add(request) { _ in }
    }
}
