import Foundation
import Observation

/// 表示言語の設定（文字起こしの言語とは別）
public enum LanguagePreference: String, CaseIterable, Identifiable, Sendable {
    /// macOS の優先言語に合わせる
    case system
    case japanese = "ja"
    case english = "en"

    public var id: String { rawValue }

    /// macOS 全体の優先言語。このアプリ用の言語指定（AppleLanguages）の影響を受けないよう、全体の設定を直接読む。
    public static var systemLanguages: [String] {
        let value = CFPreferencesCopyValue("AppleLanguages" as CFString, kCFPreferencesAnyApplication,
                                           kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        return (value as? [String]) ?? Locale.preferredLanguages
    }

    public var resolved: AppLanguage {
        switch self {
        case .system: AppLanguage.preferred(from: Self.systemLanguages)
        case .japanese: .japanese
        case .english: .english
        }
    }
}

/// 利用者の設定（文字起こしの言語・モデル・Whisper の探索方式・表示言語・自動開始・ライブ文字起こし）を UserDefaults に保存する。
///
/// 値を変えるとすぐに保存する。値の変化に応じた画面側の処理（表示言語の切り替えなど）は持たない。
@MainActor
@Observable
public final class SettingsStore {
    /// 文字起こしの言語
    public var language: LanguageOption {
        didSet { defaults.set(language.id, forKey: Keys.language) }
    }

    public var selectedModelID: String {
        didSet {
            defaults.set(selectedModelID, forKey: Keys.model)
            // 方式を切り替えて戻ったときに、前に選んでいたモデルに戻せるようにする
            if let engine = ModelCatalog.model(id: selectedModelID)?.engine {
                defaults.set(selectedModelID, forKey: Keys.model(for: engine))
            }
        }
    }

    /// 表示言語の設定
    public var languagePreference: LanguagePreference {
        didSet { saveLanguagePreference() }
    }

    /// ファイルを追加したらすぐに文字起こしを始める（既定はオフ）
    public var autoStartOnAdd: Bool {
        didSet { defaults.set(autoStartOnAdd, forKey: Keys.autoStartOnAdd) }
    }

    /// Whisper の探索方式（速度優先／精度優先）
    public var whisperDecoding: WhisperDecoding {
        didSet { defaults.set(whisperDecoding.rawValue, forKey: Keys.whisperDecoding) }
    }

    /// ゴーストモード: ライブ文字起こし中に、このアプリ自身の録音表示（メニューバーの表示）を出さず、
    /// ウインドウを隠せるようにする。既定はオフ。利用者が説明を読んで有効にしたときだけオンになる。
    /// OS が表示する収録中の表示やプライバシーの表示には影響しない。
    public var ghostMode: Bool {
        didSet { defaults.set(ghostMode, forKey: Keys.ghostMode) }
    }

    /// ライブ文字起こしを停止するショートカット（取り込み中だけ有効）
    public var liveStopShortcut: LiveShortcut {
        didSet { defaults.set(liveStopShortcut.rawValue, forKey: Keys.liveStopShortcut) }
    }

    /// 隠したウインドウを表示に戻すショートカット（取り込み中だけ有効）
    public var liveShowShortcut: LiveShortcut {
        didSet { defaults.set(liveShowShortcut.rawValue, forKey: Keys.liveShowShortcut) }
    }

    /// ライブ文字起こしに使う Whisper のモデル
    public var liveModelID: String {
        didSet { defaults.set(liveModelID, forKey: Keys.liveModel) }
    }

    /// ライブ文字起こしの語彙のヒント（固有名詞・専門用語など。認識の手がかりとして Whisper に渡す）。
    /// この Mac の設定にだけ保存し、外部へは送らない。`LivePromptBuilder.hintLimit` 文字まで。
    public var liveVocabularyHint: String {
        didSet {
            if liveVocabularyHint.count > LivePromptBuilder.hintLimit {
                liveVocabularyHint = String(liveVocabularyHint.prefix(LivePromptBuilder.hintLimit))
            }
            defaults.set(liveVocabularyHint, forKey: Keys.liveVocabularyHint)
        }
    }

