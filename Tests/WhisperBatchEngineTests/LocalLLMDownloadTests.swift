import CryptoKit
import Foundation
import Synchronization
import Testing
import WhisperBatchCore
@testable import WhisperBatchEngine

// ローカルの言語モデルの取得状況と、取得の中止・再開・照合のテスト

@Suite("ローカルの言語モデルの取得状況")
struct ModelInstallationTests {
    init() { TestLocalization.setUp() }

    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("SonaLLMInstall-\(UUID().uuidString)")
    var storage: ModelStorage { ModelStorage(directory: folder) }

    /// テスト用のモデル（今のリビジョンと、以前のリビジョンを 1 つ持つ）
    private func model(currentSize: Int64, previousSize: Int64) -> LocalLLM {
        LocalLLM(id: "test-model", name: "Test", publisher: "Test", parameters: "1B", quantization: "Q4",
                 repository: "sona-test/model", revision: String(repeating: "b", count: 40),
                 file: .init(name: "model-new.gguf", sizeBytes: currentSize, sha256: String(repeating: "0", count: 64)),
                 license: .init(name: "MIT", url: "https://example.com"), format: .chatML,
                 categories: [.multilingual], tasks: [.summary], contextTokens: 4096,
                 previousFiles: [.init(revision: String(repeating: "a", count: 40),
                                       file: .init(name: "model-old.gguf", sizeBytes: previousSize, sha256: String(repeating: "1", count: 64)))])
    }

    private func write(_ name: String, size: Int, for m: LocalLLM) throws {
        let dir = storage.directory(for: m.downloadModel)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(count: size).write(to: dir.appendingPathComponent(name))
    }

    @Test func reportsCurrentOutdatedAndMissing() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let m = model(currentSize: 300, previousSize: 200)
        #expect(ModelInstallation.resolve(m, storage: storage) == .notInstalled)
        #expect(ModelInstallation.resolve(m, storage: storage).usableModel == nil)

        // 以前のリビジョンだけがある: 更新があるが、更新するまでは以前のリビジョンを使う（自動では更新しない）
        try write("model-old.gguf", size: 200, for: m)
        let outdated = ModelInstallation.resolve(m, storage: storage)
        #expect(outdated.hasUpdate)
        #expect(outdated.usableModel?.files.first?.name == "model-old.gguf")
        #expect(outdated.usableModel?.files.first?.url.path.contains("/resolve/\(String(repeating: "a", count: 40))/") == true)

        // 今のリビジョンがそろえば、そちらを使う
        try write("model-new.gguf", size: 300, for: m)
        let current = ModelInstallation.resolve(m, storage: storage)
        #expect(!current.hasUpdate)
        #expect(current.usableModel?.files.first?.name == "model-new.gguf")

        // 大きさが違う（途中のファイルなど）ものは取得済みとみなさない
        try write("model-new.gguf", size: 299, for: m)
        #expect(ModelInstallation.resolve(m, storage: storage).hasUpdate)
    }

    @Test func verificationRejectsTamperedModelBeforeLoading() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let body = Data((0 ..< 500).map { UInt8($0 % 251) })
        let digest = SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
        let m = LocalLLM(id: "verify-model", name: "Verify", publisher: "Test", parameters: "1B", quantization: "Q4",
                         repository: "sona-test/verify", revision: String(repeating: "c", count: 40),
                         file: .init(name: "v.gguf", sizeBytes: 500, sha256: digest),
                         license: .init(name: "MIT", url: "https://example.com"), format: .chatML,
                         categories: [.multilingual], tasks: [.summary], contextTokens: 4096)
        let download = m.downloadModel
        let dir = storage.directory(for: download)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try body.write(to: dir.appendingPathComponent("v.gguf"))
        try await storage.verifyContents(of: download)
        var tampered = body
        tampered[10] ^= 0xFF
        try tampered.write(to: dir.appendingPathComponent("v.gguf"))
        await #expect(throws: WhisperBatchError.modelFileModified(modelName: download.displayName)) {
            try await storage.verifyContents(of: download)
        }
    }
}

// 実際に Hugging Face から取得して、中止・再開・照合を試す（通信する）。次の環境変数を設定したときだけ実行する。
//   WHISPER_BATCH_TEST_LLM_DOWNLOAD_DIR : 保存先（TinySwallow 1.5B、約 1.1GB を取得する）
private let downloadDir = ProcessInfo.processInfo.environment["WHISPER_BATCH_TEST_LLM_DOWNLOAD_DIR"].map { URL(fileURLWithPath: $0) }

@Suite("ローカルの言語モデルの取得（通信あり）", .enabled(if: downloadDir != nil), .serialized)
struct LocalLLMDownloadNetworkTests {
    init() { TestLocalization.setUp() }

    @Test func cancelThenResumeAndVerify() async throws {
        let llm = try #require(LocalLLMCatalog.model(id: "tinyswallow-1.5b"))
        let model = llm.downloadModel
        let storage = ModelStorage(directory: downloadDir!)
        try? storage.delete(model)
        let received = Atomic<Int64>(0)

        // 3 割ほど受け取ったところで中止する
        let task = Task {
            try await ModelDownloader.download(model, into: storage, resumeData: nil,
                                               progress: { r, _ in received.store(r, ordering: .relaxed) }, verifying: {})
        }
        while received.load(ordering: .relaxed) < model.sizeBytes * 3 / 10 {
            try await Task.sleep(for: .milliseconds(50))
        }
        task.cancel()
        var resume: Data?
        do {
            try await task.value
            Issue.record("中止されなかった")
        } catch let e as ModelDownloadInterruption {
            #expect(e.isCancelled)
            resume = e.resumeData
        }
        let atCancel = received.load(ordering: .relaxed)
        print("中止した時点の受信: \(atCancel / 1_000_000)MB / 再開用のデータ: \(resume.map { "\($0.count) バイト" } ?? "なし")")
        #expect(resume != nil)
        // 検証前のファイルは残さない
        #expect(!FileManager.default.fileExists(atPath: storage.partialURL(for: model.files[0], of: model).path))
        #expect(!storage.isInstalled(model))

        // 再開する（途中から受け取る）
        let firstProgress = Atomic<Int64>(-1)
        try await ModelDownloader.download(model, into: storage, resumeData: resume,
                                           progress: { r, _ in
                                               _ = firstProgress.compareExchange(expected: -1, desired: r, ordering: .relaxed)
                                           }, verifying: {})
        let resumedAt = firstProgress.load(ordering: .relaxed)
        print("再開した最初の進捗: \(resumedAt / 1_000_000)MB")
        #expect(resumedAt >= atCancel / 2, "途中から再開している")
        #expect(storage.isInstalled(model))
        // SHA-256 の照合（取得の最後と、読み込む前）
        try await storage.verifyContents(of: model)
        #expect(ModelInstallation.resolve(llm, storage: storage) == .current(model))
    }
}
