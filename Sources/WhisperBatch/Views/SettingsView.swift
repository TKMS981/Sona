import SwiftUI
import WhisperBatchCore

/// 設定画面（⌘,）: 一般（表示言語・自動開始・Whisper の探索方式）、ライブ文字起こし、フォント、テーマ
struct SettingsView: View {
    private enum Tab: Hashable { case general, live, editing, ai, notifications, font, theme }
    @Environment(AppModel.self) private var model
    @ViewState private var tab = Tab.general

    var body: some View {
        TabView(selection: $tab) {
            GeneralSettingsTab()
                .tabItem { Label(L("settings.tab.general"), systemImage: "gearshape") }
                .tag(Tab.general)
            LiveSettingsTab()
                .tabItem { Label(L("settings.tab.live"), systemImage: "waveform.badge.mic") }
                .tag(Tab.live)
            EditingSettingsTab()
                .tabItem { Label(L("settings.tab.editing"), systemImage: "pencil.and.list.clipboard") }
                .tag(Tab.editing)
            // AI モデルの管理は Vantage だけ
            if model.has(.aiModelManagement) {
                AIModelSettingsTab()
                    .tabItem { Label(L("settings.tab.ai"), systemImage: "cpu") }
                    .tag(Tab.ai)
            }
            NotificationSettingsTab()
                .tabItem { Label(L("settings.tab.notifications"), systemImage: "bell") }
                .tag(Tab.notifications)
            FontSettingsTab()
                .tabItem { Label(L("settings.tab.font"), systemImage: "textformat") }
                .tag(Tab.font)
            ThemeSettingsTab()
                .tabItem { Label(L("settings.tab.theme"), systemImage: "paintpalette") }
                .tag(Tab.theme)
        }
        .frame(minWidth: 560)
    }
}

/// 説明文（設定項目の下に小さく表示する）
private struct SettingNote: View {
    let text: String

    var body: some View {
        Text(text)
            .appFont(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 360, alignment: .leading)
    }
}

// MARK: - 一般

private struct GeneralSettingsTab: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                Picker(L("settings.appLanguage"), selection: $model.languagePreference) {
                    Text(L("settings.appLanguage.system", LanguagePreference.system.resolved.nativeName)).tag(LanguagePreference.system)
                    Text(AppLanguage.japanese.nativeName).tag(LanguagePreference.japanese)
                    Text(AppLanguage.english.nativeName).tag(LanguagePreference.english)
                }
                .pickerStyle(.radioGroup)
                SettingNote(text: L("settings.appLanguage.note"))
            }
            Section {
                LabeledContent(L("settings.autoStart")) {
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle(L("settings.autoStart.toggle"), isOn: $model.autoStartOnAdd)
                            .toggleStyle(.checkbox)
                        SettingNote(text: L("settings.autoStart.note"))
                    }
                }
                .padding(.top, 10)
            }
            Section {
                LabeledContent(L("settings.decoding")) {
                    VStack(alignment: .leading, spacing: 4) {
                        Picker(L("settings.decoding"), selection: $model.whisperDecoding) {
                            ForEach(WhisperDecoding.allCases) { Text($0.displayName).tag($0) }
                        }
                        .pickerStyle(.radioGroup)
                        .labelsHidden()
                        SettingNote(text: L("settings.decoding.note"))
                    }
                }
                .padding(.top, 10)
            }
            Section {
                LabeledContent(L("settings.transfer")) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            Button(L("settings.transfer.export")) { model.exportSettings() }
                            Button(L("settings.transfer.import")) { model.importSettings() }
                        }
                        SettingNote(text: L("settings.transfer.note"))
                        if let message = model.settingsTransferMessage {
                            Label(message, systemImage: "checkmark.circle")
                                .appFont(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(.top, 10)
            }
        }
        .padding(20)
    }
}

// MARK: - 編集

/// 誤認識の候補・確からしさの表示・追加のフィラー
private struct EditingSettingsTab: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Section {
                LabeledContent(L("settings.editing.confidence")) {
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle(L("settings.editing.showConfidence"), isOn: $settings.showsConfidence)
                            .toggleStyle(.checkbox)
                        SettingNote(text: L("settings.editing.confidence.note"))
                    }
                }
            }
            if model.has(.reviewCandidates) {
            Section {
                LabeledContent(L("settings.editing.review")) {
                    VStack(alignment: .leading, spacing: 4) {
                        Picker(L("settings.editing.review"), selection: $settings.reviewThreshold) {
                            ForEach(ReviewThreshold.allCases) { Text($0.displayName).tag($0) }
                        }
                        .pickerStyle(.radioGroup)
                        .labelsHidden()
                        SettingNote(text: L("settings.editing.review.note"))
                    }
                }
                .padding(.top, 10)
            }
            }
            if model.has(.fillerRemoval) {
            Section {
                LabeledContent(L("settings.editing.fillers")) {
                    VStack(alignment: .leading, spacing: 4) {
                        TextField(L("settings.editing.fillers"), text: $settings.extraFillers,
                                  prompt: Text(L("settings.editing.fillers.placeholder")), axis: .vertical)
                            .labelsHidden()
                            .lineLimit(2 ... 4)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 320)
                        SettingNote(text: L("settings.editing.fillers.note"))
                    }
                }
                .padding(.top, 10)
            }
            }
        }
        .padding(20)
    }
}

