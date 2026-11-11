import AVFoundation
import Foundation
import Synchronization
import Testing
import WhisperBatchCore
@testable import WhisperBatchEngine

/// テスト用の入力。`push` した音声をそのままセッションに届ける。
@MainActor
private final class FakeSource: LiveAudioSource {
    let kind: LiveInputKind
    var startError: (any Error)?
    private(set) var sink: LiveAudioSink?
    private(set) var startCount = 0
    private(set) var stopCount = 0

    init(_ kind: LiveInputKind, startError: (any Error)? = nil) {
        self.kind = kind
        self.startError = startError
    }

    func start(sink: LiveAudioSink) async throws {
        startCount += 1
        if let startError { throw startError }
        self.sink = sink
    }

    func stop() async {
        stopCount += 1
        sink = nil
    }

    var isRunning: Bool { sink != nil }

    func push(_ samples: [Float]) { sink?.push(samples, from: kind) }
    func report(_ event: LiveSourceEvent) { sink?.report(event, from: kind) }
}

/// テスト用の認識器。音のある区間ごとに 1 区間を返す。文字は音の大きさから決める（u0, u1, ...）。
private final class FakeRecognizer: LiveRecognizer {
    let delay: Duration
    private let calls = Atomic<Int>(0)
    var callCount: Int { calls.load(ordering: .relaxed) }

    init(delay: Duration = .zero) { self.delay = delay }

    private let promptLog = Mutex<[String?]>([])
    /// 渡された手がかりの文（呼ばれた順）
    var prompts: [String?] { promptLog.withLock { $0 } }

    func recognize(_ samples: [Float], language: String?, prompt: String?) async throws -> LiveRecognition {
        calls.add(1, ordering: .relaxed)
        promptLog.withLock { $0.append(prompt) }
        if delay > .zero { try await Task.sleep(for: delay) }
        let rate = LiveAudioSink.sampleRate
        let frame = 160
        var segments: [TranscriptSegment] = []
        var runStart: Int?
        var peak: Float = 0
        func close(at end: Int) {
            guard let s = runStart else { return }
            let index = Int(((peak - 0.2) / 0.05).rounded())
            segments.append(TranscriptSegment(start: Double(s) / rate, end: Double(end) / rate, text: "u\(index)"))
            runStart = nil
            peak = 0
        }
        var f = 0
        while f + frame <= samples.count {
            let p = samples[f ..< f + frame].map(abs).max() ?? 0
            if p > 0.05 {
                if runStart == nil { runStart = f }
                peak = max(peak, p)
            } else {
                close(at: f)
            }
            f += frame
        }
        close(at: samples.count)
        return LiveRecognition(segments: segments, language: language ?? "ja")
    }
}

private let rate = LiveAudioSink.sampleRate

/// 0.1 秒ごとの音声。音のある部分は 220Hz の正弦波（振幅で発話の番号を表す）
private func voiced(_ seconds: Double, index: Int) -> [[Float]] {
    let amplitude = Float(0.2 + 0.05 * Double(index))
    let total = Int(seconds * rate)
    let all = (0 ..< total).map { amplitude * Float(sin(2 * Double.pi * 220 * Double($0) / rate)) }
    return stride(from: 0, to: all.count, by: 1600).map { Array(all[$0 ..< min($0 + 1600, all.count)]) }
}

private func silence(_ seconds: Double) -> [[Float]] {
    Array(repeating: [Float](repeating: 0, count: 1600), count: Int(seconds * 10))
}

@MainActor
private func feed(_ source: FakeSource, _ chunks: [[Float]], pace: Duration = .milliseconds(2)) async {
    for chunk in chunks {
        source.push(chunk)
        try? await Task.sleep(for: pace)
    }
}

