import Foundation
import Observation
import WhisperBatchCore

/// 文字起こしキューと一括処理。
///
/// - 追加した項目は、すぐに長さと種類を確認する（読み込めない形式を早めに知らせる）。
/// - 一括処理では、モデルを 1 回読み込み、待機中の項目を順に処理する。1 件の失敗では止めない。
///
/// 状態の更新はすべてメインアクターで行う。認識そのものは各エンジンが専用のキューやスレッドで行う。
@MainActor
@Observable
public final class TranscriptionService {
    /// モデル（または OS の音声認識）を読み込む
    public typealias TranscriberLoading = @MainActor (SpeechModel, LanguageOption) async throws -> any Transcriber
    /// ファイルの長さと種類を調べる
    public typealias MediaInspecting = @Sendable (URL) async throws -> MediaInfo
    /// 長い無音を飛ばすときの発話区間の検出（Silero VAD）を読み込む
    public typealias VoiceActivityLoading = @MainActor () async throws -> any SpeechRegionDetecting

    public private(set) var queue = TranscriptionQueue()
    public private(set) var isRunning = false
    public private(set) var isLoadingModel = false

    @ObservationIgnored private let loadTranscriber: TranscriberLoading
    @ObservationIgnored private let inspectMedia: MediaInspecting
    @ObservationIgnored private let loadVoiceActivity: VoiceActivityLoading
    @ObservationIgnored private var runTask: Task<Void, Never>?
    @ObservationIgnored private var probeQueue: [UUID] = []
    @ObservationIgnored private var probeTask: Task<Void, Never>?
    /// 追加直後の確認で読み込めないと分かった項目（次の一括処理の結果に失敗として含める）
    @ObservationIgnored private var probeFailedIDs: Set<UUID> = []
    /// 文字起こしの内容（編集・話者・結果そのもの）が変わった・項目を削除したときに呼ぶ（AI の結果を再利用しないため）
    @ObservationIgnored public var onTranscriptInputChanged: ((Set<UUID>) -> Void)?

    public init(loadTranscriber: @escaping TranscriberLoading,
                inspectMedia: @escaping MediaInspecting = { try await MediaInspector.inspect($0) },
                loadVoiceActivity: @escaping VoiceActivityLoading = {
                    throw WhisperBatchError.modelNotInstalled(modelName: ModelCatalog.voiceActivity.displayName)
                }) {
        self.loadTranscriber = loadTranscriber
        self.inspectMedia = inspectMedia
        self.loadVoiceActivity = loadVoiceActivity
    }

    /// アプリで使う構成（モデルは `storage` から読み込む。`ai` は Vantage の AI の実装で、Air では nil）
    public convenience init(storage: ModelStorage?, ai: (any AIRuntime)? = nil) {
        self.init(loadTranscriber: { model, language in
            try await TranscriberLoader.load(model, storage: storage, language: language, ai: ai)
        }, loadVoiceActivity: {
            guard let storage else {
                throw WhisperBatchError.modelNotInstalled(modelName: ModelCatalog.voiceActivity.displayName)
            }
            return try await VoiceActivityLoader.load(storage: storage)
        })
    }

    // MARK: キューの編集

    /// ファイルを追加し、追加した項目の確認を始める
    @discardableResult
    public func add(_ candidates: [FileCandidate]) -> AddReport {
        let report = queue.add(candidates)
        enqueueProbe(report.added)
        return report
    }

    /// 指定した項目を削除する（処理中の項目は残す）。削除した件数を返す。
    @discardableResult
    public func remove(_ ids: Set<UUID>) -> Int { removing { $0.remove(ids) } }

    @discardableResult
    public func removeAllPending() -> Int { removing { $0.removeAllPending() } }

    @discardableResult
    public func removeAllRemovable() -> Int { removing { $0.removeAllRemovable() } }

    @discardableResult
    public func removeAllCompleted() -> Int { removing { $0.removeAllCompleted() } }

    /// 削除して、消えた項目を知らせる
    private func removing(_ body: (inout TranscriptionQueue) -> Int) -> Int {
        let before = Set(queue.items.map(\.id))
        let count = body(&queue)
        if count > 0 { notifyInputChanged(before.subtracting(queue.items.map(\.id))) }
        return count
    }

