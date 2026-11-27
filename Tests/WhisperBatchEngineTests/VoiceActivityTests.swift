import Foundation
import Testing
@testable import WhisperBatchCore
@testable import WhisperBatchEngine

// 長い無音を飛ばす（Silero VAD）機能の確認。
// 実際のモデルを使う確認は、次の環境変数を設定したときだけ実行する。
//   WHISPER_BATCH_TEST_VAD_MODEL : Silero VAD のモデル（ggml-silero-v6.2.0.bin）のパス
//   WHISPER_BATCH_TEST_MODEL     : （任意）ggml の Whisper モデル。あれば実際の音声の文字起こしも比べる
//   WHISPER_BATCH_TEST_VAD_AUDIO : （任意）発話と、5 秒を超える無音を何か所も含む音声ファイル
//                                  （発話区間の検出と、文字起こしの時刻が元の音声に戻ることの確認に使う）

/// 受け取ったオプションを記録する認識の代わり
private final class RecordingTranscriber: Transcriber, @unchecked Sendable {
    private let lock = NSLock()
    private var _usedVoiceActivity: [Bool] = []
    var usedVoiceActivity: [Bool] { lock.withLock { _usedVoiceActivity } }
    func transcribe(fileURL: URL, options: TranscriptionOptions,
                    progress: @escaping @Sendable (Double) -> Void) async throws -> Transcript {
        lock.withLock { _usedVoiceActivity.append(options.voiceActivity != nil) }
        progress(1)
        return Transcript(segments: [TranscriptSegment(start: 0, end: 1, text: fileURL.lastPathComponent)], language: "ja")
    }
}

private struct FixedRegions: SpeechRegionDetecting {
    func speechRanges(in samples: [Float]) async throws -> [Range<Int>] { [] }
}

@MainActor
private final class Calls {
    var loads = 0
    var notices: [String] = []
    var outcomes: [BatchOutcome?] = []
}

@Suite("長い無音を飛ばす（一括処理）", .serialized)
@MainActor
struct VoiceActivityServiceTests {
    init() { TestLocalization.setUp() }

    private func run(model: SpeechModel = ModelCatalog.defaultModel, skipsSilence: Bool,
                     load: @escaping @MainActor () async throws -> any SpeechRegionDetecting) async -> (RecordingTranscriber, Calls) {
        let transcriber = RecordingTranscriber()
        let calls = Calls()
        let service = TranscriptionService(
            loadTranscriber: { _, _ in transcriber },
            inspectMedia: { _ in MediaInfo(duration: 1, kind: .audio) },
            loadVoiceActivity: { calls.loads += 1; return try await load() })
        _ = service.add(["a.wav", "b.wav"].map { FileCandidate(url: URL(fileURLWithPath: "/tmp/wb-vad-test/\($0)"), bookmark: nil) })
        service.start(model: model, language: .japanese, skipsSilence: skipsSilence,
                      onFinish: { calls.outcomes.append($0) }, onNotice: { calls.notices.append($0) })
        await service.waitUntilFinished()
        return (transcriber, calls)
    }

    @Test func offByDefaultDoesNotLoadTheModel() async {
        let (t, calls) = await run(skipsSilence: false) { FixedRegions() }
        #expect(calls.loads == 0)
        #expect(t.usedVoiceActivity == [false, false])
        #expect(calls.notices.isEmpty)
        #expect(calls.outcomes == [.allSucceeded(count: 2)])
    }

    @Test func usesTheDetectorWhenEnabled() async {
        let (t, calls) = await run(skipsSilence: true) { FixedRegions() }
        #expect(calls.loads == 1)
        #expect(t.usedVoiceActivity == [true, true])
        #expect(calls.notices.isEmpty)
    }

    @Test(arguments: [
        WhisperBatchError.modelNotInstalled(modelName: "VAD"),
        WhisperBatchError.modelFileModified(modelName: "VAD"),
        WhisperBatchError.modelLoadFailed(modelName: "VAD"),
    ])
    func fallsBackWithANoticeWhenTheModelIsUnusable(error: WhisperBatchError) async {
        let (t, calls) = await run(skipsSilence: true) { throw error }
        #expect(calls.loads == 1)
        #expect(t.usedVoiceActivity == [false, false])
        #expect(calls.notices.count == 1)
        #expect(calls.notices.first?.contains(error.errorDescription ?? "-") == true)
        #expect(calls.outcomes == [.allSucceeded(count: 2)])
    }

