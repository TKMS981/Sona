import Foundation
internal import SherpaOnnxC
import WhisperBatchCore
import WhisperBatchEngine

/// sherpa-onnx の話者識別（pyannote の発話区間の検出 + 3D-Speaker の話者の特徴 + クラスタリング）。
///
/// 音声全体を一度に渡す必要があるため、16kHz モノラルの音声をすべてメモリに読み込む
/// （1 時間で約 230MB）。そのため `maxDuration` を超える音声は扱わない。
/// 処理はこの Mac の中だけで行い、音声を外部へ送らない。数秒〜数分ブロックするので専用のキューで実行する。
public final class SpeakerDiarizer: @unchecked Sendable {
    /// 話者識別できる音声の長さの上限
    public static let maxDuration: TimeInterval = 2 * 3600
    /// 話者の数が分からないときのクラスタリングのしきい値（sherpa-onnx の例と同じ値）
    public static let defaultThreshold: Float = 0.5

    private let pointer: OpaquePointer
    private let queue: DispatchQueue

    private init(pointer: OpaquePointer, queue: DispatchQueue) {
        self.pointer = pointer
        self.queue = queue
    }

    deinit {
        SherpaOnnxDestroyOfflineSpeakerDiarization(pointer)
    }

    /// - Parameter speakerCount: 話者の数（分かっているとき。nil なら自動で推定する）
    public static func load(model: SpeechModel, directory: URL, speakerCount: Int?) async throws -> SpeakerDiarizer {
        guard let segmentation = model.files.first(where: { $0.name.contains("segmentation") }),
              let embedding = model.files.first(where: { !$0.name.contains("segmentation") }) else {
            throw WhisperBatchError.modelLoadFailed(modelName: model.displayName)
        }
        let segPath = directory.appendingPathComponent(segmentation.name).path
        let embPath = directory.appendingPathComponent(embedding.name).path
        let threads = Int32(WhisperContext.recommendedThreadCount)
        let queue = DispatchQueue(label: "WhisperBatch.diarization", qos: .userInitiated)
        let handle: DiarizerHandle = await withCheckedContinuation { continuation in
            queue.async {
                // 設定の文字列は作成時に複製されるので、作成後に解放してよい
                let strings = [segPath, embPath, "cpu"].map { strdup($0) }
                defer { strings.forEach { free($0) } }
                var config = SherpaOnnxOfflineSpeakerDiarizationConfig()
                config.segmentation.pyannote.model = UnsafePointer(strings[0])
                config.segmentation.num_threads = threads
                config.segmentation.provider = UnsafePointer(strings[2])
                config.embedding.model = UnsafePointer(strings[1])
                config.embedding.num_threads = threads
                config.embedding.provider = UnsafePointer(strings[2])
                config.clustering.num_clusters = Int32(speakerCount ?? -1)
                config.clustering.threshold = defaultThreshold
                config.min_duration_on = 0.3
                config.min_duration_off = 0.5
                continuation.resume(returning: DiarizerHandle(pointer: SherpaOnnxCreateOfflineSpeakerDiarization(&config)))
            }
        }
        guard let pointer = handle.pointer else { throw WhisperBatchError.modelLoadFailed(modelName: model.displayName) }
        return SpeakerDiarizer(pointer: pointer, queue: queue)
    }

