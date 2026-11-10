import AppKit
import Carbon.HIToolbox
import WhisperBatchCore

/// ほかのアプリを使っているときにも効くキーボードショートカット。
///
/// Carbon の `RegisterEventHotKey` を使う（アクセシビリティの許可は不要で、App Sandbox の中でも使える）。
/// ライブ文字起こしの取り込み中・一時停止中だけ登録し、終わったら外す。
@MainActor
final class GlobalHotKeys {
    enum Action: UInt32 {
        case stop = 1
        case show = 2
    }

    private var refs: [Action: EventHotKeyRef] = [:]
    private var handlerRef: EventHandlerRef?
    private var actions: [Action: () -> Void] = [:]
    /// 登録できなかった（ほかのアプリが使っているなど）ショートカット
    private(set) var failed: Set<Action> = []

    private static let signature: OSType = 0x5742_4C56 // 'WBLV'
    nonisolated(unsafe) private static weak var current: GlobalHotKeys?

    /// 登録する（既に登録していれば置き換える）。登録できたら true。
    @discardableResult
    func register(_ action: Action, shortcut: LiveShortcut, perform: @escaping () -> Void) -> Bool {
        unregister(action)
        failed.remove(action)
        guard let key = shortcut.key, let code = Self.keyCode(for: key) else { return true }
        installHandlerIfNeeded()
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: Self.signature, id: action.rawValue)
        let modifiers = UInt32(controlKey | optionKey | cmdKey)
        let status = RegisterEventHotKey(code, modifiers, id, GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else {
            failed.insert(action)
            return false
        }
        refs[action] = ref
        actions[action] = perform
        return true
    }

    func unregister(_ action: Action) {
        if let ref = refs.removeValue(forKey: action) { UnregisterEventHotKey(ref) }
        actions[action] = nil
    }

    func unregisterAll() {
        for action in Array(refs.keys) { unregister(action) }
        failed = []
    }

    private func installHandlerIfNeeded() {
        guard handlerRef == nil else { return }
        Self.current = self
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var id = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard status == noErr, id.signature == GlobalHotKeys.signature, let action = Action(rawValue: id.id) else {
                return OSStatus(eventNotHandledErr)
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { GlobalHotKeys.current?.actions[action]?() }
            }
            return noErr
        }, 1, &spec, nil, &handlerRef)
    }

    /// 候補のキー（英字と「.」）の仮想キーコード（US 配列の位置。JIS 配列でも同じ位置のキー）
    private static func keyCode(for key: String) -> UInt32? {
        switch key {
        case "S": UInt32(kVK_ANSI_S)
        case ".": UInt32(kVK_ANSI_Period)
        case "X": UInt32(kVK_ANSI_X)
        case "L": UInt32(kVK_ANSI_L)
        case "W": UInt32(kVK_ANSI_W)
        case "O": UInt32(kVK_ANSI_O)
        default: nil
        }
    }
}