    @Test func cancellingWhileLoadingTheModelCancelsTheBatchWithoutANotice() async {
        let (t, calls) = await run(skipsSilence: true) { throw CancellationError() }
        #expect(calls.loads == 1)
        #expect(t.usedVoiceActivity.isEmpty)
        #expect(calls.notices.isEmpty)
        #expect(calls.outcomes == [.cancelled(succeeded: 0, failed: 0, remaining: 2)])
    }

    @Test func otherEnginesNeverUseIt() async {
        let reazon = ModelCatalog.defaultModel(for: .reazonSpeech)
        let (t, calls) = await run(model: reazon, skipsSilence: true) { FixedRegions() }
        #expect(calls.loads == 0)
        #expect(t.usedVoiceActivity == [false, false])
    }
}

private let env = ProcessInfo.processInfo.environment
private let vadModel = env["WHISPER_BATCH_TEST_VAD_MODEL"].map { URL(fileURLWithPath: $0) }
private let whisperModel = env["WHISPER_BATCH_TEST_MODEL"].map { URL(fileURLWithPath: $0) }
private let vadAudio = env["WHISPER_BATCH_TEST_VAD_AUDIO"].map { URL(fileURLWithPath: $0) }

private func temporaryDirectory() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wb-vad-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// モデルがなくても確かめられること（環境変数がなくても実行する）
@Suite("Silero VAD（モデル不要）")
struct SileroVoiceActivityWithoutModelTests {
    init() { TestLocalization.setUp() }

    @Test func brokenOrMissingFilesFailToLoad() async throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let broken = dir.appendingPathComponent("broken.bin")
        try Data("not a model".utf8).write(to: broken)
        for url in [broken, dir.appendingPathComponent("missing.bin")] {
            await #expect(throws: WhisperBatchError.modelLoadFailed(modelName: "VAD")) {
                _ = try await SileroVoiceActivityDetector.load(fileURL: url, modelName: "VAD")
            }
        }
    }

    @Test func loaderReportsAModelThatIsNotInstalled() async throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = ModelCatalog.voiceActivity
        await #expect(throws: WhisperBatchError.modelNotInstalled(modelName: model.displayName)) {
            _ = try await VoiceActivityLoader.load(storage: ModelStorage(directory: dir))
        }
    }
}

@Suite("Silero VAD（実際のモデル）", .enabled(if: vadModel != nil), .serialized)
struct SileroVoiceActivityIntegrationTests {
    init() { TestLocalization.setUp() }