    /// 16kHz モノラルの音声を話者ごとの区間に分ける（時刻は先頭からの秒）
    public func diarize(_ samples: [Float], progress: @escaping @Sendable (Double) -> Void) async throws -> [SpeakerTurn] {
        guard !samples.isEmpty else { return [] }
        let box = ProgressBox(progress)
        let turns: [SpeakerTurn]? = await withCheckedContinuation { continuation in
            queue.async { [self] in
                let arg = Unmanaged.passRetained(box).toOpaque()
                defer { Unmanaged<ProgressBox>.fromOpaque(arg).release() }
                let result = samples.withUnsafeBufferPointer { buf in
                    SherpaOnnxOfflineSpeakerDiarizationProcessWithCallback(
                        pointer, buf.baseAddress, Int32(buf.count),
                        { done, total, arg in
                            if let arg, total > 0 {
                                Unmanaged<ProgressBox>.fromOpaque(arg).takeUnretainedValue()
                                    .report(Double(done) / Double(total))
                            }
                            return 0
                        }, arg)
                }
                guard let result else {
                    continuation.resume(returning: nil)
                    return
                }
                defer { SherpaOnnxOfflineSpeakerDiarizationDestroyResult(result) }
                let count = Int(SherpaOnnxOfflineSpeakerDiarizationResultGetNumSegments(result))
                guard count > 0, let segments = SherpaOnnxOfflineSpeakerDiarizationResultSortByStartTime(result) else {
                    continuation.resume(returning: [])
                    return
                }
                defer { SherpaOnnxOfflineSpeakerDiarizationDestroySegment(segments) }
                let turns = (0 ..< count).map { i in
                    SpeakerTurn(start: TimeInterval(segments[i].start), end: TimeInterval(segments[i].end),
                                speaker: Int(segments[i].speaker))
                }
                continuation.resume(returning: turns)
            }
        }
        try Task.checkCancellation()
        guard let turns else { throw WhisperBatchError.diarizationFailed }
        return turns
    }

    /// 音声ファイル全体を 16kHz モノラルで読み込む（長すぎる音声はエラー）
    public static func readSamples(from url: URL) async throws -> [Float] {
        let reader = try await AudioSampleReader(url: url)
        if reader.duration > maxDuration {
            throw WhisperBatchError.audioTooLongForDiarization(maxMinutes: Int(maxDuration / 60))
        }
        var samples: [Float] = []
        samples.reserveCapacity(Int(reader.duration * AudioSampleReader.sampleRate) + 16_000)
        let limit = Int(maxDuration * AudioSampleReader.sampleRate)
        while true {
            try Task.checkCancellation()
            let chunk = try await reader.read(maxFrames: 160_000)
            samples += chunk
            if samples.count > limit {
                throw WhisperBatchError.audioTooLongForDiarization(maxMinutes: Int(maxDuration / 60))
            }
            if chunk.count < 160_000 { break }
        }
        return samples
    }
}

/// 進捗を伝えるための箱（C の関数ポインタはキャプチャできないため、引数で渡す）
private final class ProgressBox: @unchecked Sendable {
    let report: @Sendable (Double) -> Void
    init(_ report: @escaping @Sendable (Double) -> Void) { self.report = report }
}

/// 作成した識別器をキューから受け取るための箱（以降はこのクラスのキューの上でだけ使う）
private struct DiarizerHandle: @unchecked Sendable {
    let pointer: OpaquePointer?
}

/// キューの項目（音声・動画ファイル）の話者識別。動画は音声を一時 MP3 に変換してから読み込む。
enum SpeakerIdentification {
    /// - Returns: 話者ごとの区間（時刻は音声の先頭からの秒）
    @MainActor
    static func run(item: QueueItem, storage: ModelStorage, speakerCount: Int?,
                    onRefresh: @escaping @MainActor (SecurityScopedAccess.RefreshedBookmark) -> Void,
                    progress: @escaping @Sendable (SpeakerIdentificationPhase, Double) -> Void) async throws -> [SpeakerTurn] {
        let model = ModelCatalog.speakerDiarization
        guard storage.isInstalled(model) else { throw WhisperBatchError.modelNotInstalled(modelName: model.displayName) }
        try await storage.verifyContents(of: model)
        let diarizer = try await SpeakerDiarizer.load(model: model, directory: storage.directory(for: model),
                                                      speakerCount: speakerCount)
        let samples: [Float] = try await SecurityScopedAccess.withAccess(url: item.url, bookmark: item.bookmark,
                                                                          onRefresh: onRefresh) { url in
            if item.isVideo {
                progress(.converting, 0)
                let mp3 = try ConversionWorkspace.makeTemporaryMP3URL()
                defer { ConversionWorkspace.remove(mp3) }
                try await MP3Converter.convert(source: url, destination: mp3) { progress(.converting, $0) }
                progress(.reading, 0)
                return try await SpeakerDiarizer.readSamples(from: mp3)
            }
            progress(.reading, 0)
            return try await SpeakerDiarizer.readSamples(from: url)
        }
        progress(.analyzing, 0)
        return try await diarizer.diarize(samples) { progress(.analyzing, $0) }
    }
}
