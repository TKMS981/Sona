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

    // MARK: 通知（既定はすべてオフ。オンにしたときに macOS の許可を求める）

    /// 一括の文字起こしが終わったら通知する
    public var notifyBatchFinished: Bool {
        didSet { defaults.set(notifyBatchFinished, forKey: Keys.notifyBatchFinished) }
    }

    /// ライブ文字起こしの入力が止まった（対象が閉じた・機器が外れた）ら通知する
    public var notifyLiveInterrupted: Bool {
        didSet { defaults.set(notifyLiveInterrupted, forKey: Keys.notifyLiveInterrupted) }
    }

    /// モデルのダウンロードが終わったら通知する
    public var notifyDownloads: Bool {
        didSet { defaults.set(notifyDownloads, forKey: Keys.notifyDownloads) }
    }

    /// このアプリを使っている（前面にある）ときは通知しない（既定はオン）
    public var notifyOnlyWhenInactive: Bool {
        didSet { defaults.set(notifyOnlyWhenInactive, forKey: Keys.notifyOnlyWhenInactive) }
    }

    /// 通知で音を鳴らす（既定はオフ）
    public var notificationSound: Bool {
        didSet { defaults.set(notificationSound, forKey: Keys.notificationSound) }
    }

    /// 通知のどれかがオン
    public var anyNotificationEnabled: Bool { notifyBatchFinished || notifyLiveInterrupted || notifyDownloads }

    // MARK: 編集

    /// 誤認識の候補にする確からしさのしきい値
    public var reviewThreshold: ReviewThreshold {
        didSet { defaults.set(reviewThreshold.rawValue, forKey: Keys.reviewThreshold) }
    }

    /// 利用者が追加したフィラー（空白・読点・改行区切り）
    public var extraFillers: String {
        didSet {
            if extraFillers.count > Self.extraFillersLimit { extraFillers = String(extraFillers.prefix(Self.extraFillersLimit)) }
            defaults.set(extraFillers, forKey: Keys.extraFillers)
        }
    }

    public static let extraFillersLimit = 500

    /// 区間ごとの確からしさを表示する（既定はオン）
    public var showsConfidence: Bool {
        didSet { defaults.set(showsConfidence, forKey: Keys.showsConfidence) }
    }

    // MARK: AI（Vantage だけで使う）

    /// AI のモデルの選び方（自動・言語共通・用途別）
    public var aiSelectionMode: AISelectionMode {
        didSet { defaults.set(aiSelectionMode.rawValue, forKey: Keys.aiSelectionMode) }
    }

    /// 言語共通のモデル（選び方が「言語共通」のとき）
    public var aiCommonChoice: AIModelChoice {
        didSet { defaults.set(aiCommonChoice.storageValue, forKey: Keys.aiCommonChoice) }
    }

    /// 用途ごとのモデル（選び方が「用途別」のとき）
    public var aiTaskChoices: [AITask: AIModelChoice] {
        didSet {
            defaults.set(Dictionary(uniqueKeysWithValues: aiTaskChoices.map { ($0.key.rawValue, $0.value.storageValue) }),
                         forKey: Keys.aiTaskChoices)
        }
    }

    /// 誤認識の修正・文章の整形の反映のしかた（候補を確かめてから／自動で反映）
    public var aiRewriteMode: AIRewriteMode {
        didSet { defaults.set(aiRewriteMode.rawValue, forKey: Keys.aiRewriteMode) }
    }

    public var aiPreferences: AIModelPreferences {
        AIModelPreferences(mode: aiSelectionMode, common: aiCommonChoice, perTask: aiTaskChoices)
    }

    @ObservationIgnored private let defaults: UserDefaults

    /// 画面の表示設定（@AppStorage と同じ保存先）
    var displayDefaults: UserDefaults { defaults }

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
        static let notifyBatchFinished = "notify.batchFinished"
        static let notifyLiveInterrupted = "notify.liveInterrupted"
        static let notifyDownloads = "notify.downloads"
        static let notifyOnlyWhenInactive = "notify.onlyWhenInactive"
        static let notificationSound = "notify.sound"
        static let reviewThreshold = "edit.reviewThreshold"
        static let extraFillers = "edit.extraFillers"
        static let showsConfidence = "edit.showsConfidence"
        static let aiSelectionMode = "ai.selectionMode"
        static let aiCommonChoice = "ai.commonChoice"
        static let aiTaskChoices = "ai.taskChoices"
        static let aiRewriteMode = "ai.rewriteMode"
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
        notifyBatchFinished = defaults.bool(forKey: Keys.notifyBatchFinished)
        notifyLiveInterrupted = defaults.bool(forKey: Keys.notifyLiveInterrupted)
        notifyDownloads = defaults.bool(forKey: Keys.notifyDownloads)
        notifyOnlyWhenInactive = defaults.object(forKey: Keys.notifyOnlyWhenInactive) as? Bool ?? true
        notificationSound = defaults.bool(forKey: Keys.notificationSound)
        reviewThreshold = defaults.string(forKey: Keys.reviewThreshold).flatMap(ReviewThreshold.init(rawValue:)) ?? .standard
        extraFillers = String((defaults.string(forKey: Keys.extraFillers) ?? "").prefix(Self.extraFillersLimit))
        showsConfidence = defaults.object(forKey: Keys.showsConfidence) as? Bool ?? true
        aiSelectionMode = defaults.string(forKey: Keys.aiSelectionMode).flatMap(AISelectionMode.init(rawValue:)) ?? .automatic
        aiCommonChoice = defaults.string(forKey: Keys.aiCommonChoice).flatMap(AIModelChoice.init(storageValue:)) ?? .automatic
        aiTaskChoices = Self.parseTaskChoices(defaults.dictionary(forKey: Keys.aiTaskChoices))
        aiRewriteMode = defaults.string(forKey: Keys.aiRewriteMode).flatMap(AIRewriteMode.init(rawValue:)) ?? .review
    }

    static func parseTaskChoices(_ raw: [String: Any]?) -> [AITask: AIModelChoice] {
        var result: [AITask: AIModelChoice] = [:]
        for (key, value) in raw ?? [:] {
            guard let task = AITask(rawValue: key), let s = value as? String, let choice = AIModelChoice(storageValue: s) else { continue }
            result[task] = choice
        }
        return result
    }

    /// 利用者が追加したフィラーの一覧
    public var extraFillerWords: [String] { FillerRemover.parseExtra(extraFillers) }

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

/// 誤認識の候補にする確からしさのしきい値
public enum ReviewThreshold: String, CaseIterable, Identifiable, Sendable {
    /// 確からしさがかなり低いものだけ
    case strict
    case standard
    /// 少しでも低いものを広く挙げる
    case loose

    public var id: String { rawValue }

    public var value: Double {
        switch self {
        case .strict: 0.3
        case .standard: ReviewCandidateFinder.defaultThreshold
        case .loose: 0.7
        }
    }

    public var displayName: String { L("reviewThreshold.\(rawValue)") }
}

/// AI の書き換え（誤認識の修正・文章の整形）の反映のしかた
public enum AIRewriteMode: String, CaseIterable, Identifiable, Sendable {
    /// 候補を差分で確かめ、採用したものだけを反映する（既定）
    case review
    /// 検査を通った候補をすぐに反映する（原文はいつでも戻せる）
    case automatic

    public var id: String { rawValue }
    public var displayName: String { L("ai.rewriteMode.\(rawValue)") }
    /// 短い名前（横並びの選択肢用）
    public var shortName: String { L("ai.rewriteMode.\(rawValue).short") }
}
