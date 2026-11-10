import CoreGraphics
import Foundation
import Observation
import WhisperBatchCore

/// 逐次認識に使う認識器（Whisper。テストでは差し替える）
public protocol LiveRecognizer: AnyObject, Sendable {
    /// 16kHz モノラルの音声を認識する。時刻は samples の先頭からの相対秒。
    /// - Parameters:
    ///   - language: 言語コード（nil は自動判定）
    ///   - prompt: 手がかりの文（語彙のヒントと直前に確定した文。nil ならなし）
    func recognize(_ samples: [Float], language: String?, prompt: String?) async throws -> LiveRecognition
}

public struct LiveRecognition: Sendable, Equatable {
    public var segments: [TranscriptSegment]
    /// 認識に使った（自動判定時は判定した）言語コード
    public var language: String?

    public init(segments: [TranscriptSegment], language: String?) {
        self.segments = segments
        self.language = language
    }
}

extension WhisperContext: LiveRecognizer {
    /// 逐次認識は応答の速さを優先して Greedy で認識する（結果が不確かなときは温度を上げて選び直す）。
    public func recognize(_ samples: [Float], language: String?, prompt: String?) async throws -> LiveRecognition {
        try await recognizeLive(samples, language: language, prompt: prompt, decoding: .greedy)
    }

    /// whisper.cpp は 1 秒未満の音声を認識しないため、短いときは末尾に無音を足す。
    func recognizeLive(_ samples: [Float], language: String?, prompt: String?, decoding: WhisperDecoding) async throws -> LiveRecognition {
        let minimum = Int(LiveAudioSink.sampleRate * 1.1)
        let input = samples.count >= minimum ? samples : samples + [Float](repeating: 0, count: minimum - samples.count)
        let result = try await transcribe(samples: input, language: language, decoding: decoding, prompt: prompt, progress: { _ in })
        let limit = Double(samples.count) / LiveAudioSink.sampleRate
        let segments = result.segments.compactMap { seg -> TranscriptSegment? in
            guard seg.start < limit else { return nil }
            return TranscriptSegment(start: seg.start, end: min(seg.end, limit), text: seg.text)
        }
        return LiveRecognition(segments: segments, language: result.language)
    }
}

/// 画面やマイクの音声を取り込みながら、Whisper で逐次文字起こしする 1 回分のセッション。
///
/// - 音声はメモリ上で扱い、確定した分は捨てる（保持する音声は `LiveCommitPolicy.hardLimit` 秒まで）。
/// - 音声をファイルに書くのは、開始前に利用者が「音声も保存する」を選んだときだけ（一時ファイル）。
/// - 音声も結果も外部へ送らない。
///
/// 状態の更新はすべてメインアクターで行う。認識そのものは Whisper の専用キューで行う。
@MainActor
@Observable
public final class LiveTranscriptionSession {
    public enum State: Equatable, Sendable {
        /// 開始前
        case idle
        /// モデルの読み込み・取り込みの開始中
        case preparing
        case running
        /// 一時停止の処理中（残りの音声を確定している）
        case pausing
        case paused
        /// 再開の処理中
        case resuming
        /// 終了の処理中（残りの音声を確定している）
        case finishing
        /// 終了した（結果を保存できる）
        case finished

        /// 取り込み中または一時停止中（セッションが続いている）
        public var isActive: Bool {
            switch self {
            case .idle, .finished: false
            default: true
            }
        }

        /// 音声を取り込んでいる（取り込みの開始・停止の途中を含む）
        public var isCapturing: Bool {
            switch self {
            case .preparing, .running, .pausing, .resuming, .finishing: true
            default: false
            }
        }
    }

    public struct Notice: Identifiable, Equatable, Sendable {
        public enum Level: Sendable { case info, warning, error }
        public let id = UUID()
        public var level: Level
        public var message: String
        public var date: Date
    }

