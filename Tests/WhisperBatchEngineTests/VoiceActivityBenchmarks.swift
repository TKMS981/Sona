import Foundation
import Testing
@testable import WhisperBatchCore
@testable import WhisperBatchEngine

// 長い無音を飛ばす（Silero VAD）ときと飛ばさないときの比較（計測用）。次の環境変数を設定したときだけ実行する。
//   WHISPER_BATCH_TEST_VAD_BENCH    : 計測する音声・動画のパス（改行区切り。行末に「|ja」「|en」「|auto」で言語。既定 ja）
//   WHISPER_BATCH_TEST_MODEL        : ggml の Whisper モデルファイルのパス
//   WHISPER_BATCH_TEST_VAD_MODEL    : Silero VAD のモデル（ggml-silero-v6.2.0.bin）のパス
//   WHISPER_BATCH_TEST_BENCH_OUT    : 結果を追記するファイル（1 回ごとに JSON 1 行。区間の時刻と文を含む）
//   WHISPER_BATCH_TEST_VAD_REPEAT   : （任意）繰り返す回数（既定 3）
//   WHISPER_BATCH_TEST_VAD_VARIANTS : （任意）比べる条件（カンマ区切り。既定 off,on）
//       off: 飛ばさない / on: アプリの設定（しきい値 0.1・最短の発話 100ms・5 秒を超える無音を 1.0 秒に）
//       s10: whisper.cpp の既定（しきい値 0.5・最短の発話 250ms）・1 秒を超える無音を短くする / on-ms64: 最短の発話 64ms / on-th035: しきい値 0.35
//       e15, e20: アプリの設定で残す間を 1.5 秒・2.0 秒 / g1, g3, g10: 短くする無音の最短を 1・3・10 秒
//       t15, t10: しきい値 0.15・0.10（t15g1, t10g1 は短くする無音の最短 1 秒）
// Whisper は Metal 上で毎回同じ結果になるとは限らないため、同じ条件どうしの差（ばらつき）と比べられるよう、
// 条件を交互に（回ごとに順番を変えて）繰り返す。認識の条件（モデル・探索方式・チャンク）はアプリと同じ。
private let env = ProcessInfo.processInfo.environment
private let inputs: [(url: URL, language: LanguageOption)] = (env["WHISPER_BATCH_TEST_VAD_BENCH"] ?? "")
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
private let vadPath = env["WHISPER_BATCH_TEST_VAD_MODEL"].map { URL(fileURLWithPath: $0) }
private let benchOut = env["WHISPER_BATCH_TEST_BENCH_OUT"].map { URL(fileURLWithPath: $0) }
private let repeats = Int(env["WHISPER_BATCH_TEST_VAD_REPEAT"] ?? "") ?? 3
private let variants = (env["WHISPER_BATCH_TEST_VAD_VARIANTS"] ?? "off,on").split(separator: ",").map(String.init)

private func record(_ object: [String: Any]) {
    guard let benchOut, let json = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return }
    let data = json + Data("\n".utf8)
    if let handle = try? FileHandle(forWritingTo: benchOut) {
        handle.seekToEndOfFile()
        handle.write(data)
        try? handle.close()
    } else {
        try? data.write(to: benchOut)
    }
}

/// このプロセスが使っているメモリ（phys_footprint。Metal に置いたモデルも含む）
private func footprintMB() -> Double {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
    }
    return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : 0
}

/// 処理中のメモリの最大値を 50ms ごとに測る
private final class PeakMemory: @unchecked Sendable {
    private let lock = NSLock()
    private var peak = 0.0
    private var running = true
    func start() {
        Thread.detachNewThread { [self] in
            while lock.withLock({ running }) {
                let now = footprintMB()
                lock.withLock { peak = max(peak, now) }
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
    }
    func stop() -> Double { lock.withLock { running = false; return peak } }
}

private func sec(_ d: Duration) -> Double {
    Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
}

@Suite("長い無音を飛ばすときの比較（計測）", .enabled(if: !inputs.isEmpty && modelPath != nil && vadPath != nil && benchOut != nil), .serialized)
struct VoiceActivityBenchmarks {
    init() { TestLocalization.setUp() }

    @Test func compareWithAndWithoutVAD() async throws {
        let url = try #require(modelPath)
        let vadURL = try #require(vadPath)
        let model = ModelCatalog.all.first { $0.files.first?.name == url.lastPathComponent } ?? ModelCatalog.all[0]
        let ctx = try await WhisperContext.load(model: model, fileURL: url)
        let clock = ContinuousClock()
        _ = try await ctx.transcribe(samples: [Float](repeating: 0, count: 16_000), language: "ja", progress: { _ in })

        var detectors: [String: SileroVoiceActivityDetector] = [:]
        for v in variants where v != "off" {
            let tuning: SileroVoiceActivityDetector.Tuning = switch v {
            case "s10": .init()
            case "on-ms64": .init(minSpeechMilliseconds: 64)
            case "on-th035": .init(threshold: 0.35, minSpeechMilliseconds: 100)
            case "t15", "t15g1": .init(threshold: 0.15, minSpeechMilliseconds: 100)
            case "t10", "t10g1": .init(threshold: 0.10, minSpeechMilliseconds: 100)
            default: .init(threshold: VoiceActivitySettings.standard.threshold,
                           minSpeechMilliseconds: VoiceActivitySettings.standard.minSpeechMilliseconds)
            }
            detectors[v] = try await SileroVoiceActivityDetector.load(fileURL: vadURL, modelName: "silero", tuning: tuning)
        }

        for (index, input) in inputs.enumerated() {
            for round in 1 ... repeats {
                // 回ごとに条件の順番をずらす（温度や負荷の偏りを避ける）
                let order = (0 ..< variants.count).map { variants[($0 + round - 1) % variants.count] }
                for v in order {
                    var options = TranscriptionOptions(language: input.language, voiceActivity: detectors[v])
                    switch v {
                    case "g1", "s10", "on-ms64", "on-th035", "t15g1", "t10g1": options.voiceActivitySettings.minSkippedSilence = 1.0
                    case "g3": options.voiceActivitySettings.minSkippedSilence = 3.0
                    case "g10": options.voiceActivitySettings.minSkippedSilence = 10.0
                    case "e15": options.voiceActivitySettings.keptGap = 1.5
                    case "e20": options.voiceActivitySettings.keptGap = 2.0
                    default: break
                    }
                    let baseline = footprintMB()
                    let peak = PeakMemory()
                    peak.start()
                    let start = clock.now
                    let transcript = try await TranscriptionEngine.transcribe(fileURL: input.url, context: ctx, options: options, progress: { _ in })
                    let seconds = sec(clock.now - start)
                    let peakMB = peak.stop()
                    record([
                        "file": input.url.lastPathComponent, "index": index, "variant": v, "round": round,
                        "seconds": seconds, "baselineMB": baseline, "peakMB": peakMB,
                        "language": transcript.language ?? "-",
                        "segments": transcript.segments.map { ["start": $0.start, "end": $0.end, "text": $0.text] },
                    ])
                    print("vad-bench \(input.url.lastPathComponent) \(v) round=\(round) \(String(format: "%.2f", seconds))s segments=\(transcript.segments.count)")
                }
            }
        }
    }
}
