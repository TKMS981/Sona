import AppKit
import Foundation
import UniformTypeIdentifiers
import WhisperBatchCore
import WhisperBatchEngine

/// 文字起こし結果の編集・話者識別・要約の保存・設定の書き出しと読み込み
extension AppModel {
    // MARK: キューの順序

    /// 一覧のドラッグで順番を変える（待機中の項目は上から順に処理する）
    func moveItems(fromOffsets source: IndexSet, toOffset destination: Int) {
        transcription.move(fromOffsets: source, toOffset: destination)
    }

    // MARK: 編集（原文は残し、区間ごとの変更として持つ）

    func replaceSegment(_ id: UUID, index: Int, text: String) {
        guard let original = queue.item(id)?.transcript else { return }
        transcription.updateAnnotations(id) { $0.edits.replace(index, with: text, in: original) }
    }

    func deleteSegment(_ id: UUID, index: Int) {
        guard let original = queue.item(id)?.transcript else { return }
        transcription.updateAnnotations(id) { $0.edits.delete(index, in: original) }
    }

    func restoreSegment(_ id: UUID, index: Int) {
        transcription.updateAnnotations(id) { $0.edits.restore(index) }
    }

    /// すべて原文に戻す（話者名と要約は残す）
    func restoreAllSegments(_ id: UUID) {
        transcription.updateAnnotations(id) { $0.edits.restoreAll() }
    }

    /// まとめて書き換える（フィラー除去・AI の整文。どれも原文に戻せる）
    func applyRewrites(_ id: UUID, _ rewrites: [Int: String]) {
        guard let original = queue.item(id)?.transcript else { return }
        transcription.updateAnnotations(id) { annotations in
            for (index, text) in rewrites { annotations.edits.replace(index, with: text, in: original) }
        }
    }

    // MARK: 話者

    func setSpeakerName(_ id: UUID, speaker: Int, name: String) {
        let clean = SpeakerNaming.sanitized(name)
        transcription.updateAnnotations(id) { $0.speakerNames[speaker] = clean.isEmpty ? nil : clean }
    }

    func setSegmentSpeaker(_ id: UUID, index: Int, speaker: Int?) {
        transcription.setSpeaker(id, segment: index, speaker: speaker)
    }

    /// 話者識別の結果を消す
    func clearSpeakers(_ id: UUID) {
        guard let count = queue.item(id)?.transcript?.segments.count else { return }
        transcription.setSpeakers(id, Array(repeating: nil, count: count))
    }

    var isSpeakerModelInstalled: Bool { models.isInstalled(ModelCatalog.speakerDiarization) }

    /// 話者を識別する（この Mac の中で処理する。モデルが必要）
    func identifySpeakers(_ id: UUID, speakerCount: Int?) {
        guard speakerTasks[id] == nil, let item = queue.item(id), item.status == .completed, let storage = models.storage,
              let ai = SonaRuntime.ai, has(.speakerIdentification) else { return }
        speakerJobs[id] = SpeakerJob(phase: .reading, progress: 0)
        speakerTasks[id] = Task {
            defer {
                speakerJobs[id] = nil
                speakerTasks[id] = nil
            }
            do {
                let turns = try await ai.identifySpeakers(
                    item: item, storage: storage, speakerCount: speakerCount,
                    onRefresh: { self.transcription.applyRefreshedBookmark($0, to: id) },
                    progress: { phase, fraction in
                        Task { @MainActor in
                            guard self.speakerJobs[id] != nil else { return }
                            self.speakerJobs[id] = SpeakerJob(phase: phase, progress: fraction)
                        }
                    })
                guard let segments = queue.item(id)?.transcript?.segments else { return }
                let speakers = SpeakerAssigner.assign(segments, turns: turns)
                transcription.setSpeakers(id, speakers)
                if !speakers.contains(where: { $0 != nil }) {
                    alert = AlertMessage(title: L("speakers.failed.title"), message: L("speakers.none"))
                } else if settings.notifyBatchFinished {
                    let name = queue.item(id)?.displayName ?? ""
                    NotificationService.shared.post(title: L("notify.speakers.title"), body: L("notify.speakers.body", name),
                                                    settings: settings)
                }
            } catch is CancellationError {
                // 中止した場合は何も変えない
            } catch {
                alert = AlertMessage(title: L("speakers.failed.title"), message: userFacingMessage(for: error))
            }
        }
    }