// MARK: - 通知

/// 処理の終わりなどを macOS の通知で知らせる（既定はすべてオフ）
private struct NotificationSettingsTab: View {
    @Environment(AppModel.self) private var model
    private var notifications: NotificationService { .shared }

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Section {
                LabeledContent(L("settings.notify.events")) {
                    VStack(alignment: .leading, spacing: 6) {
                        toggle(L("settings.notify.batch"), $settings.notifyBatchFinished)
                        toggle(L("settings.notify.live"), $settings.notifyLiveInterrupted)
                        toggle(L("settings.notify.downloads"), $settings.notifyDownloads)
                        SettingNote(text: L("settings.notify.note"))
                    }
                }
            }
            Section {
                LabeledContent(L("settings.notify.options")) {
                    VStack(alignment: .leading, spacing: 6) {
                        Toggle(L("settings.notify.onlyInactive"), isOn: $settings.notifyOnlyWhenInactive)
                            .toggleStyle(.checkbox)
                        Toggle(L("settings.notify.sound"), isOn: $settings.notificationSound)
                            .toggleStyle(.checkbox)
                    }
                    .disabled(!settings.anyNotificationEnabled)
                }
                .padding(.top, 10)
            }
            if settings.anyNotificationEnabled {
                Section {
                    switch notifications.permission {
                    case .denied:
                        HStack(spacing: 8) {
                            Label(L("settings.notify.denied"), systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                                .appFont(.caption)
                            Button(L("settings.notify.openSettings")) { notifications.openSystemSettings() }
                                .controlSize(.small)
                        }
                    case .unsupported:
                        Label(L("settings.notify.unsupported"), systemImage: "info.circle")
                            .foregroundStyle(.secondary)
                            .appFont(.caption)
                    default:
                        EmptyView()
                    }
                }
                .padding(.top, 10)
            }
        }
        .padding(20)
        .task { await notifications.refreshPermission() }
    }

    private func toggle(_ title: String, _ binding: Binding<Bool>) -> some View {
        Toggle(title, isOn: Binding(
            get: { binding.wrappedValue },
            set: { on in
                binding.wrappedValue = on
                // オンにしたときに macOS の許可を求める（まだ決めていない場合だけ確認が出る）
                if on { Task { await notifications.requestPermissionIfNeeded() } }
            }
        ))
        .toggleStyle(.checkbox)
    }
}

// MARK: - ライブ文字起こし

/// ゴーストモードと、取り込み中だけ使えるショートカット
private struct LiveSettingsTab: View {
    @Environment(AppModel.self) private var model
    @ViewState private var showGhostConfirmation = false