    /// 入力ごとの状態（画面表示用）
    public struct InputStatus: Identifiable, Equatable, Sendable {
        public var kind: LiveInputKind
        /// 選んだウィンドウ・画面・マイクの名前
        public var label: String
        /// 取り込んでいる
        public var isActive: Bool
        /// 選んだウィンドウが画面に表示されているか（ウィンドウ以外は常に true）
        public var isVisible: Bool
        /// 直近の音量（RMS、0...1）
        public var level: Float
        public var id: LiveInputKind { kind }
    }

    /// 開始の設定
    public struct Configuration {
        public var model: SpeechModel
        public var language: LanguageOption
        /// 取り込む入力（画面の音声・マイク）
        public var sources: [any LiveAudioSource]
        /// 入力の表示名
        public var labels: [LiveInputKind: String]
        /// 選んだウィンドウの番号（閉じられたことを検知するため。ウィンドウ以外は nil）
        public var windowID: CGWindowID?
        /// 音声を一時ファイルに書き、終了後に保存できるようにする
        public var recordsAudio: Bool
        /// 語彙のヒント（固有名詞や専門用語。認識の手がかりとして Whisper に渡す。外部へは送らない）
        public var vocabularyHint: String

        public init(model: SpeechModel, language: LanguageOption, sources: [any LiveAudioSource],
                    labels: [LiveInputKind: String], windowID: CGWindowID? = nil, recordsAudio: Bool = false,
                    vocabularyHint: String = "") {
            self.model = model
            self.language = language
            self.sources = sources
            self.labels = labels
            self.windowID = windowID
            self.recordsAudio = recordsAudio
            self.vocabularyHint = vocabularyHint
        }
    }

    public typealias RecognizerLoading = @MainActor (SpeechModel) async throws -> any LiveRecognizer

    // MARK: 公開する状態

    public private(set) var state: State = .idle
    public private(set) var transcript = LiveTranscript()
    /// 認識中（Whisper が処理している）
    public private(set) var isRecognizing = false
    public private(set) var inputs: [InputStatus] = []
    /// 直近の知らせ（新しいものが後ろ。最大 `maxNotices` 件）
    public private(set) var notices: [Notice] = []
    /// 開始に失敗したときの理由
    public private(set) var startError: String?
    /// 使っているモデル
    public private(set) var model: SpeechModel?
    public private(set) var language: LanguageOption = .japanese
    /// 開始した日時
    public private(set) var startedAt: Date?
    /// 処理が追いつかずに認識しなかった音声の長さ（秒）
    public private(set) var droppedSeconds: TimeInterval = 0
    /// 終了後に保存できる音声（一時ファイル）
    public private(set) var recordedAudioURL: URL?
    /// 音声を一時ファイルに書いている
    public private(set) var isRecordingAudio = false
    /// 保存していない結果がある
    public private(set) var hasUnsavedTranscript = false
    /// 認識が追いついていない音声の長さ（秒。まだ一度も認識していない分）
    public private(set) var backlogSeconds: TimeInterval = 0

    /// 調査・測定用の記録（画面には出さない）
    public struct Diagnostics: Equatable, Sendable {
        /// 認識した回数
        public var recognitions = 0
        /// 確定した理由ごとの回数
        public var commits: [LiveCommitPolicy.Decision.Reason: Int] = [:]
        /// 直近の確定の理由
        public var lastCommitReason: LiveCommitPolicy.Decision.Reason = .none
        /// 発話がないと判定して、認識せずに捨てた音声（秒）
        public var silenceSkippedSeconds: TimeInterval = 0
        /// 一度に認識した音声の最大の長さ（秒）
        public var longestWindowSeconds: TimeInterval = 0
        /// 認識が追いついていない音声の最大（秒）
        public var longestBacklogSeconds: TimeInterval = 0
    }
    @ObservationIgnored public private(set) var diagnostics = Diagnostics()

    // MARK: 内部

