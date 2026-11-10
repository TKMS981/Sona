import CryptoKit
import Foundation
import Synchronization
import Testing
import WhisperBatchCore
@testable import WhisperBatchEngine

/// huggingface.co の代わりに応答する（通信はしない）。パスごとに応答の内容を決める。
final class MockModelServer: URLProtocol, @unchecked Sendable {
    struct Scenario: Sendable {
        var status = 200
        var contentLength: Int?
        var chunks: [Data]
        var chunkDelay: TimeInterval = 0
    }

    static let scenarios = Mutex<[String: Scenario]>([:])
    static let sentBytes = Mutex<[String: Int]>([:])
    static let stoppedPaths = Mutex<Set<String>>([])

    private let stopped = Atomic<Bool>(false)

    static func configuration() -> URLSessionConfiguration {
        let config = ModelDownloader.defaultConfiguration()
        config.protocolClasses = [MockModelServer.self]
        return config
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "huggingface.co" && request.url?.path.hasPrefix("/sona-test/") == true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let scenario = Self.scenarios.withLock({ $0[url.path] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        var headers: [String: String] = [:]
        if let length = scenario.contentLength { headers["Content-Length"] = "\(length)" }
        let response = HTTPURLResponse(url: url, statusCode: scenario.status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        DispatchQueue.global().async { [self] in
            for chunk in scenario.chunks {
                if stopped.load(ordering: .relaxed) { return }
                client?.urlProtocol(self, didLoad: chunk)
                Self.sentBytes.withLock { $0[url.path, default: 0] += chunk.count }
                if scenario.chunkDelay > 0 { Thread.sleep(forTimeInterval: scenario.chunkDelay) }
            }
            if !stopped.load(ordering: .relaxed) { client?.urlProtocolDidFinishLoading(self) }
        }
    }

    override func stopLoading() {
        stopped.store(true, ordering: .relaxed)
        if let path = request.url?.path { _ = Self.stoppedPaths.withLock { $0.insert(path) } }
    }
}

@Suite("モデルのダウンロード: 大きさの上限と後片付け", .serialized)
final class ModelDownloadLimitTests {
    private let folder: URL
    private let storage: ModelStorage

    init() {
        TestLocalization.setUp()
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("sona-download-test-\(UUID().uuidString)")
        storage = ModelStorage(directory: folder)
    }

    deinit {
        try? FileManager.default.removeItem(at: folder)
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// 応答の内容と、カタログ上の大きさ・SHA-256 を決めてモデルを作る
    private func model(size: Int64, sha256: String, scenario: MockModelServer.Scenario) -> SpeechModel {
        let path = "/sona-test/\(UUID().uuidString)/model.bin"
        MockModelServer.scenarios.withLock { $0[path] = scenario }
        let file = ModelFile(name: "model-\(UUID().uuidString).bin", url: URL(string: "https://huggingface.co\(path)")!,
                             sizeBytes: size, sha256: sha256)
        return SpeechModel(id: "test", engine: .whisper, files: [file])
    }

    private func download(_ model: SpeechModel) async -> ModelDownloadInterruption? {
        await Self.download(model, into: storage)
    }

    private static func download(_ model: SpeechModel, into storage: ModelStorage) async -> ModelDownloadInterruption? {
        do {
            try await ModelDownloader.download(model, into: storage, resumeData: nil, progress: { _, _ in },
                                               verifying: {}, configuration: { MockModelServer.configuration() })
            return nil
        } catch {
            return error
        }
    }

    private func leftovers(_ model: SpeechModel) -> (partial: Bool, final: Bool) {
        let file = model.files[0]
        let fm = FileManager.default
        return (fm.fileExists(atPath: storage.partialURL(for: file, of: model).path),
                fm.fileExists(atPath: storage.fileURL(for: file, of: model).path))
    }

    private func failure(_ error: ModelDownloadInterruption?) -> WhisperBatchError? {
        guard let error, case .failed(let failure) = error.reason else { return nil }
        return failure
    }

    @Test func stopsReceivingWhenDataExceedsCatalogSize() async throws {
        // 大きさを宣言しない応答で、カタログの 2,000 バイトを超えて送り続ける
        let chunks = Array(repeating: Data(repeating: 7, count: 1000), count: 60)
        let m = model(size: 2000, sha256: "00", scenario: .init(chunks: chunks, chunkDelay: 0.01))
        let error = await download(m)
        let f = try #require(failure(error), "中止ではなく失敗として報告する")
        #expect(f.errorDescription?.contains("2,000") == true)
        #expect(error?.resumeData == nil)
        let path = m.files[0].url.path
        #expect(MockModelServer.stoppedPaths.withLock { $0.contains(path) })
        // 上限を超えたところで止め、残り（全体で 60,000 バイト）を受け取らない
        let sent = MockModelServer.sentBytes.withLock { $0[path] ?? 0 }
        #expect(sent < 20_000)
        #expect(leftovers(m) == (false, false))
    }

    @Test func rejectsDeclaredLengthAboveCatalogSize() async throws {
        let chunks = Array(repeating: Data(repeating: 1, count: 1000), count: 30)
        let m = model(size: 2000, sha256: "00", scenario: .init(contentLength: 30_000, chunks: chunks, chunkDelay: 0.01))
        let error = await download(m)
        #expect(failure(error) != nil)
        let sent = MockModelServer.sentBytes.withLock { $0[m.files[0].url.path] ?? 0 }
        #expect(sent < 10_000)
        #expect(leftovers(m) == (false, false))
    }

    @Test func httpErrorLeavesNothing() async throws {
        let m = model(size: 2000, sha256: "00", scenario: .init(status: 404, chunks: [Data("Not Found".utf8)]))
        // 前回の残りの検証前ファイルがあっても消す
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("stale".utf8).write(to: storage.partialURL(for: m.files[0], of: m))
        let error = await download(m)
        #expect(failure(error) == .downloadHTTPError(statusCode: 404))
        #expect(leftovers(m) == (false, false))
    }

    @Test func shortBodyFailsSizeCheckBeforeHashing() async throws {
        let body = Data(repeating: 3, count: 1500)
        let verifying = Mutex(false)
        let m = model(size: 2000, sha256: Self.sha256(body), scenario: .init(chunks: [body]))
        var error: ModelDownloadInterruption?
        do {
            try await ModelDownloader.download(m, into: storage, resumeData: nil, progress: { _, _ in },
                                               verifying: { verifying.withLock { $0 = true } },
                                               configuration: { MockModelServer.configuration() })
        } catch let e { error = e }
        let f = try #require(failure(error))
        #expect(f.errorDescription?.contains("1,500") == true)
        #expect(!verifying.withLock { $0 }, "大きさが違えばハッシュを計算しない")
        #expect(leftovers(m) == (false, false))
    }

    @Test func hashMismatchLeavesNothing() async throws {
        let body = Data(repeating: 5, count: 2000)
        let m = model(size: 2000, sha256: Self.sha256(Data(repeating: 6, count: 2000)), scenario: .init(chunks: [body]))
        let error = await download(m)
        #expect(failure(error) == .checksumMismatch(modelName: m.displayName))
        #expect(leftovers(m) == (false, false))
    }

    @Test func userCancelIsReportedAsCancelled() async throws {
        let chunks = Array(repeating: Data(repeating: 9, count: 100), count: 100)
        let m = model(size: 10_000, sha256: "00", scenario: .init(chunks: chunks, chunkDelay: 0.02))
        let storage = storage
        let task = Task { await Self.download(m, into: storage) }
        try await Task.sleep(for: .milliseconds(200))
        task.cancel()
        let error = await task.value
        #expect(error?.isCancelled == true)
        #expect(leftovers(m) == (false, false))
    }

    @Test func validDownloadIsInstalledAndLaterTamperingIsDetected() async throws {
        let body = Data((0 ..< 4000).map { UInt8($0 % 251) })
        let m = model(size: 4000, sha256: Self.sha256(body),
                      scenario: .init(contentLength: 4000, chunks: [body.prefix(2000), body.suffix(2000)]))
        #expect(await download(m) == nil)
        #expect(storage.isInstalled(m))
        #expect(leftovers(m) == (false, true))

        // 読み込む前の確認: 一致すれば通り、同じ大きさのまま書き換えると止める
        try await storage.verifyContents(of: m)
        let url = storage.fileURL(for: m.files[0], of: m)
        var tampered = body
        tampered[100] ^= 0xFF
        try tampered.write(to: url)
        #expect(storage.isInstalled(m), "大きさだけでは書き換えを見分けられない")
        await #expect(throws: WhisperBatchError.modelFileModified(modelName: m.displayName)) {
            try await storage.verifyContents(of: m)
        }
        // 元に戻せば（時刻は変わるので確かめ直して）通る
        try body.write(to: url)
        try await storage.verifyContents(of: m)
    }
}

@Suite("モデルのダウンロード: 再開時の受信量")
struct DownloadSizeLimitTests {
    @Test func resumedDownloadCountsOffsetWhetherOrNotTotalIncludesIt() {
        // totalBytesWritten が再開位置を含む場合
        var a = DownloadSizeLimit(limit: 1000)
        let v1 = a.resumed(at: 600, expectedTotal: 1000)
        #expect(v1)
        for total in stride(from: 700, through: 1000, by: 100) {
            let r = a.record(bytesWritten: 100, totalBytesWritten: Int64(total), totalBytesExpected: 1000)
            #expect(r.received == Int64(total) && r.withinLimit)
        }
        let v2 = a.record(bytesWritten: 100, totalBytesWritten: 1100, totalBytesExpected: 1000).withinLimit
        #expect(!v2)

        // totalBytesWritten が今回の分だけの場合（応答の大きさは残りの分）
        var b = DownloadSizeLimit(limit: 1000)
        let v3 = b.resumed(at: 600, expectedTotal: 1000)
        #expect(v3)
        for total in stride(from: 100, through: 400, by: 100) {
            let r = b.record(bytesWritten: 100, totalBytesWritten: Int64(total), totalBytesExpected: 400)
            #expect(r.received == 600 + Int64(total) && r.withinLimit)
        }
        let v4 = b.record(bytesWritten: 100, totalBytesWritten: 500, totalBytesExpected: 400).withinLimit
        #expect(!v4)
    }

    @Test func rejectsResumeBeyondLimit() {
        var a = DownloadSizeLimit(limit: 1000)
        let v5 = a.resumed(at: 1200, expectedTotal: 1000)
        #expect(!v5)
        var b = DownloadSizeLimit(limit: 1000)
        let v6 = b.resumed(at: 0, expectedTotal: 5000)
        #expect(!v6)
        var c = DownloadSizeLimit(limit: 1000)
        let v7 = c.record(bytesWritten: 10, totalBytesWritten: 10, totalBytesExpected: 1001).withinLimit
        #expect(!v7)
        // 大きさが分からない応答（-1）は受信量だけで判断する
        let v8 = c.record(bytesWritten: 10, totalBytesWritten: 20, totalBytesExpected: -1).withinLimit
        #expect(v8)
    }
}
