import Foundation
import Testing
import WhisperBatchCore
@testable import WhisperBatchEngine

// 動画の文字起こしの経路の比較（計測用）。次の環境変数を設定したときだけ実行する。
//   WHISPER_BATCH_TEST_VIDEO_BENCH     : 計測する動画のパス（改行区切り。行末に「|ja」「|en」「|auto」で言語を指定できる。既定 ja）
//   WHISPER_BATCH_TEST_MODEL           : ggml モデルファイルのパス
//   WHISPER_BATCH_TEST_BENCH_OUT       : 結果を追記するファイル（文字起こしの全文は <名前>.<ラベル>.txt に書く）
//   WHISPER_BATCH_TEST_VIDEO_BENCH_REPEAT : （任意）繰り返す回数（既定 2）
//   WHISPER_BATCH_TEST_VIDEO_BENCH_CHUNK  : （任意）チャンクの長さ（秒。既定はアプリと同じ 600。境界を多く試すときに短くする）
// 経路 mp3: アプリの従来の処理（一時 MP3 に変換してから文字起こし）。経路 direct: 動画から音声を直接読み出して文字起こし。
// Whisper は Metal 上で毎回同じ結果になるとは限らないため、同じ経路どうしの差（ばらつき）と比べられるよう、交互に繰り返す。

private let env = ProcessInfo.processInfo.environment
private let videos: [(url: URL, language: LanguageOption)] = (env["WHISPER_BATCH_TEST_VIDEO_BENCH"] ?? "")
    .split(separator: "\n").map { line in
        let parts = line.split(separator: "|", maxSplits: 1).map(String.init)
        let language: LanguageOption = switch parts.count > 1 ? parts[1] : "ja" {
        case "en": .english
        case "auto": .auto
        default: .japanese
        }
        return (URL(fileURLWithPath: parts[0]), language)
    }
private let modelPath = env["WHISPER_BATCH_TEST_MODEL"].map { URL(fileURLWithPath: $0) }
private let benchOut = env["WHISPER_BATCH_TEST_BENCH_OUT"].map { URL(fileURLWithPath: $0) }
private let repeats = Int(env["WHISPER_BATCH_TEST_VIDEO_BENCH_REPEAT"] ?? "") ?? 2
private let planner: ChunkPlanner = Double(env["WHISPER_BATCH_TEST_VIDEO_BENCH_CHUNK"] ?? "")
    .map { ChunkPlanner(chunkDuration: $0, tailMargin: $0 < 60 ? 3 : 5) } ?? ChunkPlanner()

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

/// 区間ごとに「開始<TAB>終了<TAB>文」の行で書く（比較・境界の確認用）
private func dump(_ t: Transcript, label: String) {
    guard let benchOut else { return }
    let text = t.segments.map { String(format: "%.2f\t%.2f\t", $0.start, $0.end) + $0.text }.joined(separator: "\n")
    try? text.write(to: benchOut.deletingPathExtension().appendingPathExtension("\(label).txt"), atomically: true, encoding: .utf8)
}

@Suite("動画の文字起こしの経路の比較（計測）", .enabled(if: !videos.isEmpty && modelPath != nil && benchOut != nil), .serialized)
struct VideoPathBenchmarks {
    init() { TestLocalization.setUp() }

    @Test func compareMP3AndDirect() async throws {
        let url = try #require(modelPath)
        let model = ModelCatalog.all.first { $0.files.first?.name == url.lastPathComponent } ?? ModelCatalog.all[0]
        let ctx = try await WhisperContext.load(model: model, fileURL: url)
        let clock = ContinuousClock()
        // 最初の 1 回は GPU の準備などで遅くなりうるため、短い処理で温めておく
        _ = try await ctx.transcribe(samples: [Float](repeating: 0, count: 16_000), language: "ja", progress: { _ in })

        for (index, video) in videos.enumerated() {
            let info = try await MediaInspector.inspect(video.url)
            let name = "v\(index + 1)"
            for round in 1 ... repeats {
                for path in ["mp3", "direct"] {
                    let options = TranscriptionOptions(language: video.language, planner: planner)
                    let start = clock.now
                    var convert = Duration.zero
                    let transcript: Transcript
                    if path == "mp3" {
                        // アプリの従来の処理と同じ（一時フォルダに MP3 を作り、終わったら消す）
                        let mp3 = try ConversionWorkspace.makeTemporaryMP3URL()
                        defer { ConversionWorkspace.remove(mp3) }
                        try await MP3Converter.convert(source: video.url, destination: mp3, progress: { _ in })
                        convert = clock.now - start
                        transcript = try await TranscriptionEngine.transcribe(fileURL: mp3, context: ctx, options: options, progress: { _ in })
                    } else {
                        transcript = try await TranscriptionEngine.transcribe(fileURL: video.url, context: ctx, options: options, progress: { _ in })
                    }
                    let total = clock.now - start
                    let label = "\(name).\(path)\(round)"
                    dump(transcript, label: label)
                    let monotonic = zip(transcript.segments, transcript.segments.dropFirst()).allSatisfy { $1.start >= $0.start - 0.01 }
                    let chars = transcript.segments.map(\.text.count).reduce(0, +)
                    record("video\t\(name)\t\(path)\tround=\(round)\tduration=\(String(format: "%.1f", info.duration))"
                        + "\tconvertSeconds=\(sec(convert))\ttranscribeSeconds=\(sec(total - convert))\ttotalSeconds=\(sec(total))"
                        + "\tsegments=\(transcript.segments.count)\tchars=\(chars)\tmonotonic=\(monotonic)\tlanguage=\(transcript.language ?? "-")")
                }
            }
        }
    }
}