    @ObservationIgnored private let defaults: UserDefaults

    enum Keys {
        static let language = "language"
        static let model = "modelID"
        static func model(for engine: SpeechEngine) -> String { "modelID.\(engine.rawValue)" }
        static let appLanguage = "appLanguage"
        static let autoStartOnAdd = "autoStartOnAdd"
        static let whisperDecoding = "whisperDecoding"
        static let ghostMode = "ghostMode"
        static let liveStopShortcut = "liveStopShortcut"
        static let liveShowShortcut = "liveShowShortcut"
        static let liveModel = "liveModelID"
        static let liveVocabularyHint = "liveVocabularyHint"
        /// AppKit が読む、このアプリだけの言語指定（標準メニューやパネルの言語。次回起動時に反映）
        static let appleLanguages = "AppleLanguages"
    }

    /// - Parameter defaults: 保存先（テストでは専用のスイートを渡す）
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        language = LanguageOption(storageValue: defaults.string(forKey: Keys.language))
        selectedModelID = defaults.string(forKey: Keys.model).flatMap { ModelCatalog.model(id: $0)?.id }
            ?? ModelCatalog.defaultModelID
        languagePreference = defaults.string(forKey: Keys.appLanguage).flatMap(LanguagePreference.init(rawValue:)) ?? .system
        autoStartOnAdd = defaults.bool(forKey: Keys.autoStartOnAdd)
        whisperDecoding = defaults.string(forKey: Keys.whisperDecoding).flatMap(WhisperDecoding.init(rawValue:)) ?? .default
        ghostMode = defaults.bool(forKey: Keys.ghostMode)
        liveStopShortcut = defaults.string(forKey: Keys.liveStopShortcut).flatMap(LiveShortcut.init(rawValue:))
            .flatMap { LiveShortcut.stopChoices.contains($0) ? $0 : nil } ?? LiveShortcut.defaultStop
        liveShowShortcut = defaults.string(forKey: Keys.liveShowShortcut).flatMap(LiveShortcut.init(rawValue:))
            .flatMap { LiveShortcut.showChoices.contains($0) ? $0 : nil } ?? LiveShortcut.defaultShow
        liveModelID = defaults.string(forKey: Keys.liveModel)
            .flatMap { ModelCatalog.model(id: $0) }
            .flatMap { $0.engine == .whisper ? $0.id : nil }
            ?? ModelCatalog.defaultModel(for: .whisper).id
        liveVocabularyHint = String((defaults.string(forKey: Keys.liveVocabularyHint) ?? "").prefix(LivePromptBuilder.hintLimit))
    }

    /// ライブ文字起こしに使うモデル（Whisper だけ）
    public var liveModel: SpeechModel {
        ModelCatalog.model(id: liveModelID).flatMap { $0.engine == .whisper ? $0 : nil } ?? ModelCatalog.defaultModel(for: .whisper)
    }

    public var selectedModel: SpeechModel {
        ModelCatalog.model(id: selectedModelID) ?? ModelCatalog.defaultModel
    }

    /// その方式で最後に選んでいたモデル（なければ nil）
    public func lastSelectedModel(for engine: SpeechEngine) -> SpeechModel? {
        defaults.string(forKey: Keys.model(for: engine))
            .flatMap(ModelCatalog.model(id:))
            .flatMap { $0.engine == engine ? $0 : nil }
    }

    private func saveLanguagePreference() {
        defaults.set(languagePreference.rawValue, forKey: Keys.appLanguage)
        if languagePreference == .system {
            defaults.removeObject(forKey: Keys.appleLanguages)
        } else {
            defaults.set([languagePreference.rawValue], forKey: Keys.appleLanguages)
        }
    }
}
