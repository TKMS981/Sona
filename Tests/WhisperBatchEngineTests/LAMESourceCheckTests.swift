import Foundation
import Testing

/// scripts/fetch-lame.sh が、展開済みの LAME のソースの変更・欠落・追加を検出してビルドを止めるか。
/// 作業用のコピーで試す（リポジトリの ThirdParty/LAME/Sources/CLAME には触れない）。通信はしない。
private let repoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
private let extracted = repoRoot.appendingPathComponent("ThirdParty/LAME/Sources/CLAME")

@Suite("LAME のソースの照合", .serialized,
       .enabled(if: FileManager.default.fileExists(atPath: extracted.appendingPathComponent("lame.c").path)))
final class LAMESourceCheckTests {
    private let work: URL
    private var clame: URL { work.appendingPathComponent("ThirdParty/LAME/Sources/CLAME") }

    init() throws {
        let fm = FileManager.default
        work = fm.temporaryDirectory.appendingPathComponent("sona-lame-check-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: work.appendingPathComponent("scripts"), withIntermediateDirectories: true)
        try fm.createDirectory(at: work.appendingPathComponent("ThirdParty/LAME/Sources"), withIntermediateDirectories: true)
        try fm.copyItem(at: repoRoot.appendingPathComponent("scripts/fetch-lame.sh"),
                        to: work.appendingPathComponent("scripts/fetch-lame.sh"))
        for name in ["config.h", "CLAME.sha256"] {
            try fm.copyItem(at: repoRoot.appendingPathComponent("ThirdParty/LAME/\(name)"),
                            to: work.appendingPathComponent("ThirdParty/LAME/\(name)"))
        }
        try fm.copyItem(at: extracted, to: clame)
        // 以前の版が作った目印。このスクリプトは信頼せずに消す
        try Data().write(to: clame.appendingPathComponent(".lame-4.0"))
    }

    deinit {
        try? FileManager.default.removeItem(at: work)
    }

    /// スクリプトを実行して終了コードを返す
    private func run() throws -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = [work.appendingPathComponent("scripts/fetch-lame.sh").path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        return p.terminationStatus
    }

    @Test func intactSourcePasses() throws {
        #expect(try run() == 0)
        #expect(!FileManager.default.fileExists(atPath: clame.appendingPathComponent(".lame-4.0").path))
        // Finder のメタデータはビルドに使われないので数えない
        try Data("x".utf8).write(to: clame.appendingPathComponent(".DS_Store"))
        #expect(try run() == 0)
    }

    @Test func modifiedFileStopsBuild() throws {
        let file = clame.appendingPathComponent("lame.c")
        var data = try Data(contentsOf: file)
        data[data.count / 2] ^= 0x01
        try data.write(to: file)
        #expect(try run() != 0)
    }

    @Test func missingFileStopsBuild() throws {
        try FileManager.default.removeItem(at: clame.appendingPathComponent("util.h"))
        #expect(try run() != 0)
    }

    @Test func addedFileStopsBuild() throws {
        try Data("int injected(void) { return 1; }\n".utf8).write(to: clame.appendingPathComponent("extra.c"))
        #expect(try run() != 0)
    }

    @Test func symlinkStopsBuild() throws {
        try FileManager.default.createSymbolicLink(at: clame.appendingPathComponent("vector/link.h"),
                                                   withDestinationURL: clame.appendingPathComponent("util.h"))
        #expect(try run() != 0)
    }

    @Test func editedConfigCopyStopsBuild() throws {
        let file = clame.appendingPathComponent("config.h")
        try (try String(contentsOf: file, encoding: .utf8) + "\n#define INJECTED 1\n").write(to: file, atomically: true, encoding: .utf8)
        #expect(try run() != 0)
    }
}
