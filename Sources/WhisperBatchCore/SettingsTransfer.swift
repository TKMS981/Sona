import Foundation

/// 設定の書き出し・読み込みに使うファイルの内容（JSON）。
///
/// - 含めるもの: 文字起こし・ライブ文字起こし・通知・編集・表示・外観の設定。
/// - 含めないもの: ゴーストモード（設定画面で説明を読んで確認したときだけ有効にするため）、背景画像（ファイル）、
///   モデルのファイル、文字起こしの結果、ファイルの場所。
/// - 読み込むときは項目ごとに値を確かめ、知らない値・範囲外の値は読み飛ばす（ほかの項目は反映する）。
public struct SettingsSnapshot: Codable, Equatable, Sendable {
    public static let formatIdentifier = "Sona.settings"
    public static let currentVersion = 1
    /// 読み込むファイルの大きさの上限
    public static let maxFileSize = 1_000_000

    public var format: String = formatIdentifier
    public var version: Int = currentVersion
    public var exportedAt: Date?
    public var general: General?
    public var live: Live?
    public var notifications: Notifications?
    public var editing: Editing?
    public var display: Display?
    public var appearance: Appearance?
    /// AI のモデルの選び方（Vantage）。モデルのファイルは含めない。
    public var ai: AI?

    public init() {}

    public struct AI: Codable, Equatable, Sendable {
        public var selectionMode: String?
        public var commonChoice: String?
        public var taskChoices: [String: String]?
        public var rewriteMode: String?
        public init() {}
    }

    public struct General: Codable, Equatable, Sendable {
        public var transcriptionLanguage: String?
        public var modelID: String?
        public var appLanguage: String?
        public var autoStartOnAdd: Bool?
        public var whisperDecoding: String?
        public init() {}
    }

    public struct Live: Codable, Equatable, Sendable {
        public var modelID: String?
        public var vocabularyHint: String?
        public var stopShortcut: String?
        public var showShortcut: String?
        public init() {}
    }

    public struct Notifications: Codable, Equatable, Sendable {
        public var batchFinished: Bool?
        public var liveInterrupted: Bool?
        public var downloads: Bool?
        public var onlyWhenInactive: Bool?
        public var sound: Bool?
        public init() {}
    }

    public struct Editing: Codable, Equatable, Sendable {
        public var reviewThreshold: String?
        public var extraFillers: String?
        public var showsConfidence: Bool?
        public init() {}
    }

    public struct Display: Codable, Equatable, Sendable {
        public var showTimestamps: Bool?
        public var liveShowTimestamps: Bool?
        public init() {}
    }

    /// 外観（値の確認と反映はアプリ側の AppearanceSettings が行う）
    public struct Appearance: Codable, Equatable, Sendable {
        public var fontFamily: String?
        public var fontSize: String?
        public var appearanceMode: String?
        public var backgroundStyle: String?
        public var backgroundColor: String?
        public var imageOpacity: Double?
        public init() {}
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    /// ファイルの内容を読む。設定のファイルでない・新しすぎる版・大きすぎるものはエラー。
    public static func decode(_ data: Data) throws(SettingsTransferError) -> SettingsSnapshot {
        guard data.count <= maxFileSize else { throw .tooLarge }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let snapshot: SettingsSnapshot
        do {
            snapshot = try decoder.decode(SettingsSnapshot.self, from: data)
        } catch {
            throw .notSettingsFile
        }
        guard snapshot.format == formatIdentifier else { throw .notSettingsFile }
        guard snapshot.version <= currentVersion, snapshot.version >= 1 else { throw .unsupportedVersion(snapshot.version) }
        return snapshot
    }
}

public enum SettingsTransferError: Error, Equatable, Sendable, LocalizedError {
    case tooLarge
    case notSettingsFile
    case unsupportedVersion(Int)

    public var errorDescription: String? {
        switch self {
        case .tooLarge: L("settings.transfer.error.tooLarge")
        case .notSettingsFile: L("settings.transfer.error.notSettings")
        case .unsupportedVersion(let v): L("settings.transfer.error.version", v)
        }
    }
}

/// 読み込みの結果
public struct SettingsImportReport: Equatable, Sendable {
    /// 反映した項目の数
    public var applied = 0
    /// 値が正しくなく読み飛ばした項目（キー名）
    public var skipped: [String] = []

    public init() {}

    mutating func apply<T>(_ value: T?, key: String, parse: (T) -> Bool) {
        guard let value else { return }
        if parse(value) { applied += 1 } else { skipped.append(key) }
    }
}

extension SettingsStore {
    /// 画面の表示設定（@AppStorage で使っているキー）
    public enum DisplayKeys {
        public static let showTimestamps = "showTimestamps"
        public static let liveShowTimestamps = "live.showTimestamps"
    }

