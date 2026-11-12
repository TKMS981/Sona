import Foundation
import Observation
import Testing
import WhisperBatchCore
@testable import WhisperBatchEngine

private final class OneSegmentTranscriber: Transcriber {
    func transcribe(fileURL: URL, options: TranscriptionOptions,
                    progress: @escaping @Sendable (Double) -> Void) async throws -> Transcript {
        for i in 0 ... 1_000 { progress(Double(i) / 1_000) }
        return Transcript(segments: [TranscriptSegment(start: 0, end: 1, text: "あ"), TranscriptSegment(start: 1, end: 2, text: "い")],
                          language: "ja")
    }
}

/// 監視している値が変わった回数を数える（変わるたびに監視し直す）
@MainActor
private final class Changes {
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

@MainActor
private final class ChangeLog {
    var changes: [Set<UUID>] = []
}

@Suite("AI の結果の無効化の通知・進捗の間引き", .serialized)
@MainActor
struct TranscriptInputChangeTests {
    init() { TestLocalization.setUp() }

    private func completedService() async -> (TranscriptionService, UUID, ChangeLog) {
        let service = TranscriptionService(loadTranscriber: { _, _ in OneSegmentTranscriber() },
                                           inspectMedia: { _ in MediaInfo(duration: 2, kind: .audio) })
        let log = ChangeLog()
        service.onTranscriptInputChanged = { log.changes.append($0) }
        let id = service.add([FileCandidate(url: URL(fileURLWithPath: "/tmp/sona-test/a.wav"), bookmark: nil)]).added[0]
        service.start(model: ModelCatalog.defaultModel, language: .japanese)
        await service.waitUntilFinished()
        return (service, id, log)
    }

    @Test func editsSpeakersRetryAndRemovalNotify() async throws {
        let (service, id, log) = await completedService()
        #expect(service.queue.item(id)?.status == .completed)
        #expect(log.changes == [[id]]) // 結果ができた
        let original = try #require(service.queue.item(id)?.transcript)

        // 要約などの結果を入れただけでは知らせない（AI に渡す文は変わらない）
        service.updateAnnotations(id) { $0.analysis.summary = ["要点"] }
        #expect(log.changes.count == 1)

        // 編集・話者名・話者の変更は知らせる
        service.updateAnnotations(id) { $0.edits.replace(0, with: "あー", in: original) }
        service.updateAnnotations(id) { $0.speakerNames[0] = "田中" }
        service.setSpeaker(id, segment: 1, speaker: 0)
        service.setSpeakers(id, [0, 1])
        #expect(log.changes.count == 5)

        // やり直し・削除も知らせる
        #expect(service.retry([id]) == 1)
        #expect(log.changes.last == [id])
        #expect(service.remove([id]) == 1)
        #expect(log.changes.last == [id])
        #expect(log.changes.count == 7)
        // 何も消えなければ知らせない
        #expect(service.removeAllCompleted() == 0)
        #expect(log.changes.count == 7)
    }

    /// 進捗の表示の更新は間引くが、完了の表示と結果は変わらない
    @Test func progressUpdatesAreThrottled() async throws {
        let service = TranscriptionService(loadTranscriber: { _, _ in OneSegmentTranscriber() },
                                           inspectMedia: { _ in MediaInfo(duration: 2, kind: .audio) })
        let id = service.add([FileCandidate(url: URL(fileURLWithPath: "/tmp/sona-test/b.wav"), bookmark: nil)]).added[0]
        let updates = Changes { _ = service.queue }
        service.start(model: ModelCatalog.defaultModel, language: .japanese)
        await service.waitUntilFinished()
        for _ in 0 ..< 20 { await Task.yield() }
        #expect(service.queue.item(id)?.status == .completed)
        #expect(service.queue.item(id)?.transcript?.segments.map(\.text) == ["あ", "い"])
        // 1,001 回の進捗のうち、画面の更新につながるのは 0.2% ごと（最大 500 回程度）だけ
        #expect(updates.count < 600)
    }
}

@MainActor
private final class SilentSource: LiveAudioSource {
    let kind: LiveInputKind = .microphone
    private var sink: LiveAudioSink?
    func start(sink: LiveAudioSink) async throws { self.sink = sink }
    func stop() async { sink = nil }
    func push(_ samples: [Float]) { sink?.push(samples, from: kind) }
}

private final class NoSpeechRecognizer: LiveRecognizer {
    func recognize(_ samples: [Float], language: String?, prompt: String?) async throws -> LiveRecognition {
        LiveRecognition(segments: [], language: language)
    }
}

@Suite("ライブ文字起こしの画面の更新", .serialized)
@MainActor
struct LiveIdleUpdateTests {
    init() { TestLocalization.setUp() }

    /// 無音が続く間は、入力の音量と結果を書き換えない（音声は欠けずに受け取る）
    @Test func silenceDoesNotRewriteObservedState() async throws {
        let source = SilentSource()
        let session = LiveTranscriptionSession(collectInterval: .milliseconds(20), loadRecognizer: { _ in NoSpeechRecognizer() })
        await session.start(.init(model: ModelCatalog.defaultModel, language: .japanese, sources: [source],
                                  labels: [.microphone: "mic"]))
        #expect(session.state == .running)
        // 入力が始まった直後の書き換えが落ち着くのを待つ
        try await Task.sleep(for: .milliseconds(100))
        let inputChanges = Changes { _ = session.inputs }
        let transcriptChanges = Changes { _ = session.transcript }
        let chunk = [Float](repeating: 0, count: 1_600)
        for _ in 0 ..< 30 {
            source.push(chunk)
            try await Task.sleep(for: .milliseconds(20))
        }
        try await Task.sleep(for: .milliseconds(200))
        #expect(inputChanges.count == 0)
        #expect(transcriptChanges.count == 0)
        #expect(session.droppedSeconds == 0)
        await session.finish()
        #expect(session.state == .finished)
    }
}