    @ObservationIgnored private let loadRecognizer: RecognizerLoading
    @ObservationIgnored public let policy: LiveCommitPolicy
    @ObservationIgnored public let promptBuilder: LivePromptBuilder
    @ObservationIgnored private var vocabularyHint = ""
    @ObservationIgnored private let detector = VoiceActivityDetector()
    @ObservationIgnored private let sampleRate = LiveAudioSink.sampleRate
    @ObservationIgnored private let collectInterval: Duration
    @ObservationIgnored private var recognizer: (any LiveRecognizer)?
    @ObservationIgnored private var sources: [any LiveAudioSource] = []
    @ObservationIgnored private var labels: [LiveInputKind: String] = [:]
    @ObservationIgnored private var windowID: CGWindowID?
    /// 取り込んでいる入力
    @ObservationIgnored private var activeKinds: Set<LiveInputKind> = []
    /// 対象が閉じたなどで、再開しても取り込めない入力
    @ObservationIgnored private var lostKinds: Set<LiveInputKind> = []
    @ObservationIgnored private var sink = LiveAudioSink()
    @ObservationIgnored private var window: LiveAudioWindow
    @ObservationIgnored private var recorder: LiveAudioRecorder?
    /// 書いている途中の一時ファイル（テスト用）
    var recordingURL: URL? { recorder?.url }
    @ObservationIgnored private var collectorTask: Task<Void, Never>?
    @ObservationIgnored private var recognitionTask: Task<Void, Never>?
    @ObservationIgnored private var stopRecognitionLoop = false
    /// 最後に認識した音声の終わり（タイムラインのサンプル位置）
    @ObservationIgnored private var lastRecognizedEnd = 0
    @ObservationIgnored private var lockedLanguage: String?
    @ObservationIgnored private var consecutiveFailures = 0
    @ObservationIgnored private var accumulatedActive: TimeInterval = 0
    @ObservationIgnored private var activeSince: Date?
    @ObservationIgnored private var lastPresenceCheck = Date.distantPast
    @ObservationIgnored private var lastDropNotice = Date.distantPast
    @ObservationIgnored private var cancelPreparation = false

    static let maxNotices = 30

    public init(policy: LiveCommitPolicy = LiveCommitPolicy(),
                promptBuilder: LivePromptBuilder = LivePromptBuilder(),
                collectInterval: Duration = .milliseconds(100),
                loadRecognizer: @escaping RecognizerLoading) {
        self.policy = policy
        self.promptBuilder = promptBuilder
        self.collectInterval = collectInterval
        self.loadRecognizer = loadRecognizer
        window = LiveAudioWindow(sampleRate: LiveAudioSink.sampleRate, capacity: policy.hardLimit)
    }

    /// アプリで使う構成（モデルは `storage` から読み込む）
    public convenience init(storage: ModelStorage?) {
        self.init(loadRecognizer: { model in
            guard model.engine == .whisper, let storage, let file = model.files.first, storage.isInstalled(model) else {
                throw WhisperBatchError.modelNotInstalled(modelName: model.displayName)
            }
            try await storage.verifyContents(of: model)
            return try await WhisperContext.load(model: model, fileURL: storage.fileURL(for: file, of: model))
        })
    }

    // MARK: 参照

    /// 取り込んでいた時間（一時停止していた時間は含めない）
    public func elapsed(at date: Date = Date()) -> TimeInterval {
        accumulatedActive + (activeSince.map { max(date.timeIntervalSince($0), 0) } ?? 0)
    }

    /// 認識を待っている音声の長さ（秒、確定していない分）
    public var pendingAudioSeconds: TimeInterval { window.duration }

    // MARK: 開始