    func cancelSpeakerIdentification(_ id: UUID) {
        speakerTasks[id]?.cancel()
    }

    // MARK: 要約・重要な発言

    /// 対象の文字起こし（編集を反映したもの）
    func analysisTranscript(_ target: AnalysisTarget) -> Transcript? {
        switch target {
        case .item(let id): queue.item(id)?.editedTranscript
        case .live: live.session.transcript.confirmed.isEmpty ? nil : live.session.transcript.transcript
        }
    }

    func analysis(_ target: AnalysisTarget) -> TranscriptAnalysis {
        switch target {
        case .item(let id): queue.item(id)?.annotations.analysis ?? TranscriptAnalysis()
        case .live: live.analysis
        }
    }

    func updateAnalysis(_ target: AnalysisTarget, _ body: (inout TranscriptAnalysis) -> Void) {
        switch target {
        case .item(let id): transcription.updateAnnotations(id) { body(&$0.analysis) }
        case .live: body(&live.analysis)
        }
    }

    /// AI に渡す行（編集と話者名を反映）
    func analysisLines(_ target: AnalysisTarget) -> [LocalAIText.Line] {
        switch target {
        case .item(let id):
            guard let item = queue.item(id), let original = item.transcript else { return [] }
            return LocalAIText.lines(original: original, edits: item.annotations.edits, speakerNames: item.annotations.speakerNames)
        case .live:
            return LocalAIText.lines(original: live.session.transcript.transcript, edits: TranscriptEdits(), speakerNames: [:])
        }
    }

    // MARK: 設定の書き出し・読み込み

    func exportSettings() {
        Task {
            let panel = NSSavePanel()
            panel.title = L("settings.transfer.export.title")
            panel.nameFieldStringValue = L("settings.transfer.fileName") + ".json"
            panel.allowedContentTypes = [.json]
            panel.canCreateDirectories = true
            panel.isExtensionHidden = false
            guard await panel.begin() == .OK, let url = panel.url else { return }
            do {
                let data = try settings.makeSnapshot(appearance: appearance.snapshot()).encoded()
                try data.write(to: url, options: [.atomic])
                settingsTransferMessage = L("settings.transfer.exported", url.lastPathComponent)
            } catch {
                settingsTransferMessage = nil
                alert = AlertMessage(title: L("settings.transfer.failed.title"),
                                     message: userFacingMessage(for: error, during: .writing(fileName: url.lastPathComponent)))
            }
        }
    }

    func importSettings() {
        Task {
            let panel = NSOpenPanel()
            panel.title = L("settings.transfer.import.title")
            panel.allowedContentTypes = [.json]
            panel.allowsMultipleSelection = false
            panel.canChooseDirectories = false
            guard await panel.begin() == .OK, let url = panel.url else { return }
            do {
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                guard size <= SettingsSnapshot.maxFileSize else { throw SettingsTransferError.tooLarge }
                let snapshot = try SettingsSnapshot.decode(try Data(contentsOf: url))
                var report = settings.apply(snapshot)
                if let a = snapshot.appearance {
                    let r = appearance.apply(a)
                    report.applied += r.applied
                    report.skipped += r.skipped
                }
                // 表示言語・文字起こしの言語の変更を画面とモデルの状態に反映する
                languagePreference = settings.languagePreference
                models.transcriptionLanguage = settings.language
                live.updateHotKeys()
                settingsTransferMessage = report.skipped.isEmpty
                    ? L("settings.transfer.imported", report.applied)
                    : L("settings.transfer.importedWithSkips", report.applied, report.skipped.count)
            } catch {
                settingsTransferMessage = nil
                alert = AlertMessage(title: L("settings.transfer.failed.title"), message: userFacingMessage(for: error))
            }
        }
    }
}
