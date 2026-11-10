import Foundation
import ScreenCaptureKit
import Synchronization
import Testing
import WhisperBatchCore
@testable import WhisperBatchEngine

// 実際の Whisper モデルや画面の音声を使うライブ文字起こしの結合テスト。環境変数を設定したときだけ実行する。
//   WHISPER_BATCH_TEST_MODEL        : ggml モデルファイルのパス
//   WHISPER_BATCH_TEST_LIVE_SPEECH  : 実時間で流し込む音声ファイル（話の切れ目を含む日本語の音声）
//   WHISPER_BATCH_TEST_LIVE_WINDOW  : 音声を再生しているウィンドウのタイトル（画面の音声の取り込みを試す）
//   WHISPER_BATCH_TEST_LIVE_EXPECT  : 結果に含まれるはずの語（カンマ区切り）
//   WHISPER_BATCH_TEST_LIVE_SECONDS : 画面の音声を取り込む秒数（既定 30）
//   WHISPER_BATCH_TEST_LIVE_CLOSING_WINDOW : 数秒後に閉じられるウィンドウのタイトル（閉じたことの検知を試す）
// 画面の音声の取り込みには、テストを実行するアプリ（ターミナルなど）に画面収録の許可が必要。

private let env = ProcessInfo.processInfo.environment
private let modelPath = env["WHISPER_BATCH_TEST_MODEL"].map { URL(fileURLWithPath: $0) }
private let liveSpeech = env["WHISPER_BATCH_TEST_LIVE_SPEECH"].map { URL(fileURLWithPath: $0) }
private let liveWindowTitle = env["WHISPER_BATCH_TEST_LIVE_WINDOW"]
private let expectedWords = (env["WHISPER_BATCH_TEST_LIVE_EXPECT"] ?? "").split(separator: ",").map(String.init)
private let closingWindowTitle = env["WHISPER_BATCH_TEST_LIVE_CLOSING_WINDOW"]
private let captureSeconds = env["WHISPER_BATCH_TEST_LIVE_SECONDS"].flatMap(Double.init) ?? 30

/// 認識にかかった時間を記録する
private final class TimedRecognizer: LiveRecognizer {
    let context: WhisperContext
    private let durations = Mutex<[Double]>([])

    init(context: WhisperContext) { self.context = context }

    var timings: [Double] { durations.withLock { $0 } }

    func recognize(_ samples: [Float], language: String?, prompt: String?) async throws -> LiveRecognition {
        let start = ContinuousClock.now
        let result = try await context.recognize(samples, language: language, prompt: prompt)
        let elapsed = ContinuousClock.now - start
        durations.withLock { $0.append(Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18) }
        return result
    }
}

@MainActor
private final class PushSource: LiveAudioSource {
    let kind: LiveInputKind = .system
    private(set) var sink: LiveAudioSink?
    func start(sink: LiveAudioSink) async throws { self.sink = sink }
    func stop() async { sink = nil }
}

private func loadContext() async throws -> WhisperContext {
    let url = try #require(modelPath)
    let model = ModelCatalog.all.first { $0.files.first?.name == url.lastPathComponent } ?? ModelCatalog.defaultModel(for: .whisper)
    return try await WhisperContext.load(model: model, fileURL: url)
}

@MainActor
private func summary(_ session: LiveTranscriptionSession, _ recognizer: TimedRecognizer) -> String {
    let t = recognizer.timings
    let mean = t.isEmpty ? 0 : t.reduce(0, +) / Double(t.count)
    return String(format: "認識 %d 回、平均 %.2f 秒、最大 %.2f 秒、取りこぼし %.1f 秒",
                  t.count, mean, t.max() ?? 0, session.droppedSeconds)
}