    private func notifyInputChanged(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        onTranscriptInputChanged?(ids)
    }

    /// 項目の順序を変える（待機中の項目は上から順に処理する）
    public func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        queue.move(fromOffsets: source, toOffset: destination)
    }

    /// 完了した項目の編集・話者名・要約などを変える
    public func updateAnnotations(_ id: UUID, _ body: (inout TranscriptAnnotations) -> Void) {
        let before = queue.item(id)?.annotations
        queue.updateAnnotations(id, body)
        // AI に渡す文が変わる変更（編集・話者名）だけを知らせる（要約などの結果を入れただけなら知らせない）
        if let before, let after = queue.item(id)?.annotations,
           before.edits != after.edits || before.speakerNames != after.speakerNames {
            notifyInputChanged([id])
        }
    }

    /// 話者識別の結果を入れる
    public func setSpeakers(_ id: UUID, _ speakers: [Int?]) {
        queue.setSpeakers(id, speakers)
        notifyInputChanged([id])
    }

    /// 1 つの区間の話者を変える
    public func setSpeaker(_ id: UUID, segment: Int, speaker: Int?) {
        queue.setSpeaker(id, segment: segment, speaker: speaker)
        notifyInputChanged([id])
    }

    /// 古くなったブックマークを作り直したときに、キューの項目へ反映する
    public func applyRefreshedBookmark(_ refreshed: SecurityScopedAccess.RefreshedBookmark, to id: UUID) {
        queue.updateLocation(id, url: refreshed.url, bookmark: refreshed.bookmark)
    }

    /// 失敗・キャンセル・完了した項目を待機中に戻す。戻した件数を返す。
    @discardableResult
    public func retry(_ ids: Set<UUID>) -> Int {
        probeFailedIDs.subtract(ids)
        let count = queue.resetForRetry(ids)
        if count > 0 { notifyInputChanged(ids) }
        return count
    }

    // MARK: 一括処理

    /// 待機中の項目を順に文字起こしする。終わったとき（中止を含む）に結果を `onFinish` へ渡す。
    /// 何も処理しなかった場合の結果は nil。既に処理中なら何もしない。
    /// - Parameters:
    ///   - decoding: Whisper の探索方式（ほかの方式では使わない）
    ///   - skipsSilence: 長い無音を飛ばす（Silero VAD。Whisper だけ）。モデルがない・読み込めないときは
    ///     飛ばさずに（従来どおり）文字起こしし、理由を `onNotice` に渡す。
    public func start(model: SpeechModel, language: LanguageOption, decoding: WhisperDecoding = .default,
                      skipsSilence: Bool = false,
                      onFinish: @escaping @MainActor (BatchOutcome?) -> Void = { _ in },
                      onNotice: @escaping @MainActor (String) -> Void = { _ in }) {
        guard !isRunning else { return }
        isRunning = true
        let options = TranscriptionOptions(language: language, decoding: decoding)
        let usesVoiceActivity = skipsSilence && model.engine == .whisper
        runTask = Task {
            let outcome = await runBatch(model: model, options: options, usesVoiceActivity: usesVoiceActivity, onNotice: onNotice)
            onFinish(outcome)
            isRunning = false
            isLoadingModel = false
            runTask = nil
        }
    }

    public func cancel() {
        runTask?.cancel()
    }

    /// 処理中なら、モデルの解放と一時ファイルの削除が終わるまで待つ
    public func waitUntilFinished() async {
        await runTask?.value
    }

    private func runBatch(model: SpeechModel, options: TranscriptionOptions, usesVoiceActivity: Bool,
                          onNotice: @MainActor (String) -> Void) async -> BatchOutcome? {
        isLoadingModel = true
        let context: any Transcriber
        do {
            context = try await loadTranscriber(model, options.language)
        } catch {
            return .couldNotStart(ItemFailure(error))
        }
        var options = options
        if usesVoiceActivity {
            do {
                options.voiceActivity = try await loadVoiceActivity()
            } catch is CancellationError {
                isLoadingModel = false
                return .cancelled(succeeded: 0, failed: 0, remaining: queue.counts.pending)
            } catch {
                // 無音を飛ばせないだけなので、止めずに従来どおり文字起こしする
                onNotice(L("vad.unavailable", ItemFailure(error).message))
            }
        }
        isLoadingModel = false

        var succeeded = 0
        var failed = 0
        var cancelled = false

        while let id = queue.nextPendingID {
            if Task.isCancelled { cancelled = true; break }
            guard let item = queue.item(id) else { continue }
            do { try queue.markProcessing(id, phase: .transcribing) } catch { continue }
            do {
                let transcript = try await process(item, context: context, options: options)
                try queue.markCompleted(id, transcript: transcript)
                notifyInputChanged([id])
                succeeded += 1
            } catch is CancellationError {
                try? queue.markCancelled(id)
                cancelled = true
                break
            } catch {
                // 1 件の失敗では止めず、次のファイルへ進む
                try? queue.markFailed(id, failure: ItemFailure(error, during: .reading(fileName: item.displayName)))
                failed += 1
            }
        }
        // 追加時点で読み込めなかった項目も、この回の失敗として数える
        failed += probeFailedIDs.filter { queue.item($0)?.status.isFailed == true }.count
        probeFailedIDs.removeAll()
        // context はここでスコープを抜けて解放される
        guard succeeded + failed > 0 || cancelled else { return nil }
        return .make(succeeded: succeeded, failed: failed, wasCancelled: cancelled, remaining: queue.counts.pending)
    }

    /// 1 件分の処理。動画も音声ファイルと同じく、音声トラックを AVFoundation で直接読み出して文字起こしする。
    /// （以前は一時 MP3 に変換してから読んでいたが、同じデコードの後に不可逆な変換が 1 回増えるだけで、
    ///   講義動画などの計測では変換が全体の 16〜29% を占め、文字起こしの結果に差はなかったため、直接読む）
    private func process(_ item: QueueItem, context: any Transcriber, options: TranscriptionOptions) async throws -> Transcript {
        let id = item.id
        return try await SecurityScopedAccess.withAccess(
            url: item.url, bookmark: item.bookmark,
            onRefresh: { applyRefreshedBookmark($0, to: id) }
        ) { url in
            // 追加直後の確認が終わっていない場合もあるので、ここで種類を確かめる
            let info = try await inspectMedia(url)
            queue.setMediaKind(id, info.kind)
            if info.duration > 0 { queue.setDuration(id, info.duration) }

            try queue.setPhase(id, .transcribing)
            return try await transcribe(url, id: id, context: context, options: options)
        }
    }

    private func transcribe(_ url: URL, id: UUID, context: any Transcriber, options: TranscriptionOptions) async throws -> Transcript {
        // 進捗の表示の更新は間引く（認識の処理そのものは変えない）
        let gate = ProgressGate()
        return try await context.transcribe(fileURL: url, options: options) { p in
            guard gate.pass(p) else { return }
            Task { @MainActor in self.queue.updateProgress(id, phase: .transcribing, p) }
        }
    }

    // MARK: 長さと種類の確認（読み込めない形式を早めに知らせる）

    private func enqueueProbe(_ ids: [UUID]) {
        probeQueue += ids
        guard probeTask == nil, !probeQueue.isEmpty else { return }
        probeTask = Task {
            while !probeQueue.isEmpty {
                let id = probeQueue.removeFirst()
                guard let item = queue.item(id), item.status == .pending else { continue }
                do {
                    let info = try await SecurityScopedAccess.withAccess(
                        url: item.url, bookmark: item.bookmark,
                        onRefresh: { applyRefreshedBookmark($0, to: id) }
                    ) { url in
                        try await inspectMedia(url)
                    }
                    queue.setDuration(id, info.duration > 0 ? info.duration : nil)
                    queue.setMediaKind(id, info.kind)
                } catch {
                    // 処理が既に始まっていればそちらの結果に任せる
                    if queue.item(id)?.status == .pending {
                        try? queue.markFailed(id, failure: ItemFailure(error, during: .reading(fileName: item.displayName)))
                        probeFailedIDs.insert(id)
                    }
                }
            }
            probeTask = nil
        }
    }
}
