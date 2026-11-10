import Darwin
import Foundation
import Synchronization

/// プロセスごとに分けた一時フォルダ。
///
/// 構成は `<base>/<ID>.lock` と `<base>/<ID>/`（ID は UUID）。
/// - フォルダを作ったプロセスは `<ID>.lock` の排他ロック（flock）を持ち続ける。ロックはプロセスが終わると
///   （異常終了でも）カーネルが外すので、「ロックを取れる = 持ち主のプロセスはもういない」と判断できる。
///   PID は使わないので、PID の再利用に左右されない。
/// - 起動時の掃除（`removeAbandoned()`）は、ロックを取れたフォルダだけを消す。動いている別のプロセス
///   （同じアプリの別のコピーや、Bundle ID とサンドボックスを共有する旧版）のフォルダには触れない。
/// - 終了時（`removeOwnFiles()`）は自分のフォルダだけを消す。
/// - 判断に迷う場合（ロックを確かめられない、子プロセスの起動中でロックが一時的に共有されている など）は消さない。
///   残ったものは次の起動時の掃除で消える。
/// - フォルダは所有者だけが読み書きできる（0700）。ファイルは予測できない名前で新しく作り（O_EXCL）、
///   既存のファイルを開いたり切り詰めたりしない。
public final class TemporaryWorkspace: Sendable {
    public let base: URL

    private struct Owned {
        var id: UUID
        var lockFD: Int32
    }

    private let owned = Mutex<Owned?>(nil)

    public init(base: URL) {
        self.base = base
    }

    /// このプロセスのフォルダ。初めて使うときに作る。
    public func directory() throws -> URL {
        try owned.withLock { state throws -> URL in
            if let state { return folder(state.id) }
            let created = try create()
            state = created
            return folder(created.id)
        }
    }

    /// このプロセスのフォルダに、予測できない名前の空のファイルを新しく作り、その URL を返す
    public func makeFile(prefix: String, pathExtension: String) throws -> URL {
        let dir = try directory()
        for _ in 0 ..< 5 {
            let url = dir.appendingPathComponent("\(prefix)\(UUID().uuidString).\(pathExtension)")
            let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            if fd >= 0 {
                close(fd)
                return url
            }
            if errno != EEXIST { throw Self.posixError() }
        }
        throw CocoaError(.fileWriteFileExists)
    }

