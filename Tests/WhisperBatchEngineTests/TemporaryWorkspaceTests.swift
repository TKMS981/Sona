import Foundation
import Testing
@testable import WhisperBatchEngine

// 順に実行する: 子プロセス（perl）を起動している瞬間は、このプロセスのロックが子にも一時的に共有されて
// 「使用中」に見え、同時に走る別のテストの掃除が（安全側に）何も消さないことがあるため
@Suite("一時フォルダのプロセスごとの分離", .serialized)
final class TemporaryWorkspaceTests {
    private let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SonaWorkspaceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ url: URL) throws {
        try Data("audio".utf8).write(to: url)
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    @Test func createsPrivateFolderAndFreshFiles() throws {
        let ws = TemporaryWorkspace(base: root)
        defer { ws.removeOwnFiles() }
        let dir = try ws.directory()
        let fm = FileManager.default
        #expect(try fm.attributesOfItem(atPath: dir.path)[.posixPermissions] as? Int == 0o700)
        let a = try ws.makeFile(prefix: "live-", pathExtension: "wav")
        let b = try ws.makeFile(prefix: "live-", pathExtension: "wav")
        #expect(a != b)
        #expect(a.deletingLastPathComponent().path == dir.path)
        #expect(try fm.attributesOfItem(atPath: a.path)[.posixPermissions] as? Int == 0o600)
        #expect(try fm.attributesOfItem(atPath: a.path)[.size] as? Int == 0)
        // 同じプロセスでは同じフォルダを使い続ける
        #expect(try ws.directory() == dir)
    }

    @Test func cleanupKeepsActiveOwnersAndRemovesAbandonedOnes() throws {
        let active = TemporaryWorkspace(base: root)
        let crashed = TemporaryWorkspace(base: root)
        let activeFile = try active.makeFile(prefix: "live-", pathExtension: "wav")
        let crashedFile = try crashed.makeFile(prefix: "live-", pathExtension: "wav")
        let crashedDir = crashedFile.deletingLastPathComponent()
        try write(activeFile)
        try write(crashedFile)
        crashed.abandonForTesting()

        // 新しく起動したプロセスの掃除
        let launcher = TemporaryWorkspace(base: root)
        // 別のテストが子プロセスを起動している瞬間は、ロックが一時的に共有されて「使用中」に見える（消さない側に倒れる）
        var removed = 0
        for _ in 0 ..< 50 where removed == 0 {
            removed = launcher.removeAbandoned()
            if removed == 0 { Thread.sleep(forTimeInterval: 0.01) }
        }
        #expect(removed == 1)
        #expect(exists(activeFile))
        #expect(!exists(crashedDir))
        #expect(!exists(crashedDir.appendingPathExtension("lock")))

        // 動いているプロセスは、掃除の後も同じフォルダに書き続けられる
        try write(activeFile)
        let more = try active.makeFile(prefix: "live-", pathExtension: "wav")
        #expect(exists(more))

        // 終了時は自分のフォルダだけを消す
        let other = TemporaryWorkspace(base: root)
        let otherFile = try other.makeFile(prefix: "", pathExtension: "mp3")
        active.removeOwnFiles()
        #expect(!exists(activeFile))
        #expect(exists(otherFile))
        other.removeOwnFiles()
        #expect(!exists(otherFile))
    }

    @Test func removeOnlyTouchesOwnFolder() throws {
        let a = TemporaryWorkspace(base: root)
        let b = TemporaryWorkspace(base: root)
        defer { a.removeOwnFiles(); b.removeOwnFiles() }
        let fileB = try b.makeFile(prefix: "live-", pathExtension: "wav")
        let outside = root.appendingPathComponent("outside.wav")
        try write(outside)
        _ = try a.directory()
        a.remove(fileB)
        a.remove(outside)
        #expect(exists(fileB))
        #expect(exists(outside))
        b.remove(fileB)
        #expect(!exists(fileB))
    }

    @Test func cleanupIgnoresUnknownNamesAndOrphanFoldersAreRemoved() throws {
        let unknown = root.appendingPathComponent("notes.txt")
        try write(unknown)
        // ロックファイルのないフォルダ（持ち主が消すのに失敗して終わったもの）
        let orphan = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: false)
        try write(orphan.appendingPathComponent("live-x.wav"))
        let ws = TemporaryWorkspace(base: root)
        ws.removeAbandoned()
        #expect(exists(unknown))
        #expect(!exists(orphan))
    }

    @Test func refusesSymlinkedBase() throws {
        let target = root.appendingPathComponent("target", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        let link = root.appendingPathComponent("link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let ws = TemporaryWorkspace(base: link)
        #expect(throws: (any Error).self) { try ws.directory() }
        #expect(ws.removeAbandoned() == 0)
        #expect(try FileManager.default.contentsOfDirectory(atPath: target.path).isEmpty)
    }

    /// 別のプロセスが同じ形式でフォルダを持っている間は消さず、そのプロセスが強制終了したら消す
    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: "/usr/bin/perl")))
    func otherProcessIsProtectedUntilItDies() throws {
        let id = UUID().uuidString
        let script = """
        use Fcntl qw(:flock O_RDWR O_CREAT O_EXCL);
        my ($base, $id) = @ARGV;
        sysopen(my $fh, "$base/$id.lock", O_RDWR|O_CREAT|O_EXCL, 0600) or die "lock: $!";
        flock($fh, LOCK_EX) or die "flock: $!";
        mkdir("$base/$id", 0700) or die "mkdir: $!";
        open(my $f, ">", "$base/$id/live-x.wav") or die "file: $!"; print $f "data"; close $f;
        $| = 1; print "ready\\n";
        sleep 60;
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = ["-e", script, root.path, id]
        let out = Pipe()
        process.standardOutput = out
        try process.run()
        defer { if process.isRunning { process.terminate() } }
        let line = String(decoding: out.fileHandleForReading.availableData, as: UTF8.self)
        try #require(line.contains("ready"))

        let file = root.appendingPathComponent("\(id)/live-x.wav")
        let ws = TemporaryWorkspace(base: root)
        #expect(ws.removeAbandoned() == 0)
        #expect(exists(file))

        kill(process.processIdentifier, SIGKILL)
        process.waitUntilExit()
        #expect(ws.removeAbandoned() == 1)
        #expect(!exists(file))
        #expect(!exists(root.appendingPathComponent("\(id).lock")))
    }
}
