import Foundation
import Observation
import Synchronization
import Testing
import WhisperBatchCore
@testable import WhisperBatchEngine

// 負荷の計測（最適化の前後比較用）。WHISPER_BATCH_TEST_BENCH_OUT（結果を追記するファイル）を設定したときだけ実行する。
// 動画の変換を含む計測は WHISPER_BATCH_TEST_AUDIO_DIR（long.mp4）も必要。
// 画面の描き直しのもとになる「監視している値の変更の通知」の回数と、かかった時間を記録する。

private let env = ProcessInfo.processInfo.environment
private let benchOut = env["WHISPER_BATCH_TEST_BENCH_OUT"].map { URL(fileURLWithPath: $0) }
private let audioDir = env["WHISPER_BATCH_TEST_AUDIO_DIR"].map { URL(fileURLWithPath: $0) }

private func record(_ line: String) {
    guard let benchOut else { return }
    let data = Data((line + "\n").utf8)
    if let handle = try? FileHandle(forWritingTo: benchOut) {
        handle.seekToEndOfFile()
        handle.write(data)
        try? handle.close()
    } else {
        try? data.write(to: benchOut)
    }
    print(line)
}

/// 監視している値が変わった回数を数える（変わるたびに監視し直す）
@MainActor
private final class ChangeCounter {
    private(set) var count = 0
    private let read: @MainActor () -> Void

    init(_ read: @escaping @MainActor () -> Void) {
        self.read = read
        track()
    }

    private func track() {
        withObservationTracking { read() } onChange: { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.count += 1
                self.track()
            }
        }
    }
}

/// Whisper のように、30 秒ごとのチャンクの中で 0〜100% の進捗を返す認識器（認識はしない）
private final class ProgressOnlyTranscriber: Transcriber {
    let chunks: Int
    private let calls = Atomic<Int>(0)
    var progressCalls: Int { calls.load(ordering: .relaxed) }
    init(chunks: Int) { self.chunks = chunks }

    func transcribe(fileURL: URL, options: TranscriptionOptions,
                    progress: @escaping @Sendable (Double) -> Void) async throws -> Transcript {
        progress(0)
        for chunk in 0 ..< chunks {
            for p in 0 ... 100 {
                calls.add(1, ordering: .relaxed)
                progress(min((Double(chunk) + Double(p) / 100) / Double(chunks), 0.999))
            }
            await Task.yield()
        }
        progress(1)
        return Transcript(segments: [.init(start: 0, end: 1, text: "x")], language: "ja")
    }
}

@Suite("負荷の計測（一括処理・ライブ）", .enabled(if: benchOut != nil), .serialized)
@MainActor
struct ResourceBenchmarks {
    init() { TestLocalization.setUp() }

    /// 動画 1 件（変換 + 認識）の一括処理で、キューの変更の通知が何回起きるか
    @Test(.enabled(if: audioDir != nil))
    func batchQueueUpdates() async throws {
        let video = audioDir!.appendingPathComponent("long.mp4")
        let transcriber = ProgressOnlyTranscriber(chunks: 120)
        let service = TranscriptionService(loadTranscriber: { _, _ in transcriber })
        service.add([FileCandidate(url: video, bookmark: nil)])
        // 追加直後の確認が終わるのを待つ
        while service.queue.items.first?.duration == nil { try await Task.sleep(for: .milliseconds(20)) }
        let counter = ChangeCounter { _ = service.queue }
        let clock = ContinuousClock()
        let start = clock.now
        let model = ModelCatalog.all[0]
        service.start(model: model, language: .japanese)
        await service.waitUntilFinished()
        let elapsed = clock.now - start
        // 最後の進捗の更新（メインアクターへ送ったもの）が反映されるのを待つ
        for _ in 0 ..< 50 { await Task.yield() }
        #expect(service.queue.items.first?.status == .completed)
        record("batch\tqueueChanges=\(counter.count)\ttranscriberProgressCalls=\(transcriber.progressCalls)\twallSeconds=\(String(format: "%.3f", Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18))")
    }

    /// ライブ文字起こしで、無音が続くときに画面の値（入力の状態・結果）の変更の通知が何回起きるか
    @Test func liveIdleUpdates() async throws {
        let source = BenchSource()
        let session = LiveTranscriptionSession(loadRecognizer: { _ in EmptyRecognizer() })
        await session.start(.init(model: ModelCatalog.all[0], language: .japanese, sources: [source],
                                  labels: [.system: "bench"]))
        #expect(session.state == .running)
        let inputs = ChangeCounter { _ = session.inputs }
        let transcript = ChangeCounter { _ = session.transcript }
        let backlog = ChangeCounter { _ = session.backlogSeconds }
        // 5 秒間、100 ミリ秒ごとに無音を届ける（実時間）
        let silence = [Float](repeating: 0, count: Int(LiveAudioSink.sampleRate / 10))
        for _ in 0 ..< 50 {
            source.push(silence)
            try await Task.sleep(for: .milliseconds(100))
        }
        await session.finish()
        record("liveIdle\tinputsChanges=\(inputs.count)\ttranscriptChanges=\(transcript.count)\tbacklogChanges=\(backlog.count)\tdropped=\(session.droppedSeconds)")
    }
}

@MainActor
private final class BenchSource: LiveAudioSource {
    let kind: LiveInputKind = .system
    private var sink: LiveAudioSink?
    func start(sink: LiveAudioSink) async throws { self.sink = sink }
    func stop() async { sink = nil }
    var isRunning: Bool { sink != nil }
    func push(_ samples: [Float]) { sink?.push(samples, from: kind) }
}

private final class EmptyRecognizer: LiveRecognizer {
    func recognize(_ samples: [Float], language: String?, prompt: String?) async throws -> LiveRecognition {
        LiveRecognition(segments: [], language: language)
    }
}
