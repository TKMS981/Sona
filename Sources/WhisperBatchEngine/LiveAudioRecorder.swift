import AVFoundation
import Foundation
import WhisperBatchCore

/// ライブ文字起こしの音声を一時ファイル（WAV、16kHz モノラル 16 ビット）に書く。
/// 利用者が開始前に「音声も保存する」を選んだときだけ使う。保存先は終了後に利用者が選ぶ。
/// 保存しなかった一時ファイルは、新しいセッション・アプリの終了時に削除し、異常終了で残ったものは次回の起動時に削除する。
final class LiveAudioRecorder {
    let url: URL
    private var file: AVAudioFile?
    private let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: LiveAudioSink.sampleRate,
                                       channels: 1, interleaved: false)!
    private(set) var writtenFrames = 0

    /// 1 時間あたりのファイルサイズ（バイト）
    static let bytesPerHour: Int64 = Int64(LiveAudioSink.sampleRate) * 2 * 3600

    init() throws {
        url = try LiveRecordingWorkspace.makeTemporaryURL()
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: LiveAudioSink.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        do {
            file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        } catch {
            throw ErrorMapper.map(error, during: .writing(fileName: url.lastPathComponent))
                ?? .exportFailed(fileName: url.lastPathComponent, detail: (error as NSError).localizedDescription)
        }
    }

    func write(_ samples: [Float]) throws {
        guard let file, !samples.isEmpty,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            buffer.floatChannelData![0].update(from: src.baseAddress!, count: samples.count)
        }
        do {
            try file.write(from: buffer)
            writtenFrames += samples.count
        } catch {
            throw ErrorMapper.map(error, during: .writing(fileName: url.lastPathComponent)) ?? .diskFull
        }
    }

    /// 書き終える（以降の write は何もしない）
    func close() {
        file?.close()
        file = nil
    }
}

/// ライブ文字起こしの一時ファイルの置き場所（プロセスごとのフォルダ。`TemporaryWorkspace` を参照）
public enum LiveRecordingWorkspace {
    static var workspace: TemporaryWorkspace { .liveRecording }

    /// 空き容量を確かめる場所（一時フォルダのあるボリューム）
    static var volumeProbe: URL { FileManager.default.temporaryDirectory }

    static func makeTemporaryURL() throws -> URL {
        try workspace.makeFile(prefix: "live-", pathExtension: "wav")
    }

    /// このプロセスが作った一時ファイルを 1 つ消す
    public static func remove(_ url: URL) {
        workspace.remove(url)
    }

    /// 起動時: 終了したプロセス（異常終了を含む）が残した一時ファイルだけを消す
    public static func removeAbandonedFiles() {
        workspace.removeAbandoned()
    }

    /// 終了時: このプロセスの一時ファイルを消す（ほかのプロセスのものは消さない）
    public static func removeOwnFiles() {
        workspace.removeOwnFiles()
    }
}