    /// モデルを読み込み、入力の取り込みを始める。失敗したら `startError` に理由を入れて開始前に戻る。
    public func start(_ configuration: Configuration) async {
        guard state == .idle || state == .finished else { return }
        resetForNewSession()
        state = .preparing
        cancelPreparation = false
        model = configuration.model
        language = configuration.language
        sources = configuration.sources
        labels = configuration.labels
        windowID = configuration.windowID
        vocabularyHint = LivePromptBuilder.sanitizedHint(configuration.vocabularyHint)
        lockedLanguage = configuration.language.code
        inputs = configuration.sources.map {
            InputStatus(kind: $0.kind, label: configuration.labels[$0.kind] ?? "", isActive: false, isVisible: true, level: 0)
        }

        do {
            guard !configuration.sources.isEmpty else { throw LiveCaptureError.noInputStarted }
            recognizer = try await loadRecognizer(configuration.model)
            try checkCancelled()
            if configuration.recordsAudio {
                // 1 時間分の空きがあるかを先に確かめる（足りなくなったら途中で書くのをやめて知らせる）
                try DiskSpace.ensure(LiveAudioRecorder.bytesPerHour, availableIn: [LiveRecordingWorkspace.volumeProbe])
                recorder = try LiveAudioRecorder()
                isRecordingAudio = true
            }
            try await startSources(configuration.sources.map(\.kind), reportFailures: true)
            try checkCancelled()
        } catch {
            await stopSources()
            recognizer = nil
            discardRecorder()
            if !(error is CancellationError) { startError = userFacingMessage(for: error) }
            sources = []
            inputs = []
            state = .idle
            return
        }
        startedAt = Date()
        activeSince = Date()
        state = .running
        startLoops()
    }

    private func checkCancelled() throws {
        if cancelPreparation { throw CancellationError() }
    }

    // MARK: 一時停止・再開・終了

    /// 取り込みを止め、残りの音声を確定させる。入力はそのまま（再開できる）。
    public func pause() async {
        guard state == .running else { return }
        state = .pausing
        await stopCaptureAndFlush()
        state = .paused
    }

    /// 一時停止した入力の取り込みを再開する。どの入力も再開できなければ一時停止のまま。
    public func resume() async {
        guard state == .paused else { return }
        state = .resuming
        let kinds = sources.map(\.kind).filter { !lostKinds.contains($0) }
        do {
            try await startSources(kinds, reportFailures: true)
        } catch {
            addNotice(.error, userFacingMessage(for: error))
            state = .paused
            return
        }
        activeSince = Date()
        state = .running
        startLoops()
    }

    /// 取り込みを止め、残りの音声を確定させて終える。準備中なら取り消す。
    public func finish() async {
        // 一時停止・再開の途中なら、終わるのを待ってから終了する
        while state == .pausing || state == .resuming {
            try? await Task.sleep(for: .milliseconds(50))
        }
        switch state {
        case .preparing:
            cancelPreparation = true
            return
        case .running:
            state = .finishing
            await stopCaptureAndFlush()
        case .paused:
            state = .finishing
        default:
            return
        }
        recognizer = nil
        if let recorder {
            recorder.close()
            recordedAudioURL = recorder.writtenFrames > 0 ? recorder.url : nil
            if recorder.writtenFrames == 0 { LiveRecordingWorkspace.remove(recorder.url) }
            self.recorder = nil
        }
        isRecordingAudio = false
        sources = []
        for i in inputs.indices { inputs[i].isActive = false; inputs[i].level = 0 }
        transcript.clearProvisional()
        hasUnsavedTranscript = !transcript.confirmed.isEmpty
        state = .finished
    }

    /// 終了した結果と一時ファイルを消して、開始前に戻す
    public func reset() {
        guard state == .finished || state == .idle else { return }
        resetForNewSession()
        state = .idle
    }

    /// 結果を保存した
    public func markTranscriptSaved() {
        hasUnsavedTranscript = false
    }

    /// 一時ファイルの音声を、利用者が選んだ場所へ移す
    public func moveRecordedAudio(to destination: URL) throws {
        guard let source = recordedAudioURL else { throw WhisperBatchError.nothingToExport }
        let fm = FileManager.default
        do {
            if fm.fileExists(atPath: destination.path) {
                _ = try fm.replaceItemAt(destination, withItemAt: source)
            } else {
                try fm.moveItem(at: source, to: destination)
            }
        } catch {
            let name = destination.lastPathComponent
            throw ErrorMapper.map(error, during: .writing(fileName: name))
                ?? .exportFailed(fileName: name, detail: (error as NSError).localizedDescription)
        }
        recordedAudioURL = nil
    }