    var body: some View {
        let live = model.live
        Form {
            Section {
                LabeledContent(L("settings.ghost")) {
                    VStack(alignment: .leading, spacing: 6) {
                        Toggle(L("settings.ghost.toggle"), isOn: Binding(
                            get: { model.settings.ghostMode },
                            set: { on in
                                // 有効にするのは、説明を読んで確認したときだけ
                                if on { showGhostConfirmation = true } else { live.disableGhostMode() }
                            }
                        ))
                        .toggleStyle(.checkbox)
                        SettingNote(text: L("settings.ghost.note"))
                    }
                }
            }
            Section {
                LabeledContent(L("settings.live.stopShortcut")) {
                    Picker(L("settings.live.stopShortcut"), selection: Binding(
                        get: { model.settings.liveStopShortcut },
                        set: { model.settings.liveStopShortcut = $0; live.updateHotKeys() }
                    )) {
                        ForEach(LiveShortcut.stopChoices) { Text($0.symbol ?? L("settings.live.shortcutOff")).tag($0) }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 160)
                }
                .padding(.top, 10)
                LabeledContent(L("settings.live.showShortcut")) {
                    Picker(L("settings.live.showShortcut"), selection: Binding(
                        get: { model.settings.liveShowShortcut },
                        set: { model.settings.liveShowShortcut = $0; live.updateHotKeys() }
                    )) {
                        ForEach(LiveShortcut.showChoices) { Text($0.symbol ?? L("settings.live.shortcutOff")).tag($0) }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 160)
                }
                SettingNote(text: L("settings.live.shortcut.note"))
                if !live.failedShortcuts.isEmpty {
                    Label(L("settings.live.shortcut.failed"), systemImage: "exclamationmark.triangle")
                        .appFont(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
        .padding(20)
        .alert(L("settings.ghost.confirm.title"), isPresented: $showGhostConfirmation) {
            Button(L("settings.ghost.confirm.enable")) { live.enableGhostMode() }
            Button(L("common.cancel"), role: .cancel) {}
        } message: {
            Text(L("settings.ghost.confirm.message"))
        }
    }
}

// MARK: - フォント

private struct FontSettingsTab: View {
    @Environment(AppModel.self) private var model
    @Environment(\.appTypography) private var typography

    /// 書体の一覧は起動中に 1 回だけ作る（数百件あるため）
    private static let families = AppearanceSettings.availableFontFamilies()

    var body: some View {
        @Bindable var appearance = model.appearance
        Form {
            Picker(L("settings.font.family"), selection: $appearance.fontFamily) {
                Text(L("settings.font.system")).tag("")
                Divider()
                ForEach(Self.families, id: \.family) { item in
                    Text(item.displayName).tag(item.family)
                }
            }
            Picker(L("settings.font.size"), selection: $appearance.fontSize) {
                ForEach(FontSizeOption.allCases) { option in
                    Text(option.label).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 360)

            LabeledContent(L("settings.font.preview")) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("settings.font.preview.title"))
                        .appFont(.headline)
                    Text(L("settings.font.preview.body"))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(L("settings.font.preview.caption"))
                        .appFont(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(10)
                .frame(maxWidth: 360, alignment: .leading)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            }
            SettingNote(text: L("settings.font.note"))

            HStack {
                Spacer()
                Button(L("settings.resetDefaults")) {
                    appearance.fontFamily = ""
                    appearance.fontSize = .standard
                }
                .disabled(typography.isStandard)
            }
        }
        .padding(20)
    }
}

// MARK: - テーマ

private struct ThemeSettingsTab: View {
    @Environment(AppModel.self) private var model
    @ViewState private var showImageImporter = false
    @ViewState private var imageError: String?

    var body: some View {
        @Bindable var appearance = model.appearance
        Form {
            Picker(L("settings.appearance"), selection: $appearance.appearanceMode) {
                ForEach(AppearanceMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 320)

            Picker(L("settings.background"), selection: $appearance.backgroundStyle) {
                ForEach(BackgroundStyle.allCases) { style in
                    Text(style.label).tag(style)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 320)

            switch appearance.backgroundStyle {
            case .standard:
                EmptyView()
            case .color:
                LabeledContent(L("settings.background.colorPicker")) {
                    ColorPicker(L("settings.background.colorPicker"), selection: Binding(
                        get: { appearance.backgroundColor.color },
                        set: { appearance.backgroundColor = ThemeColor($0) }
                    ))
                    .labelsHidden()
                    .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 5 }
                }
                SettingNote(text: L("settings.background.color.note"))
            case .image:
                LabeledContent(L("settings.background.imageFile")) {
                    HStack(spacing: 8) {
                        Text(appearance.imageDisplayName ?? L("settings.background.noImage"))
                            .foregroundStyle(appearance.imageDisplayName == nil ? .secondary : .primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: 180, alignment: .leading)
                        Button(L("settings.background.chooseImage")) { showImageImporter = true }
                        Button(L("settings.background.removeImage")) { appearance.clearBackgroundImage() }
                            .disabled(appearance.backgroundImage == nil)
                    }
                }
                LabeledContent(L("settings.background.opacity")) {
                    HStack(spacing: 8) {
                        Slider(value: $appearance.imageOpacity, in: AppearanceSettings.imageOpacityRange)
                            .frame(maxWidth: 220)
                            .accessibilityValue(L("common.percent", Int((appearance.imageOpacity * 100).rounded())))
                        Text(L("common.percentShort", Int((appearance.imageOpacity * 100).rounded())))
                            .appFont(.body, monospacedDigit: true)
                            .frame(width: 44, alignment: .trailing)
                    }
                    .disabled(appearance.backgroundImage == nil)
                }
                SettingNote(text: L("settings.background.image.note"))
            }

            if appearance.backgroundStyle != .standard {
                LabeledContent(L("settings.background.preview")) {
                    ThemeBackground(settings: appearance)
                        .frame(width: 200, height: 112)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay {
                            RoundedRectangle(cornerRadius: 8).strokeBorder(.separator)
                        }
                        .accessibilityHidden(true)
                        // 見出しを枠の上端にそろえる
                        .alignmentGuide(.firstTextBaseline) { $0[.top] + 12 }
                }
            }
        }
        .padding(20)
        .fileImporter(isPresented: $showImageImporter, allowedContentTypes: AppearanceSettings.imageContentTypes) { result in
            switch result {
            case .success(let url):
                do {
                    try appearance.setBackgroundImage(from: url)
                } catch {
                    imageError = L("settings.background.imageFailed", url.lastPathComponent)
                }
            case .failure(let error):
                imageError = userFacingMessage(for: error)
            }
        }
        .alert(
            L("settings.background.imageFailed.title"),
            isPresented: Binding(get: { imageError != nil }, set: { if !$0 { imageError = nil } })
        ) {
            Button(L("common.ok")) {}
        } message: {
            Text(imageError ?? "")
        }
    }
}