@MainActor
private func waitUntil(timeout: Duration = .seconds(10), _ condition: () -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while clock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

@MainActor
private func makeSession(recognizer: FakeRecognizer = FakeRecognizer(),
                         policy: LiveCommitPolicy = LiveCommitPolicy(step: 0.3, pauseToCommit: 0.5)) -> LiveTranscriptionSession {
    LiveTranscriptionSession(policy: policy, collectInterval: .milliseconds(5), loadRecognizer: { _ in recognizer })
}

private let whisperModel = ModelCatalog.defaultModel(for: .whisper)

@MainActor
private func configuration(_ sources: [FakeSource], recordsAudio: Bool = false) -> LiveTranscriptionSession.Configuration {
    .init(model: whisperModel, language: .japanese, sources: sources,
          labels: Dictionary(uniqueKeysWithValues: sources.map { ($0.kind, "\($0.kind.rawValue)-label") }),
          recordsAudio: recordsAudio)
}

@Suite("ライブ文字起こしのセッション", .serialized)
@MainActor
struct LiveSessionTests {
    @Test func passesTheHintAsAPrompt() async {
        let source = FakeSource(.window)
        let recognizer = FakeRecognizer()
        let session = makeSession(recognizer: recognizer)
        var config = configuration([source])
        config.vocabularyHint = "  ミナト精機\n"
        await session.start(config)
        await feed(source, voiced(1, index: 0) + silence(1.5) + voiced(1, index: 1) + silence(1.5))
        #expect(await waitUntil { session.transcript.confirmed.count >= 2 })
        await session.finish()
        let prompts = recognizer.prompts.compactMap { $0 }
        #expect(prompts.count == recognizer.prompts.count)       // ヒントがあるので毎回渡す
        // 改行や前後の空白は除き、既定では確定した文を足さない
        #expect(prompts.allSatisfy { $0 == "ミナト精機" })
    }

    @Test func confirmsUtterancesAtPausesInOrder() async {
        let source = FakeSource(.window)
        let session = makeSession()
        await session.start(configuration([source]))
        #expect(session.state == .running)
        #expect(session.inputs.map(\.isActive) == [true])
        #expect(session.inputs.first?.label == "window-label")

        for i in 0 ..< 3 {
            await feed(source, voiced(1.2, index: i) + silence(1.0))
        }
        #expect(await waitUntil { session.transcript.confirmed.count == 3 })
        #expect(session.transcript.confirmed.map(\.text) == ["u0", "u1", "u2"])
        // 時刻はセッションのタイムライン（発話の位置）になっている
        let starts = session.transcript.confirmed.map(\.start)
        #expect(starts == starts.sorted())
        #expect(abs(starts[1] - 2.2) < 0.15)
        #expect(session.hasUnsavedTranscript)

        await session.finish()
        #expect(session.state == .finished)
        #expect(source.stopCount >= 1)
        #expect(!source.isRunning)
        #expect(session.transcript.transcript.language == "ja")
    }

    @Test func textStaysProvisionalUntilAPause() async {
        let source = FakeSource(.system)
        let session = makeSession()
        await session.start(configuration([source]))
        await feed(source, voiced(1.5, index: 4))
        #expect(await waitUntil { !session.transcript.provisional.isEmpty })
        #expect(session.transcript.confirmed.isEmpty)
        #expect(session.transcript.provisionalText == "u4")

        await feed(source, silence(1.0))
        #expect(await waitUntil { session.transcript.confirmed.count == 1 })
        #expect(session.transcript.provisional.isEmpty)
        await session.finish()
    }

    @Test func pauseConfirmsPendingSpeechAndResumeRestartsInputs() async {
        let source = FakeSource(.microphone)
        let session = makeSession()
        await session.start(configuration([source]))
        await feed(source, voiced(1.0, index: 1))
        try? await Task.sleep(for: .milliseconds(50))

        await session.pause()
        #expect(session.state == .paused)
        #expect(!source.isRunning)
        // 話の途中で止めても、そこまでの音声は確定する
        #expect(session.transcript.confirmed.map(\.text) == ["u1"])
        #expect(session.transcript.provisional.isEmpty)

        // 一時停止中は経過時間が進まない
        let frozen = session.elapsed()
        try? await Task.sleep(for: .milliseconds(100))
        #expect(session.elapsed() == frozen)

        await session.resume()
        #expect(session.state == .running)
        #expect(source.startCount == 2)
        await feed(source, voiced(1.0, index: 2) + silence(1.0))
        #expect(await waitUntil { session.transcript.confirmed.count == 2 })
        // 一時停止していた時間はタイムラインに含めない
        #expect(abs(session.transcript.confirmed[1].start - 1.0) < 0.2)
        await session.finish()
    }

    @Test func closedTargetPausesTheSessionAndCannotBeResumed() async {
        let source = FakeSource(.window)
        let session = makeSession()
        await session.start(configuration([source]))
        await feed(source, voiced(0.5, index: 0))
        source.report(.stopped(.targetClosed))
        #expect(await waitUntil { session.state == .paused })
        #expect(session.notices.contains { $0.message == L("live.notice.windowClosed") })
        #expect(session.notices.contains { $0.message == L("live.notice.pausedNoInput") })
        #expect(session.inputs.first?.isActive == false)

        await session.resume()
        #expect(session.state == .paused)
        #expect(session.notices.last?.level == .error)
        await session.finish()
        #expect(session.state == .finished)
    }

    @Test func losingTheMicrophoneKeepsOtherInputsRunning() async {
        let screen = FakeSource(.system)
        let mic = FakeSource(.microphone)
        let session = makeSession()
        await session.start(configuration([screen, mic]))
        #expect(session.inputs.map(\.isActive) == [true, true])
        mic.report(.stopped(.deviceLost))
        #expect(await waitUntil { session.inputs.last?.isActive == false })
        #expect(session.state == .running)
        #expect(session.notices.contains { $0.message == L("live.notice.micLost") })

        // 残った入力の音声はそのまま認識される
        await feed(screen, voiced(1.0, index: 3) + silence(1.0))
        #expect(await waitUntil { session.transcript.confirmed.map(\.text) == ["u3"] })

        // マイクは再開時にもう一度試す（機器を挿し直した場合のため）
        await session.pause()
        await session.resume()
        #expect(mic.startCount == 2)
        await session.finish()
    }

    @Test func mixesTwoInputs() async {
        let screen = FakeSource(.system)
        let mic = FakeSource(.microphone)
        let session = makeSession()
        await session.start(configuration([screen, mic]))
        // 画面側だけが話し、マイクは無音を送り続ける
        for (a, b) in zip(voiced(1.0, index: 2) + silence(1.0), silence(2.0)) {
            screen.push(a)
            mic.push(b)
            try? await Task.sleep(for: .milliseconds(2))
        }
        #expect(await waitUntil { session.transcript.confirmed.map(\.text) == ["u2"] })
        await session.finish()
    }

    @Test func silenceIsNeverSentToTheRecognizer() async {
        let recognizer = FakeRecognizer()
        let source = FakeSource(.system)
        let session = makeSession(recognizer: recognizer)
        await session.start(configuration([source]))
        await feed(source, silence(5))
        try? await Task.sleep(for: .milliseconds(100))
        #expect(recognizer.callCount == 0)
        // 発話のない音声は少しだけ残して捨てる
        #expect(session.pendingAudioSeconds <= 1.5)
        await session.finish()
        #expect(session.transcript.isEmpty)
        #expect(!session.hasUnsavedTranscript)
    }

    @Test func slowRecognitionDropsOldAudioInsteadOfGrowing() async {
        let recognizer = FakeRecognizer(delay: .milliseconds(300))
        let policy = LiveCommitPolicy(step: 0.3, pauseToCommit: 0.5, maxWindow: 3, tailMargin: 1, hardLimit: 4)
        let source = FakeSource(.system)
        let session = makeSession(recognizer: recognizer, policy: policy)
        await session.start(configuration([source]))
        var maxPending = 0.0
        // 30 秒分の切れ目のない発話を、実時間よりずっと速く流す
        for chunk in voiced(30, index: 0) {
            source.push(chunk)
            maxPending = max(maxPending, session.pendingAudioSeconds)
            try? await Task.sleep(for: .milliseconds(1))
        }
        #expect(await waitUntil { session.droppedSeconds > 0 })
        #expect(maxPending <= 4.0 + 1e-9)
        #expect(session.notices.contains { $0.message == L("live.notice.dropped") })
        await session.finish()
        #expect(session.state == .finished)
    }

    @Test func startFailureIsReportedAndNothingKeepsRunning() async {
        let source = FakeSource(.microphone, startError: LiveCaptureError.microphoneDenied)
        let session = makeSession()
        await session.start(configuration([source]))
        #expect(session.state == .idle)
        #expect(session.startError == LiveCaptureError.microphoneDenied.errorDescription)
        #expect(!source.isRunning)
    }

    @Test func oneFailingInputDoesNotBlockTheOther() async {
        let screen = FakeSource(.window, startError: LiveCaptureError.screenCaptureDenied)
        let mic = FakeSource(.microphone)
        let session = makeSession()
        await session.start(configuration([screen, mic]))
        #expect(session.state == .running)
        #expect(session.inputs.map(\.isActive) == [false, true])
        #expect(session.notices.contains { $0.message.contains(LiveCaptureError.screenCaptureDenied.errorDescription!) })
        await session.finish()
    }

    @Test func missingModelIsReported() async {
        let source = FakeSource(.system)
        let session = LiveTranscriptionSession(loadRecognizer: { model in
            throw WhisperBatchError.modelNotInstalled(modelName: model.displayName)
        })
        await session.start(configuration([source]))
        #expect(session.state == .idle)
        #expect(session.startError == WhisperBatchError.modelNotInstalled(modelName: whisperModel.displayName).errorDescription)
        #expect(source.startCount == 0)
    }

    @Test func audioIsWrittenOnlyWhenAskedAndRemovedWhenDiscarded() async throws {
        // 保存を選ばなければ一時ファイルも作らない
        let plain = FakeSource(.system)
        let s1 = makeSession()
        await s1.start(configuration([plain]))
        #expect(!s1.isRecordingAudio)
        await feed(plain, voiced(1.0, index: 0))
        await s1.finish()
        #expect(s1.recordedAudioURL == nil)

        // 保存を選んだ場合は、終了後に保存できる一時ファイルがある
        let source = FakeSource(.system)
        let s2 = makeSession()
        await s2.start(configuration([source], recordsAudio: true))
        #expect(s2.isRecordingAudio)
        await feed(source, voiced(1.0, index: 0) + silence(1.0))
        await s2.finish()
        let url = try #require(s2.recordedAudioURL)
        #expect(FileManager.default.fileExists(atPath: url.path))
        let reader = try await AudioSampleReader(url: url)
        #expect(abs(reader.duration - 2.0) < 0.15)

        // 利用者が選んだ場所へ移す
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("live-test-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: dest) }
        try s2.moveRecordedAudio(to: dest)
        #expect(FileManager.default.fileExists(atPath: dest.path))
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(s2.recordedAudioURL == nil)

        // 保存しないで新しいセッションにしたら消える
        let again = FakeSource(.system)
        let s3 = makeSession()
        await s3.start(configuration([again], recordsAudio: true))
        await feed(again, voiced(0.5, index: 0))
        await s3.finish()
        let temp = try #require(s3.recordedAudioURL)
        s3.reset()
        #expect(!FileManager.default.fileExists(atPath: temp.path))
        #expect(s3.state == .idle)
        #expect(s3.transcript.isEmpty)
    }

    @Test func shutdownStopsCaptureAndRemovesTemporaryAudio() async throws {
        let source = FakeSource(.system)
        let session = makeSession()
        await session.start(configuration([source], recordsAudio: true))
        await feed(source, voiced(0.5, index: 0))
        let temp = try #require(session.recordingURL)
        #expect(FileManager.default.fileExists(atPath: temp.path))
        // 一時ファイルはこのプロセス専用のフォルダに、所有者だけが読み書きできる形で作る
        let dir = try LiveRecordingWorkspace.workspace.directory()
        #expect(temp.deletingLastPathComponent().path == dir.path)
        let perms = try FileManager.default.attributesOfItem(atPath: dir.path)[.posixPermissions] as? Int
        #expect(perms == 0o700)
        await session.shutdown()
        #expect(!source.isRunning)
        #expect(session.recordedAudioURL == nil)
        #expect(!FileManager.default.fileExists(atPath: temp.path))
    }

    @Test func elapsedTimeCountsOnlyCapture() async {
        let source = FakeSource(.system)
        let session = makeSession()
        await session.start(configuration([source]))
        try? await Task.sleep(for: .milliseconds(200))
        let running = session.elapsed()
        #expect(running >= 0.15)
        await session.finish()
        let final = session.elapsed()
        try? await Task.sleep(for: .milliseconds(100))
        #expect(session.elapsed() == final)
    }
}

@Suite("ライブ文字起こし: 入力の変換")
struct LiveInputConversionTests {
    /// 48kHz ステレオ（左右同じ・振幅 0.5 の 440Hz）を 16kHz モノラルにしても、音量と長さが変わらない
    @Test func stereo48kBecomesMono16kWithoutGainChange() throws {
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false))
        let resampler = MonoResampler(input: format)
        var out: [Float] = []
        for block in 0 ..< 10 {
            let frames = 4800
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
            buffer.frameLength = AVAudioFrameCount(frames)
            for i in 0 ..< frames {
                let v = 0.5 * Float(sin(2 * Double.pi * 440 * Double(block * frames + i) / 48_000))
                buffer.floatChannelData![0][i] = v
                buffer.floatChannelData![1][i] = v
            }
            out += resampler.convert(buffer)
        }
        // 1 秒分 → 約 16000 サンプル（変換器が内部に保持する分、数百サンプルの差は許す）
        #expect(abs(out.count - 16_000) < 400)
        let steady = out.dropFirst(1000)
        let peak = steady.map(abs).max() ?? 0
        let rms = sqrt(steady.map { $0 * $0 }.reduce(0, +) / Float(steady.count))
        print("変換後: \(out.count) サンプル、最大 \(peak)、RMS \(rms)")
        #expect(abs(peak - 0.5) < 0.03)
        #expect(abs(Double(rms) - 0.5 / 2.0.squareRoot()) < 0.02)
    }

    /// 呼び出しを重ねても、変換で失われるサンプルが増えない（変換器の内部の遅れ分だけ）
    @Test func conversionDoesNotLoseSamplesPerCall() throws {
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false))
        for (blocks, frames) in [(10, 4800), (100, 4800), (100, 480)] {
            let resampler = MonoResampler(input: format)
            var total = 0
            for _ in 0 ..< blocks {
                let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
                buffer.frameLength = AVAudioFrameCount(frames)
                for c in 0 ..< 2 { for i in 0 ..< frames { buffer.floatChannelData![c][i] = 0.1 } }
                total += resampler.convert(buffer).count
            }
            let expected = blocks * frames / 3
            print("変換: \(blocks) 回 × \(frames) → \(total)（期待 \(expected)、差 \(expected - total)）")
            // 差は変換器が内部に保持している分だけで、呼び出し回数に比例して増えない
            #expect(expected - total >= 0 && expected - total < 400)
        }
    }

    /// 片方のチャンネルだけに音がある場合は、平均（半分の大きさ）になる
    @Test func oneSidedStereoIsAveraged() throws {
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false))
        let resampler = MonoResampler(input: format)
        let frames = 48_000
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
        buffer.frameLength = AVAudioFrameCount(frames)
        for i in 0 ..< frames {
            buffer.floatChannelData![0][i] = 0.5 * Float(sin(2 * Double.pi * 440 * Double(i) / 48_000))
            buffer.floatChannelData![1][i] = 0
        }
        let out = resampler.convert(buffer).dropFirst(1000)
        let peak = out.map(abs).max() ?? 0
        print("片側だけの音: 最大 \(peak)")
        #expect(peak > 0.2 && peak < 0.55)
    }
}

