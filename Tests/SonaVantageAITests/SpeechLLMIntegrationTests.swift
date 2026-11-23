import Foundation
import Synchronization
import Testing
import WhisperBatchCore
import WhisperBatchEngine
@testable import SonaLLM
@testable import SonaVantageAI

// 音声を直接読む言語モデル（Qwen3-ASR・Granite Speech）の文字起こし（実モデル）。次の環境変数を設定したときだけ実行する。
//   WHISPER_BATCH_TEST_SPEECH_LLM_DIR : カタログのファイル名の GGUF（本体と音声エンコーダー）を置いたフォルダ
//   WHISPER_BATCH_TEST_AUDIO_DIR      : テスト音声のフォルダ（scripts/make-test-audio.sh で作成）

private let env = ProcessInfo.processInfo.environment
private let modelDir = env["WHISPER_BATCH_TEST_SPEECH_LLM_DIR"].map { URL(fileURLWithPath: $0) }
private let audioDir = env["WHISPER_BATCH_TEST_AUDIO_DIR"].map { URL(fileURLWithPath: $0) }
private func audio(_ name: String) -> URL { audioDir!.appendingPathComponent(name) }

private let speechModels = ModelCatalog.all.filter { $0.engine.requiresAIRuntime }

/// モデルを取得済みとして一時フォルダに置き（ハードリンク）、アプリと同じ経路（照合 → AIRuntime）で読み込んで body を実行する
private func withTranscriber<T>(_ model: SpeechModel, _ body: (any Transcriber) async throws -> T) async throws -> T {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sona-speechllm-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let storage = ModelStorage(directory: dir)
    for file in model.files {
        let dest = storage.fileURL(for: file, of: model)
        try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.linkItem(at: modelDir!.appendingPathComponent(file.name), to: dest)
    }
    let transcriber = try await TranscriberLoader.load(model, storage: storage, language: .japanese, ai: VantageAIRuntime())
    return try await body(transcriber)
}

private final class Recorder: Sendable {
    private let values = Mutex<[Double]>([])
    func add(_ v: Double) { values.withLock { $0.append(v) } }
    var all: [Double] { values.withLock { $0 } }
}

@Suite("音声を読む言語モデルの文字起こし（実モデル）", .enabled(if: modelDir != nil && audioDir != nil), .serialized)
struct SpeechLLMIntegrationTests {
    init() { TestLocalization.setUp() }

    @Test(arguments: speechModels)
    func transcribesJapaneseAndEnglish(model: SpeechModel) async throws {
        try await withTranscriber(model) { transcriber in
            let progress = Recorder()
            let ja = try await transcriber.transcribe(fileURL: audio("ja1.wav"), options: .init(language: .japanese),
                                                      progress: { progress.add($0) })
            let jaText = TranscriptFormatter.plainText(ja)
            print("\(model.id) ja:", jaText, ja.segments.map { "\($0.start)-\($0.end)" })
            #expect(jaText.contains("晴天") || jaText.contains("テスト"))
            #expect(ja.language == "ja")
            #expect(progress.all.last == 1)
            #expect(zip(progress.all, progress.all.dropFirst()).allSatisfy { $0 <= $1 })

            // 言語を指定しない（自動判定）
            let en = try await transcriber.transcribe(fileURL: audio("en1.aiff"), options: .init(language: .auto), progress: { _ in })
            let enText = TranscriptFormatter.plainText(en).lowercased()
            print("\(model.id) en(auto):", enText, en.language ?? "-")
            #expect(enText.contains("english"))
            #expect(en.language == "en", "Granite は書き起こした文から言語を推定する")

            // 動画も音声トラックを直接読む
            let video = try await transcriber.transcribe(fileURL: audio("ja1.mp4"), options: .init(language: .japanese), progress: { _ in })
            #expect(TranscriptFormatter.plainText(video).contains("晴天") || TranscriptFormatter.plainText(video).contains("テスト"))
        }
    }

    /// 長い音声を発話ごとに区切っても、各文が欠けず二重にもならず、時刻が進むこと
    @Test(arguments: speechModels)
    func longAudioHasNoGapsOrDuplicates(model: SpeechModel) async throws {
        try await withTranscriber(model) { transcriber in
            let t = try await transcriber.transcribe(fileURL: audio("long.aiff"), options: .init(language: .japanese), progress: { _ in })
            for (a, b) in zip(t.segments, t.segments.dropFirst()) {
                #expect(b.start >= a.end - 0.01)
            }
            let text = TranscriptFormatter.plainText(t)
            let numbers = text.matches(of: /([0-9]+|[一二三四五六七八九十]+)\s*番目/).compactMap { kanjiOrArabic(String($0.1)) }
            let counts = Dictionary(numbers.map { ($0, 1) }, uniquingKeysWith: +)
            let duplicated = counts.filter { $0.value > 1 }.keys.sorted()
            let missing = (1 ... 40).filter { counts[$0] == nil }
            print("\(model.id) long: segments=\(t.segments.count) duplicated=\(duplicated) missing=\(missing)")
            #expect(duplicated.isEmpty)
            #expect(missing.count <= 2)
        }
    }

    /// 中止するとすぐに止まる
    @Test(arguments: speechModels)
    func cancellationStopsQuickly(model: SpeechModel) async throws {
        try await withTranscriber(model) { transcriber in
            let task = Task {
                try await transcriber.transcribe(fileURL: audio("long.aiff"), options: .init(language: .japanese), progress: { _ in })
            }
            try await Task.sleep(for: .seconds(2))
            let clock = ContinuousClock()
            let start = clock.now
            task.cancel()
            await #expect(throws: CancellationError.self) { try await task.value }
            #expect(clock.now - start < .seconds(3))
        }
    }
}

/// 算用数字か漢数字（九十九まで）を数にする
private func kanjiOrArabic(_ text: String) -> Int? {
    if let n = Int(text) { return n }
    let digits: [Character: Int] = ["一": 1, "二": 2, "三": 3, "四": 4, "五": 5, "六": 6, "七": 7, "八": 8, "九": 9]
    let parts = text.split(separator: "十", omittingEmptySubsequences: false)
    switch parts.count {
    case 1: return text.count == 1 ? digits[text.first!] : nil
    case 2:
        let tens = parts[0].isEmpty ? 1 : (parts[0].count == 1 ? digits[parts[0].first!] : nil)
        let ones = parts[1].isEmpty ? 0 : (parts[1].count == 1 ? digits[parts[1].first!] : nil)
        guard let tens, let ones else { return nil }
        return tens * 10 + ones
    default: return nil
    }
}