    /// 保存しない音声の一時ファイルを消す
    public func discardRecordedAudio() {
        if let url = recordedAudioURL { LiveRecordingWorkspace.remove(url) }
        recordedAudioURL = nil
    }

    /// アプリの終了時: 取り込みを止め、一時ファイルを消す
    public func shutdown() async {
        if state == .preparing {
            cancelPreparation = true
        }
        await finish()
        discardRecordedAudio()
        discardRecorder()
    }

    // MARK: private

    private func resetForNewSession() {
        discardRecordedAudio()
        discardRecorder()
        transcript = LiveTranscript()
        notices = []
        startError = nil
        inputs = []
        droppedSeconds = 0
        hasUnsavedTranscript = false
        startedAt = nil
        accumulatedActive = 0
        activeSince = nil
        activeKinds = []
        lostKinds = []
        sink = LiveAudioSink()
        window = LiveAudioWindow(sampleRate: sampleRate, capacity: policy.hardLimit)
        lastRecognizedEnd = 0
        backlogSeconds = 0
        diagnostics = Diagnostics()
        consecutiveFailures = 0
        lastDropNotice = .distantPast
    }

    private func discardRecorder() {
        if let recorder {
            recorder.close()
            LiveRecordingWorkspace.remove(recorder.url)
        }
        recorder = nil
        isRecordingAudio = false
    }

    /// 入力を始める。1 つも始められなければエラーを投げる（1 つだけならその理由）。
    private func startSources(_ kinds: [LiveInputKind], reportFailures: Bool) async throws {
        var started: Set<LiveInputKind> = []
        var errors: [any Error] = []
        sink.setInputs(Set(kinds))
        for source in sources where kinds.contains(source.kind) {
            do {
                try await source.start(sink: sink)
                started.insert(source.kind)
            } catch {
                errors.append(error)
                if reportFailures, kinds.count > 1 {
                    addNotice(.error, inputName(source.kind) + ": " + userFacingMessage(for: error))
                }
            }
        }
        activeKinds = started
        sink.setInputs(started)
        updateInputs()
        if started.isEmpty {
            throw errors.count == 1 ? errors[0] : LiveCaptureError.noInputStarted
        }
    }

    private func stopSources() async {
        for source in sources { await source.stop() }
        activeKinds = []
        updateInputs()
    }

    private func updateInputs() {
        for i in inputs.indices {
            inputs[i].isActive = activeKinds.contains(inputs[i].kind)
            if !inputs[i].isActive { inputs[i].level = 0 }
        }
    }