// MARK: - 認識品質・遅れの表示

extension LiveSessionTests {
    @Test func recordsLatencyAndProcessingTime() async {
        let source = FakeSource(.window)
        let session = makeSession(recognizer: FakeRecognizer(delay: .milliseconds(20)))
        await session.start(configuration([source]))
        #expect(session.qualityStatus() == .measuring)
        for i in 0 ..< 2 { await feed(source, voiced(1.0, index: i) + silence(1.0)) }
        #expect(await waitUntil { session.transcript.confirmed.count == 2 })
        let snapshot = session.quality.snapshot
        // 測った値だけを持つ（偽の認識器は確からしさを返さないので nil）
        #expect((snapshot.averageProcessing ?? 0) >= 0.02)
        #expect(snapshot.averageLatency != nil && snapshot.averageLatency! >= 0)
        #expect(snapshot.averageConfidence == nil)
        #expect(session.qualityStatus() != .measuring)
        await session.finish()
        // 新しいセッションでは記録を消す
        session.reset()
        #expect(session.quality.snapshot.averageLatency == nil)
    }

    @Test func interruptionIsReportedForNotifications() async {
        let source = FakeSource(.window)
        let session = makeSession()
        var messages: [String] = []
        session.onInputInterrupted = { messages.append($0) }
        await session.start(configuration([source]))
        source.report(.stopped(.targetClosed))
        #expect(await waitUntil { !messages.isEmpty })
        #expect(messages.first?.isEmpty == false)
        await session.finish()
    }
}