    @Test func loadsThePinnedModelAndFindsNoSpeechInSilence() async throws {
        let detector = try await SileroVoiceActivityDetector.load(fileURL: try #require(vadModel), modelName: "VAD")
        #expect(try await detector.speechRanges(in: [Float](repeating: 0, count: 16_000 * 5)).isEmpty)
        #expect(try await detector.speechRanges(in: []).isEmpty)
    }

    @Test func cancelledCallerGetsCancellationError() async throws {
        let detector = try await SileroVoiceActivityDetector.load(fileURL: try #require(vadModel), modelName: "VAD")
        // 中止済みのタスクから呼ぶ（onCancel が処理より先に必ず動くので、毎回同じ結果になる）
        let task = Task { () async throws -> [Range<Int>] in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await detector.speechRanges(in: [Float](repeating: 0, count: 16_000))
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        // 中止の後も、同じ検出器はそのまま使える
        #expect(try await detector.speechRanges(in: [Float](repeating: 0, count: 16_000)).isEmpty)
    }

    @Test func appliesTheStandardTuning() async throws {
        let url = try #require(vadModel)
        let standard = try await SileroVoiceActivityDetector.load(fileURL: url, modelName: "VAD")
        #expect(standard.params.threshold == VoiceActivitySettings.standard.threshold)
        #expect(Int(standard.params.min_speech_duration_ms) == VoiceActivitySettings.standard.minSpeechMilliseconds)
        // 指定しない値は whisper.cpp の既定値のまま
        let defaults = try await SileroVoiceActivityDetector.load(fileURL: url, modelName: "VAD", tuning: .init())
        #expect(standard.params.min_silence_duration_ms == defaults.params.min_silence_duration_ms)
        #expect(defaults.params.threshold != VoiceActivitySettings.standard.threshold)
        let custom = try await SileroVoiceActivityDetector.load(fileURL: url, modelName: "VAD", tuning: .init(minSilenceMilliseconds: 300))
        #expect(custom.params.min_silence_duration_ms == 300)
        #expect(custom.params.threshold == defaults.params.threshold)
    }

    @Test(.enabled(if: vadAudio != nil))
    func findsOrderedSpeechRangesInsideTheAudio() async throws {
        let detector = try await SileroVoiceActivityDetector.load(fileURL: try #require(vadModel), modelName: "VAD")
        let samples = try await readAllSamples(try #require(vadAudio))
        let ranges = try await detector.speechRanges(in: samples)
        #expect(!ranges.isEmpty)
        #expect(ranges.allSatisfy { 0 <= $0.lowerBound && $0.lowerBound < $0.upperBound && $0.upperBound <= samples.count })
        #expect(zip(ranges, ranges.dropFirst()).allSatisfy { $0.upperBound <= $1.lowerBound })
    }

    @Test func loaderChecksInstallationAndChecksum() async throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let storage = ModelStorage(directory: dir)
        let model = ModelCatalog.voiceActivity
        let file = try #require(model.files.first)
        await #expect(throws: WhisperBatchError.modelNotInstalled(modelName: model.displayName)) {
            _ = try await VoiceActivityLoader.load(storage: storage)
        }
        let destination = storage.fileURL(for: file, of: model)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        // 大きさは同じで中身が違うファイル（壊れている）
        var bytes = try Data(contentsOf: try #require(vadModel))
        bytes[bytes.count / 2] ^= 0xFF
        try bytes.write(to: destination)
        await #expect(throws: WhisperBatchError.modelFileModified(modelName: model.displayName)) {
            _ = try await VoiceActivityLoader.load(storage: storage)
        }
        try FileManager.default.removeItem(at: destination)
        try FileManager.default.copyItem(at: try #require(vadModel), to: destination)
        _ = try await VoiceActivityLoader.load(storage: storage)
    }

    @Test(.enabled(if: whisperModel != nil && vadAudio != nil))
    func transcribesWithTimesOnTheOriginalTimeline() async throws {
        let modelURL = try #require(whisperModel)
        let model = ModelCatalog.all.first { $0.files.first?.name == modelURL.lastPathComponent } ?? ModelCatalog.defaultModel
        let ctx = try await WhisperContext.load(model: model, fileURL: modelURL)
        let detector = try await SileroVoiceActivityDetector.load(fileURL: try #require(vadModel), modelName: "VAD")
        let url = try #require(vadAudio)
        let off = try await TranscriptionEngine.transcribe(fileURL: url, context: ctx, options: TranscriptionOptions(language: .japanese), progress: { _ in })
        let on = try await TranscriptionEngine.transcribe(fileURL: url, context: ctx,
                                                          options: TranscriptionOptions(language: .japanese, voiceActivity: detector), progress: { _ in })
        let duration = try await MediaInspector.inspect(url).duration
        #expect(!on.segments.isEmpty)
        #expect(on.segments.allSatisfy { $0.start >= 0 && $0.end >= $0.start && $0.end <= duration + 0.05 })
        #expect(zip(on.segments, on.segments.dropFirst()).allSatisfy { $1.start >= $0.start - 0.01 })
        // 区間の数は大きく変わらない（内蔵の VAD のように発話が 1 つの区間にまとまらない）
        #expect(on.segments.count * 2 >= off.segments.count)
        // 時刻が元の音声に戻っている。無音を短くした音声の長さより後ろまで区間が続く
        // （戻さなければ、どの区間も短くした音声の長さ以内に収まる）。この確認には長い無音を含む音声が要る
        let samples = try await readAllSamples(url)
        let settings = VoiceActivitySettings.standard
        let plan = SpeechGapPlan(speech: try await detector.speechRanges(in: samples), originalCount: samples.count,
                                 keptGap: Int(settings.keptGap * AudioSampleReader.sampleRate),
                                 minSkippedGap: Int(settings.minSkippedSilence * AudioSampleReader.sampleRate))
        let compressedSeconds = Double(plan.compressedCount) / AudioSampleReader.sampleRate
        try #require(compressedSeconds + 10 < duration, "WHISPER_BATCH_TEST_VAD_AUDIO には 5 秒を超える無音が何か所も必要")
        #expect(try #require(on.segments.map(\.end).max()) > compressedSeconds + 5)
    }
}

/// 音声ファイルの全サンプル（16kHz モノラル）
private func readAllSamples(_ url: URL) async throws -> [Float] {
    let reader = try await AudioSampleReader(url: url)
    var samples: [Float] = []
    while true {
        let chunk = try await reader.read(maxFrames: 160_000)
        if chunk.isEmpty { return samples }
        samples += chunk
    }
}
