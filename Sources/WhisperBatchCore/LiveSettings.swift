import Foundation

/// ライブ文字起こし中だけ有効になる、ほかのアプリを使っていても効くキーボードショートカット。
/// 割り当ては決まった候補から選ぶ（⌃⌥⌘ と 1 文字の組み合わせ。ほかのアプリと重なりにくいもの）。
public enum LiveShortcut: String, CaseIterable, Identifiable, Sendable {
    case off
    case controlOptionCommandS
    case controlOptionCommandPeriod
    case controlOptionCommandX
    case controlOptionCommandL
    case controlOptionCommandW
    case controlOptionCommandO

    public var id: String { rawValue }

    /// 割り当てるキー（off は nil）
    public var key: String? {
        switch self {
        case .off: nil
        case .controlOptionCommandS: "S"
        case .controlOptionCommandPeriod: "."
        case .controlOptionCommandX: "X"
        case .controlOptionCommandL: "L"
        case .controlOptionCommandW: "W"
        case .controlOptionCommandO: "O"
        }
    }

    /// メニューなどに出す表記（例: ⌃⌥⌘S）
    public var symbol: String? { key.map { "⌃⌥⌘\($0)" } }

    /// 停止に使える候補
    public static let stopChoices: [LiveShortcut] = [.off, .controlOptionCommandS, .controlOptionCommandPeriod, .controlOptionCommandX]
    /// ウインドウを表示に戻すのに使える候補
    public static let showChoices: [LiveShortcut] = [.off, .controlOptionCommandL, .controlOptionCommandW, .controlOptionCommandO]

    public static let defaultStop: LiveShortcut = .controlOptionCommandS
    public static let defaultShow: LiveShortcut = .controlOptionCommandL
}

/// ライブ文字起こしで起きる、利用者に知らせるエラー。文は表示言語に従う。
public enum LiveCaptureError: Error, Equatable, Sendable {
    /// 画面収録（画面とシステムオーディオの収録）が許可されていない
    case screenCaptureDenied
    /// 画面側の音声の取り込みを始められなかった
    case screenCaptureFailed(detail: String)
    /// マイクの使用が許可されていない
    case microphoneDenied
    /// 使えるマイクがない
    case microphoneUnavailable
    /// マイクの取り込みを始められなかった
    case microphoneFailed(detail: String)
    /// どの入力も始められなかった
    case noInputStarted
    /// Whisper のモデルが取得されていない
    case noWhisperModel
}

extension LiveCaptureError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .screenCaptureDenied: L("live.error.screenDenied")
        case .screenCaptureFailed(let detail): L("live.error.screenFailed", detail)
        case .microphoneDenied: L("live.error.micDenied")
        case .microphoneUnavailable: L("live.error.micUnavailable")
        case .microphoneFailed(let detail): L("live.error.micFailed", detail)
        case .noInputStarted: L("live.error.noInput")
        case .noWhisperModel: L("live.error.noModel")
        }
    }
}
