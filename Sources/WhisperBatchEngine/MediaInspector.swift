import AVFoundation
import Foundation
import WhisperBatchCore

public struct MediaInfo: Equatable, Sendable {
    public var duration: TimeInterval
    public var kind: MediaKind
}

/// ファイルを開いて、長さと種類（音声か動画か）を調べる。
public enum MediaInspector {
    /// - Throws: 読み込めない形式、音声トラックのない音声・動画は `WhisperBatchError`
    @concurrent
    public static func inspect(_ url: URL) async throws -> MediaInfo {
        let name = url.lastPathComponent
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw WhisperBatchError.fileNotFound(name: name)
        }
        let asset = AVURLAsset(url: url)
        let audioTracks: [AVAssetTrack]
        let videoTracks: [AVAssetTrack]
        do {
            audioTracks = try await asset.loadTracks(withMediaType: .audio)
            videoTracks = try await asset.loadTracks(withMediaType: .video)
        } catch {
            throw AudioSampleReader.mapOpenError(error, name: name)
        }
        let kind: MediaKind = videoTracks.isEmpty ? .audio : .video
        guard !audioTracks.isEmpty else {
            throw kind == .video ? WhisperBatchError.videoHasNoAudio(name: name) : WhisperBatchError.noAudioTrack(name: name)
        }
        let seconds = (try? await asset.load(.duration)).map { CMTimeGetSeconds($0) } ?? 0
        return MediaInfo(duration: seconds.isFinite ? max(seconds, 0) : 0, kind: kind)
    }
}

/// 変換用の一時 MP3 を置くフォルダ（プロセスごとのフォルダ。`TemporaryWorkspace` を参照）。
/// 一時ファイルは処理が終わると削除し、異常終了で残ったものは次回の起動時に削除する。
public enum ConversionWorkspace {
    static var workspace: TemporaryWorkspace { .conversions }

    public static func makeTemporaryMP3URL() throws -> URL {
        try workspace.makeFile(prefix: "", pathExtension: "mp3")
    }

    /// 起動時: 終了したプロセス（異常終了を含む）が残した一時ファイルだけを消す
    public static func removeAbandonedFiles() {
        workspace.removeAbandoned()
    }

    /// 終了時: このプロセスの一時ファイルを消す（ほかのプロセスのものは消さない）
    public static func removeOwnFiles() {
        workspace.removeOwnFiles()
    }

    public static func remove(_ url: URL) {
        workspace.remove(url)
    }
}