    /// このプロセスのフォルダにあるファイルを 1 つ消す（ほかの場所のファイルは消さない）
    public func remove(_ url: URL) {
        guard let dir = owned.withLock({ $0.map { folder($0.id) } }),
              url.deletingLastPathComponent().standardizedFileURL.path == dir.standardizedFileURL.path else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// このプロセスのフォルダを中身ごと消す（アプリの終了時）。以降に使うと新しいフォルダを作る。
    public func removeOwnFiles() {
        owned.withLock { state in
            guard let s = state else { return }
            // フォルダを消してからロックファイルを消し、最後にロックを外す
            try? FileManager.default.removeItem(at: folder(s.id))
            unlink(lockURL(s.id).path)
            close(s.lockFD)
            state = nil
        }
    }

    /// 持ち主のプロセスが終わっている（ロックを取れる）フォルダだけを消す。消したフォルダの数を返す。
    @discardableResult
    public func removeAbandoned() -> Int {
        let ownID = owned.withLock { $0?.id }
        guard Self.isRealDirectory(base),
              let names = try? FileManager.default.contentsOfDirectory(atPath: base.path) else { return 0 }
        var ids = Set<UUID>()
        for name in names {
            let stem = name.hasSuffix(".lock") ? String(name.dropLast(5)) : name
            if let id = UUID(uuidString: stem), id != ownID { ids.insert(id) }
        }
        return ids.reduce(0) { $0 + (removeIfAbandoned($1) ? 1 : 0) }
    }

    /// テスト用: 異常終了と同じ状態にする（ファイルを残したままロックを外す）
    func abandonForTesting() {
        owned.withLock { state in
            if let s = state { close(s.lockFD) }
            state = nil
        }
    }

    // MARK: private

    private func folder(_ id: UUID) -> URL {
        base.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    private func lockURL(_ id: UUID) -> URL {
        base.appendingPathComponent(id.uuidString + ".lock", isDirectory: false)
    }

    private func create() throws -> Owned {
        let fm = FileManager.default
        try fm.createDirectory(at: base, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // シンボリックリンクなどに置き換えられていたら使わない
        guard Self.isRealDirectory(base) else { throw CocoaError(.fileWriteNoPermission) }
        for _ in 0 ..< 5 {
            let id = UUID()
            let lockPath = lockURL(id).path
            // 作成と同時に排他ロックを取る（O_EXLOCK）。同じ名前のファイルがあれば失敗する（O_EXCL）。
            // O_CLOEXEC: 子プロセスにロックを引き継がない（引き継ぐと、終了後もロックが残る）
            let fd = open(lockPath, O_RDWR | O_CREAT | O_EXCL | O_EXLOCK | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0 else {
                if errno == EEXIST { continue }
                throw Self.posixError()
            }
            // 作成からロックまでのわずかな間に、別プロセスの掃除がこのファイルを消していたら、この ID は使わない
            guard Self.isSameFile(fd, path: lockPath) else {
                close(fd)
                continue
            }
            do {
                // ロックを取ってからフォルダを作る（掃除はロックファイルのないフォルダを、終わったものとして扱う）
                try fm.createDirectory(at: folder(id), withIntermediateDirectories: false,
                                       attributes: [.posixPermissions: 0o700])
            } catch {
                unlink(lockPath)
                close(fd)
                throw error
            }
            return Owned(id: id, lockFD: fd)
        }
        throw CocoaError(.fileWriteUnknown)
    }

    private func removeIfAbandoned(_ id: UUID) -> Bool {
        let lockPath = lockURL(id).path
        let fd = open(lockPath, O_RDWR | O_EXLOCK | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {
            // ロックファイルがない: 持ち主はフォルダを消し終えたか、消すのに失敗して終わっている。
            // 持ち主はロックファイルを作ってからフォルダを作るので、動いているプロセスのフォルダではない。
            // EWOULDBLOCK（ロック中 = 持ち主が動いている）などのときは何もしない。
            return errno == ENOENT && removeFolder(id)
        }
        defer { close(fd) }
        // 開いてからロックを取るまでの間に、別の掃除がこのロックファイルを消していたら何もしない
        guard Self.isSameFile(fd, path: lockPath) else { return false }
        guard removeFolder(id) else { return false }
        unlink(lockPath)
        return true
    }

    /// フォルダを消す。もともとない場合も成功として扱う。
    private func removeFolder(_ id: UUID) -> Bool {
        let url = folder(id)
        guard FileManager.default.fileExists(atPath: url.path) else { return true }
        return (try? FileManager.default.removeItem(at: url)) != nil
    }

    private static func isSameFile(_ fd: Int32, path: String) -> Bool {
        var a = stat()
        var b = stat()
        guard fstat(fd, &a) == 0, lstat(path, &b) == 0 else { return false }
        return a.st_dev == b.st_dev && a.st_ino == b.st_ino
    }

    private static func isRealDirectory(_ url: URL) -> Bool {
        var s = stat()
        guard lstat(url.path, &s) == 0 else { return false }
        return (s.st_mode & S_IFMT) == S_IFDIR && s.st_uid == getuid()
    }

    private static func posixError() -> any Error {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}

extension TemporaryWorkspace {
    /// ライブ文字起こしの一時録音。開発中の版がフォルダごと消していた `WhisperBatchLive` とは別の場所にする。
    public static let liveRecording = TemporaryWorkspace(
        base: FileManager.default.temporaryDirectory.appendingPathComponent("Sona-Live", isDirectory: true))

    /// 動画の変換用の一時 MP3。旧版（Whisper Batch 1.1.1 まで）は起動・終了時に `WhisperBatch-Conversions` を
    /// フォルダごと消すので、旧版と同時に動かしても消されないよう別の場所にする。
    public static let conversions = TemporaryWorkspace(
        base: FileManager.default.temporaryDirectory.appendingPathComponent("Sona-Conversions", isDirectory: true))
}