@Suite("ライブ文字起こし（実際の Whisper）", .enabled(if: modelPath != nil && liveSpeech != nil), .serialized)
@MainActor
struct LiveWhisperTests {
    /// 音声ファイルを実時間で流し込み、暫定と確定が順に出ることを確かめる
    @Test func transcribesSpeechFedInRealTime() async throws {
        let recognizer = TimedRecognizer(context: try await loadContext())
        let reader = try await AudioSampleReader(url: try #require(liveSpeech))
        let audio = try await reader.read(maxFrames: Int(reader.duration * LiveAudioSink.sampleRate) + 16_000)

        let source = PushSource()
        let session = LiveTranscriptionSession(loadRecognizer: { _ in recognizer })
        await session.start(.init(model: ModelCatalog.defaultModel(for: .whisper), language: .japanese,
                                  sources: [source], labels: [.system: "test"]))
        #expect(session.state == .running)

        var sawProvisional = false
        var confirmedTimes: [Double] = []
        let clock = ContinuousClock()
        let begin = clock.now
        for (i, offset) in stride(from: 0, to: audio.count, by: 1600).enumerated() {
            source.sink?.push(Array(audio[offset ..< min(offset + 1600, audio.count)]), from: .system)
            if !session.transcript.provisional.isEmpty { sawProvisional = true }
            if session.transcript.confirmed.count > confirmedTimes.count {
                confirmedTimes.append(Double(i) * 0.1)
            }
            try await clock.sleep(until: begin + .milliseconds(100 * (i + 1)))
        }
        await session.finish()

        let text = session.transcript.confirmedText
        print("確定した文:\n\(text)")
        print(summary(session, recognizer))
        print("確定した時点（秒）: \(confirmedTimes)")
        #expect(sawProvisional)
        #expect(session.transcript.confirmed.count >= 2)
        #expect(session.droppedSeconds == 0)
        for word in expectedWords { #expect(text.contains(word), "\(word)") }
        // 1 回の認識は実時間より十分速い（追いつけている）
        #expect((recognizer.timings.max() ?? 0) < 5)
    }
}

@Suite("ライブ文字起こし（画面の音声の取り込み）", .enabled(if: modelPath != nil && liveWindowTitle != nil), .serialized)
@MainActor
struct LiveCaptureTests {
    private func run(_ source: ScreenAudioSource, windowID: CGWindowID?) async throws -> (LiveTranscriptionSession, TimedRecognizer) {
        let recognizer = TimedRecognizer(context: try await loadContext())
        let session = LiveTranscriptionSession(loadRecognizer: { _ in recognizer })
        await session.start(.init(model: ModelCatalog.defaultModel(for: .whisper), language: .japanese,
                                  sources: [source], labels: [source.kind: "test"], windowID: windowID))
        #expect(session.state == .running, "\(session.startError ?? "")")
        var peak: Float = 0
        let end = ContinuousClock.now + .seconds(captureSeconds)
        while ContinuousClock.now < end {
            try await Task.sleep(for: .milliseconds(200))
            peak = max(peak, session.inputs.first?.level ?? 0)
        }
        await session.finish()
        print("[\(source.kind.rawValue)] 確定した文:\n\(session.transcript.confirmedText)")
        print("[\(source.kind.rawValue)] \(summary(session, recognizer))、入力レベルの最大 \(peak)")
        #expect(peak > 0.01)
        for word in expectedWords { #expect(session.transcript.confirmedText.contains(word), "\(word)") }
        return (session, recognizer)
    }

    private func targetWindow() async throws -> SCWindow {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        return try #require(content.windows.first { $0.title == liveWindowTitle })
    }

    @Test func capturesTheChosenWindow() async throws {
        let window = try await targetWindow()
        #expect(WindowPresence.of(window.windowID) == .visible)
        let source = ScreenAudioSource(kind: .window, filter: SCContentFilter(desktopIndependentWindow: window))
        _ = try await run(source, windowID: window.windowID)
    }

    @Test func capturesSystemAudio() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        let display = try #require(content.displays.first)
        let source = ScreenAudioSource(kind: .system, filter: SCContentFilter(display: display, excludingWindows: []))
        _ = try await run(source, windowID: nil)
    }

    /// 選んだウィンドウが閉じられたら、取り込みを止めて一時停止し、理由を知らせる
    @Test(.enabled(if: closingWindowTitle != nil))
    func closingTheWindowPausesTheSession() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        let window = try #require(content.windows.first { $0.title == closingWindowTitle })
        let recognizer = TimedRecognizer(context: try await loadContext())
        let session = LiveTranscriptionSession(loadRecognizer: { _ in recognizer })
        let source = ScreenAudioSource(kind: .window, filter: SCContentFilter(desktopIndependentWindow: window))
        await session.start(.init(model: ModelCatalog.defaultModel(for: .whisper), language: .japanese,
                                  sources: [source], labels: [.window: "test"], windowID: window.windowID))
        #expect(session.state == .running)
        let deadline = ContinuousClock.now + .seconds(20)
        while session.state != .paused, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        print("[closing] state=\(session.state) notices=\(session.notices.map(\.message))")
        #expect(session.state == .paused)
        #expect(session.notices.contains { $0.message == L("live.notice.windowClosed") })
        await session.finish()
    }

    @Test func unknownWindowIsGone() {
        #expect(WindowPresence.of(CGWindowID(UInt32.max - 1)) == .gone)
    }
}
