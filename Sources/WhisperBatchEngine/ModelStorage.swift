import CryptoKit
import Darwin
import Foundation
import Synchronization
import WhisperBatchCore

/// モデルファイルの保存場所と、取得済みかどうかの判定
public struct ModelStorage: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// 既定の保存先: ~/Library/Application Support/WhisperBatch/Models
    /// （サンドボックス有効時は ~/Library/Containers/<Bundle ID>/Data/Library/Application Support/WhisperBatch/Models）
    public static func defaultStorage() throws -> ModelStorage {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return ModelStorage(directory: base.appendingPathComponent("WhisperBatch/Models", isDirectory: true))
    }

    public func ensureDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// モデルのファイルを置くフォルダ（Whisper は保存先の直下）
    public func directory(for model: SpeechModel) -> URL {
        model.folder.map { directory.appendingPathComponent($0, isDirectory: true) } ?? directory
    }

    public func fileURL(for file: ModelFile, of model: SpeechModel) -> URL {
        directory(for: model).appendingPathComponent(file.name)
    }

    /// 検証前のダウンロード済みファイル
    func partialURL(for file: ModelFile, of model: SpeechModel) -> URL {
        directory(for: model).appendingPathComponent(file.name + ".download")
    }

    /// ファイルが揃っているか（あり、サイズが一致する）。内容は、ダウンロード直後と、読み込む直前
    /// （`verifyContents(of:)`）に SHA-256 で確かめる。
    public func isInstalled(_ file: ModelFile, of model: SpeechModel) -> Bool {
        let path = fileURL(for: file, of: model).path
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = (attrs[.size] as? NSNumber)?.int64Value else { return false }
        return size == file.sizeBytes
    }

    /// モデルのファイルがすべて揃っているか（ダウンロードしないモデルは false）
    public func isInstalled(_ model: SpeechModel) -> Bool {
        model.isDownloadable && model.files.allSatisfy { isInstalled($0, of: model) }
    }

    public func delete(_ model: SpeechModel) throws {
        let fm = FileManager.default
        for file in model.files {
            for url in [fileURL(for: file, of: model), partialURL(for: file, of: model)] where fm.fileExists(atPath: url.path) {
                try fm.removeItem(at: url)
            }
        }
        // モデル専用のフォルダが空になったら消す
        if model.folder != nil {
            let dir = directory(for: model)
            if (try? fm.contentsOfDirectory(atPath: dir.path))?.isEmpty == true {
                try? fm.removeItem(at: dir)
            }
        }
    }

    /// 保存先ボリュームの空き容量
    public func availableCapacity() -> Int64? {
        let probe = FileManager.default.fileExists(atPath: directory.path) ? directory : directory.deletingLastPathComponent()
        let values = try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    /// 読み込む前に、モデルのファイルの内容がカタログの SHA-256 と一致するかを確かめる。
    ///
    /// 同じプロセスの中で一度確かめたファイルは、ファイルの同一性（デバイス・inode・サイズ・更新時刻・状態変更時刻）が
    /// 変わらない限り確かめ直さない。内容の書き換え、別のファイルへの置き換え、属性の変更（状態変更時刻は
    /// 利用者のプログラムからは戻せない）のどれでも確かめ直す。結果はディスクに保存しない
    /// （保存すると、モデルを書き換えられる者がその記録も書き換えられるため）。
    /// 確かめてから whisper.cpp などが読み込むまでの間の置き換えは検出できない。
    public func verifyContents(of model: SpeechModel) async throws {
        for file in model.files {
            let url = fileURL(for: file, of: model)
            guard let before = FileIdentity(path: url.path) else {
                throw WhisperBatchError.modelNotInstalled(modelName: model.displayName)
            }
            if VerifiedModelFiles.shared.isVerified(path: url.path, identity: before, sha256: file.sha256) { continue }
            let digest: String
            do {
                digest = try await Self.sha256(of: url)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw WhisperBatchError.modelLoadFailed(modelName: model.displayName)
            }
            // 計算している間に変わったものは、確かめられたとはいえない
            guard digest == file.sha256, FileIdentity(path: url.path) == before else {
                VerifiedModelFiles.shared.forget(path: url.path)
                throw WhisperBatchError.modelFileModified(modelName: model.displayName)
            }
            VerifiedModelFiles.shared.remember(path: url.path, identity: before, sha256: file.sha256)
        }
    }

    /// SHA-256 をファイルを少しずつ読みながら計算する
    @concurrent
    static func sha256(of url: URL) async throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            try Task.checkCancellation()
            let data = try handle.read(upToCount: 8 * 1024 * 1024) ?? Data()
            if data.isEmpty { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// ファイルの同一性。どれかが変われば、内容が変わった可能性があるとみなす。
struct FileIdentity: Equatable, Sendable {
    var device: Int64
    var inode: UInt64
    var size: Int64
    var modified: timespec
    var changed: timespec

    init?(path: String) {
        var s = stat()
        guard stat(path, &s) == 0, (s.st_mode & S_IFMT) == S_IFREG else { return nil }
        device = Int64(s.st_dev)
        inode = UInt64(s.st_ino)
        size = Int64(s.st_size)
        modified = s.st_mtimespec
        changed = s.st_ctimespec
    }

    static func == (a: FileIdentity, b: FileIdentity) -> Bool {
        a.device == b.device && a.inode == b.inode && a.size == b.size
            && a.modified.tv_sec == b.modified.tv_sec && a.modified.tv_nsec == b.modified.tv_nsec
            && a.changed.tv_sec == b.changed.tv_sec && a.changed.tv_nsec == b.changed.tv_nsec
    }
}

/// このプロセスで内容を確かめたモデルのファイル（メモリーの中だけに持つ）
final class VerifiedModelFiles: Sendable {
    static let shared = VerifiedModelFiles()

    private struct Entry {
        var identity: FileIdentity
        var sha256: String
    }

    private let entries = Mutex<[String: Entry]>([:])

    func isVerified(path: String, identity: FileIdentity, sha256: String) -> Bool {
        entries.withLock { $0[path].map { $0.identity == identity && $0.sha256 == sha256 } ?? false }
    }

    func remember(path: String, identity: FileIdentity, sha256: String) {
        entries.withLock { $0[path] = Entry(identity: identity, sha256: sha256) }
    }

    func forget(path: String) {
        _ = entries.withLock { $0.removeValue(forKey: path) }
    }
}
