import Foundation
import Testing
import WhisperBatchCore
import WhisperBatchEngine
@testable import SonaLLM
@testable import SonaVantageAI

// 音声を読む言語モデルの文字起こしの計測（Whisper との比較用）。次の環境変数を設定したときだけ実行する。
//   WHISPER_BATCH_TEST_SPEECH_BENCH   : 計測する音声・動画のパス（改行区切り。行末に「|ja」「|en」「|auto」で言語。既定 ja）
//   WHISPER_BATCH_TEST_SPEECH_LLM_DIR : カタログのファイル名の GGUF を置いたフォルダ
//   WHISPER_BATCH_TEST_BENCH_OUT      : 結果を追記するファイル（文字起こしは <名前>.<ラベル>.txt に「開始<TAB>終了<TAB>文」で書く）
//   WHISPER_BATCH_TEST_SPEECH_BENCH_MODELS : （任意）計測するモデルの id（カンマ区切り。既定はすべて）
//   WHISPER_BATCH_TEST_SPEECH_BENCH_SPLIT  : （任意）発話の区切り方「最短の無音（秒）,最長の発話（秒）」。既定はアプリと同じ
//   WHISPER_BATCH_TEST_BENCH_LABEL         : （任意）結果の名前に付けるラベル

private let env = ProcessInfo.processInfo.environment
private let inputs: [(url: URL, language: LanguageOption)] = (env["WHISPER_BATCH_TEST_SPEECH_BENCH"] ?? "")
    .split(separator: "\n").map { line in
        let parts = line.split(separator: "|", maxSplits: 1).map(String.init)
        let language: LanguageOption = switch parts.count > 1 ? parts[1] : "ja" {
        case "en": .english
        case "auto": .auto
        default: .japanese
        }
        return (URL(fileURLWithPath: parts[0]), language)
    }
private let modelDir = env["WHISPER_BATCH_TEST_SPEECH_LLM_DIR"].map { URL(fileURLWithPath: $0) }
private let benchOut = env["WHISPER_BATCH_TEST_BENCH_OUT"].map { URL(fileURLWithPath: $0) }
private let benchModels: [SpeechModel] = {
    let all = ModelCatalog.all.filter { $0.engine.requiresAIRuntime }
    guard let ids = env["WHISPER_BATCH_TEST_SPEECH_BENCH_MODELS"] else { return all }
    let wanted = Set(ids.split(separator: ",").map(String.init))
    return all.filter { wanted.contains($0.id) }
}()

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

private func sec(_ d: Duration) -> String {
    String(format: "%.3f", Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18)
}

@Suite("音声を読む言語モデルの計測", .enabled(if: !inputs.isEmpty && modelDir != nil && benchOut != nil), .serialized)
struct SpeechLLMBenchmarks {
    init() { TestLocalization.setUp() }

    @Test(arguments: benchModels)
    func transcribeInputs(model: SpeechModel) async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sona-speechbench-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let storage = ModelStorage(directory: dir)
        for file in model.files {
            let dest = storage.fileURL(for: file, of: model)
            try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.linkItem(at: modelDir!.appendingPathComponent(file.name), to: dest)
        }
        try await storage.verifyContents(of: model)
        let clock = ContinuousClock()
        var start = clock.now
        var transcriber = try await SpeechLLMTranscriber.load(model: model, storage: storage)
        if let split = env["WHISPER_BATCH_TEST_SPEECH_BENCH_SPLIT"]?.split(separator: ",").compactMap({ Double($0) }), split.count == 2 {
            transcriber = SpeechLLMTranscriber(model: model, recognizer: transcriber.recognizer,
                                               splitter: UtteranceSplitter(minPause: split[0], maxUtterance: split[1]))
        }
        record("load\t\(model.id)\tseconds=\(sec(clock.now - start))")

        for (index, input) in inputs.enumerated() {
            do {
                start = clock.now
                let t = try await transcriber.transcribe(fileURL: input.url, options: .init(language: input.language), progress: { _ in })
                let elapsed = clock.now - start
                let label = model.id + (env["WHISPER_BATCH_TEST_BENCH_LABEL"].map { "-\($0)" } ?? "")
                let text = t.segments.map { String(format: "%.2f\t%.2f\t", $0.start, $0.end) + $0.text }.joined(separator: "\n")
                if let benchOut {
                    try? text.write(to: benchOut.deletingPathExtension().appendingPathExtension("v\(index + 1).\(label).txt"),
                                    atomically: true, encoding: .utf8)
                }
                let monotonic = zip(t.segments, t.segments.dropFirst()).allSatisfy { $1.start >= $0.end - 0.01 }
                record("speech\tv\(index + 1)\t\(label)\tseconds=\(sec(elapsed))\tsegments=\(t.segments.count)"
                    + "\tchars=\(t.segments.map(\.text.count).reduce(0, +))\tmonotonic=\(monotonic)\tlanguage=\(t.language ?? "-")")
            }
        }
    }
}