    private func startLoops() {
        stopRecognitionLoop = false
        let interval = collectInterval
        collectorTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard let self, !Task.isCancelled else { return }
                await self.collect()
            }
        }
        recognitionTask = Task { [weak self] in
            await self?.recognitionLoop()
        }
    }

    /// 取り込みを止め、届いた音声をすべて認識して確定させる（一時停止・終了の共通処理）
    private func stopCaptureAndFlush() async {
        await stopSources()
        stopRecognitionLoop = true
        await recognitionTask?.value
        recognitionTask = nil
        collectorTask?.cancel()
        collectorTask = nil
        await collect()
        if let started = activeSince {
            accumulatedActive += max(Date().timeIntervalSince(started), 0)
            activeSince = nil
        }
        await recognizeOnce(isFinal: true)
        window.discardAll()
        lastRecognizedEnd = window.endFrame
    }

    /// 入力から届いた音声と知らせを取り出して反映する
    private func collect() async {
        let drained = sink.drain()
        if !drained.samples.isEmpty {
            if let recorder {
                do {
                    try recorder.write(drained.samples)
                } catch {
                    // 書けなくなったら音声の保存だけをやめ、文字起こしは続ける
                    recorder.close()
                    recordedAudioURL = recorder.writtenFrames > 0 ? recorder.url : nil
                    self.recorder = nil
                    isRecordingAudio = false
                    addNotice(.warning, L("live.notice.recordingStopped", userFacingMessage(for: error)))
                }
            }
            let dropped = window.append(drained.samples)
            noteDropped(dropped)
        }
        updateBacklog()
        noteDropped(drained.droppedFrames)
        for i in inputs.indices {
            inputs[i].level = inputs[i].isActive ? (drained.levels[inputs[i].kind] ?? 0) : 0
        }
        for (kind, event) in drained.events {
            await handle(event, from: kind)
        }
        await checkWindowPresence()
    }

    private func updateBacklog() {
        let seconds = Double(max(window.endFrame - max(lastRecognizedEnd, window.startFrame), 0)) / sampleRate
        diagnostics.longestBacklogSeconds = max(diagnostics.longestBacklogSeconds, seconds)
        // 表示は 0.5 秒単位で更新する（細かく変えて画面を何度も描き直さない）
        let rounded = (seconds * 2).rounded(.down) / 2
        if rounded != backlogSeconds { backlogSeconds = rounded }
    }

    private func noteDropped(_ frames: Int) {
        guard frames > 0 else { return }
        droppedSeconds += Double(frames) / sampleRate
        if Date().timeIntervalSince(lastDropNotice) > 10 {
            lastDropNotice = Date()
            addNotice(.warning, L("live.notice.dropped"))
        }
    }

    private func handle(_ event: LiveSourceEvent, from kind: LiveInputKind) async {
        switch event {
        case .switchedDevice(let name):
            labels[kind] = name
            if let i = inputs.firstIndex(where: { $0.kind == kind }) { inputs[i].label = name }
            addNotice(.info, L("live.notice.micSwitched", name))
        case .stopped(let reason):
            await sourceStopped(kind, reason: reason)
        }
    }

    /// 入力が止まった（対象が閉じた・機器が外れた・macOS のメニューから止められた）
    private func sourceStopped(_ kind: LiveInputKind, reason: LiveSourceStopReason) async {
        guard activeKinds.contains(kind) else { return }
        if let source = sources.first(where: { $0.kind == kind }) { await source.stop() }
        activeKinds.remove(kind)
        sink.setInputs(activeKinds)
        updateInputs()
        let name = inputName(kind)
        switch reason {
        case .targetClosed:
            lostKinds.insert(kind)
            addNotice(.warning, kind == .window ? L("live.notice.windowClosed") : L("live.notice.targetClosed", name))
        case .stoppedBySystem:
            lostKinds.insert(kind)
            addNotice(.warning, L("live.notice.stoppedBySystem", name))
        case .deviceLost:
            addNotice(.warning, L("live.notice.micLost"))
        case .failed(let detail):
            addNotice(.error, L("live.notice.inputFailed", name, detail))
        }
        if activeKinds.isEmpty, state == .running {
            addNotice(.warning, L("live.notice.pausedNoInput"))
            // 取り込みのループの中から呼ばれるので、一時停止は別のタスクで行う
            Task { await self.pause() }
        }
    }

    /// 選んだウィンドウが閉じられていないか（1 秒ごと）
    private func checkWindowPresence() async {
        guard let windowID, activeKinds.contains(.window), Date().timeIntervalSince(lastPresenceCheck) >= 1 else { return }
        lastPresenceCheck = Date()
        let presence = WindowPresence.of(windowID)
        if let i = inputs.firstIndex(where: { $0.kind == .window }) {
            inputs[i].isVisible = presence == .visible
        }
        if presence == .gone {
            await sourceStopped(.window, reason: .targetClosed)
        }
    }

    private func inputName(_ kind: LiveInputKind) -> String {
        switch kind {
        case .window: L("live.input.window")
        case .system: L("live.input.system")
        case .microphone: L("live.input.microphone")
        }
    }

    private func addNotice(_ level: Notice.Level, _ message: String) {
        notices.append(Notice(level: level, message: message, date: Date()))
        if notices.count > Self.maxNotices { notices.removeFirst(notices.count - Self.maxNotices) }
    }

    // MARK: 認識

    private func recognitionLoop() async {
        let stepFrames = Int(policy.step * sampleRate)
        while !stopRecognitionLoop {
            if window.endFrame - lastRecognizedEnd >= stepFrames {
                await recognizeOnce(isFinal: false)
            } else {
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    /// 確定していない音声をまとめて認識し、確定する区間と暫定の区間を決める
    private func recognizeOnce(isFinal: Bool) async {
        let snapshot = window.samples
        let startFrame = window.startFrame
        lastRecognizedEnd = startFrame + snapshot.count
        updateBacklog()
        guard !snapshot.isEmpty, let recognizer else {
            if isFinal { transcript.clearProvisional() }
            return
        }
        let duration = Double(snapshot.count) / sampleRate
        let windowStart = Double(startFrame) / sampleRate
        let analysis = await Self.analyze(snapshot, detector: detector, sampleRate: sampleRate)
        guard analysis.hasSpeech else {
            // 発話のない音声は認識しない（無音から文章を作る誤認識を避ける）
            transcript.clearProvisional()
            let before = window.startFrame
            discard(upTo: startFrame, plus: policy.silentAdvance(windowDuration: duration, isFinal: isFinal))
            diagnostics.silenceSkippedSeconds += Double(window.startFrame - before) / sampleRate
            updateBacklog()
            return
        }
        diagnostics.recognitions += 1
        diagnostics.longestWindowSeconds = max(diagnostics.longestWindowSeconds, duration)
        isRecognizing = true
        defer { isRecognizing = false }
        // 手がかりの文（語彙のヒントと直前に確定した文。長さに上限あり）
        let prompt = promptBuilder.prompt(hint: vocabularyHint, confirmed: transcript.confirmed, windowStart: windowStart)
        // 前回の暫定の区間（今回の音声の先頭からの相対時刻）。2 回続けて同じ結果になった区間を確定するのに使う。
        let previous = transcript.provisional.map { $0.shifted(by: -windowStart) }
        do {
            let result = try await recognizer.recognize(snapshot, language: lockedLanguage, prompt: prompt)
            consecutiveFailures = 0
            // 自動判定は、最初に発話を認識したときの言語で固定する
            if lockedLanguage == nil, !result.segments.isEmpty, let detected = result.language {
                lockedLanguage = detected
            }
            if transcript.language == nil { transcript.language = lockedLanguage ?? result.language }
            // ヒントを丸写ししただけの区間は、話された内容ではないので捨てる
            let segments = vocabularyHint.isEmpty
                ? result.segments
                : result.segments.filter { !LivePromptBuilder.isHintEcho($0.text, hint: vocabularyHint) }
            let decision = policy.decide(segments: segments, windowDuration: duration,
                                         pauses: analysis.pauses, silences: analysis.silences, previous: previous,
                                         gaps: analysis.gaps,
                                         quietest: { analysis.quietestTime(in: $0) }, isFinal: isFinal)
            transcript.apply(decision, windowStart: windowStart)
            if !decision.confirmed.isEmpty {
                diagnostics.commits[decision.reason, default: 0] += 1
                diagnostics.lastCommitReason = decision.reason
            }
            if !decision.confirmed.isEmpty { hasUnsavedTranscript = true }
            discard(upTo: startFrame, plus: decision.advance)
        } catch {
            consecutiveFailures += 1
            addNotice(.error, L("live.notice.recognitionFailed", userFacingMessage(for: error)))
            if isFinal { transcript.clearProvisional() }
            // 同じ音声で失敗し続けないよう、何度も失敗したら認識を待っている音声を捨てる
            if consecutiveFailures >= 3 {
                discard(upTo: startFrame, plus: duration)
                consecutiveFailures = 0
            }
        }
    }

    private func discard(upTo startFrame: Int, plus seconds: TimeInterval) {
        window.discard(before: startFrame + Int((seconds * sampleRate).rounded()))
    }

    @concurrent
    private static func analyze(_ samples: [Float], detector: VoiceActivityDetector, sampleRate: Double) async -> VoiceActivityDetector.Analysis {
        detector.analyze(samples, sampleRate: sampleRate)
    }
}