    /// 今の設定を書き出す内容にする（外観はアプリ側から渡す）
    public func makeSnapshot(appearance: SettingsSnapshot.Appearance?, date: Date = Date()) -> SettingsSnapshot {
        var s = SettingsSnapshot()
        s.exportedAt = date
        var general = SettingsSnapshot.General()
        general.transcriptionLanguage = language.id
        general.modelID = selectedModelID
        general.appLanguage = languagePreference.rawValue
        general.autoStartOnAdd = autoStartOnAdd
        general.whisperDecoding = whisperDecoding.rawValue
        s.general = general

        var live = SettingsSnapshot.Live()
        live.modelID = liveModelID
        live.vocabularyHint = liveVocabularyHint
        live.stopShortcut = liveStopShortcut.rawValue
        live.showShortcut = liveShowShortcut.rawValue
        s.live = live

        var notifications = SettingsSnapshot.Notifications()
        notifications.batchFinished = notifyBatchFinished
        notifications.liveInterrupted = notifyLiveInterrupted
        notifications.downloads = notifyDownloads
        notifications.onlyWhenInactive = notifyOnlyWhenInactive
        notifications.sound = notificationSound
        s.notifications = notifications

        var editing = SettingsSnapshot.Editing()
        editing.reviewThreshold = reviewThreshold.rawValue
        editing.extraFillers = extraFillers
        editing.showsConfidence = showsConfidence
        s.editing = editing

        var display = SettingsSnapshot.Display()
        display.showTimestamps = displayDefaults.bool(forKey: DisplayKeys.showTimestamps)
        display.liveShowTimestamps = displayDefaults.bool(forKey: DisplayKeys.liveShowTimestamps)
        s.display = display

        var ai = SettingsSnapshot.AI()
        ai.selectionMode = aiSelectionMode.rawValue
        ai.commonChoice = aiCommonChoice.storageValue
        ai.taskChoices = Dictionary(uniqueKeysWithValues: aiTaskChoices.map { ($0.key.rawValue, $0.value.storageValue) })
        ai.rewriteMode = aiRewriteMode.rawValue
        s.ai = ai

        s.appearance = appearance
        return s
    }

    /// 読み込んだ設定を反映する（外観はアプリ側で反映する）。値を 1 つずつ確かめ、正しくないものは読み飛ばす。
    @discardableResult
    public func apply(_ snapshot: SettingsSnapshot) -> SettingsImportReport {
        var report = SettingsImportReport()
        if let g = snapshot.general {
            report.apply(g.transcriptionLanguage, key: "general.transcriptionLanguage") { value in
                guard let option = LanguageOption.allCases.first(where: { $0.id == value }) else { return false }
                language = option
                return true
            }
            report.apply(g.modelID, key: "general.modelID") { value in
                guard ModelCatalog.model(id: value) != nil else { return false }
                selectedModelID = value
                return true
            }
            report.apply(g.appLanguage, key: "general.appLanguage") { value in
                guard let pref = LanguagePreference(rawValue: value) else { return false }
                languagePreference = pref
                return true
            }
            report.apply(g.autoStartOnAdd, key: "general.autoStartOnAdd") { autoStartOnAdd = $0; return true }
            report.apply(g.whisperDecoding, key: "general.whisperDecoding") { value in
                guard let d = WhisperDecoding(rawValue: value) else { return false }
                whisperDecoding = d
                return true
            }
        }
        if let l = snapshot.live {
            report.apply(l.modelID, key: "live.modelID") { value in
                guard ModelCatalog.model(id: value)?.engine == .whisper else { return false }
                liveModelID = value
                return true
            }
            report.apply(l.vocabularyHint, key: "live.vocabularyHint") { value in
                guard value.count <= LivePromptBuilder.hintLimit else { return false }
                liveVocabularyHint = value
                return true
            }
            report.apply(l.stopShortcut, key: "live.stopShortcut") { value in
                guard let shortcut = LiveShortcut(rawValue: value), LiveShortcut.stopChoices.contains(shortcut) else { return false }
                liveStopShortcut = shortcut
                return true
            }
            report.apply(l.showShortcut, key: "live.showShortcut") { value in
                guard let shortcut = LiveShortcut(rawValue: value), LiveShortcut.showChoices.contains(shortcut) else { return false }
                liveShowShortcut = shortcut
                return true
            }
        }
        if let n = snapshot.notifications {
            report.apply(n.batchFinished, key: "notifications.batchFinished") { notifyBatchFinished = $0; return true }
            report.apply(n.liveInterrupted, key: "notifications.liveInterrupted") { notifyLiveInterrupted = $0; return true }
            report.apply(n.downloads, key: "notifications.downloads") { notifyDownloads = $0; return true }
            report.apply(n.onlyWhenInactive, key: "notifications.onlyWhenInactive") { notifyOnlyWhenInactive = $0; return true }
            report.apply(n.sound, key: "notifications.sound") { notificationSound = $0; return true }
        }
        if let e = snapshot.editing {
            report.apply(e.reviewThreshold, key: "editing.reviewThreshold") { value in
                guard let t = ReviewThreshold(rawValue: value) else { return false }
                reviewThreshold = t
                return true
            }
            report.apply(e.extraFillers, key: "editing.extraFillers") { value in
                guard value.count <= Self.extraFillersLimit else { return false }
                extraFillers = value
                return true
            }
            report.apply(e.showsConfidence, key: "editing.showsConfidence") { showsConfidence = $0; return true }
        }
        if let d = snapshot.display {
            report.apply(d.showTimestamps, key: "display.showTimestamps") {
                displayDefaults.set($0, forKey: DisplayKeys.showTimestamps)
                return true
            }
            report.apply(d.liveShowTimestamps, key: "display.liveShowTimestamps") {
                displayDefaults.set($0, forKey: DisplayKeys.liveShowTimestamps)
                return true
            }
        }
        if let a = snapshot.ai {
            report.apply(a.selectionMode, key: "ai.selectionMode") { value in
                guard let mode = AISelectionMode(rawValue: value) else { return false }
                aiSelectionMode = mode
                return true
            }
            report.apply(a.commonChoice, key: "ai.commonChoice") { value in
                guard let choice = AIModelChoice(storageValue: value) else { return false }
                aiCommonChoice = choice
                return true
            }
            report.apply(a.taskChoices, key: "ai.taskChoices") { value in
                let parsed = Self.parseTaskChoices(value)
                guard parsed.count == value.count else { return false }
                aiTaskChoices = parsed
                return true
            }
            report.apply(a.rewriteMode, key: "ai.rewriteMode") { value in
                guard let mode = AIRewriteMode(rawValue: value) else { return false }
                aiRewriteMode = mode
                return true
            }
        }
        return report
    }
}
