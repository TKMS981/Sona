import CryptoKit
import Foundation
import Testing
import WhisperBatchCore
@testable import WhisperBatchEngine

// 動画の MP3 変換。WHISPER_BATCH_TEST_AUDIO_DIR（scripts/make-test-audio.sh で作成）が必要。
// 認識まで確かめるテストは WHISPER_BATCH_TEST_MODEL も必要。

private let env = ProcessInfo.processInfo.environment
private let audioDir = env["WHISPER_BATCH_TEST_AUDIO_DIR"].map { URL(fileURLWithPath: $0) }
private let modelPath = env["WHISPER_BATCH_TEST_MODEL"].map { URL(fileURLWithPath: $0) }
private func media(_ name: String) -> URL { audioDir!.appendingPathComponent(name) }

private func sha256(_ url: URL) throws -> String {
    SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
}

private func tempMP3() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("wb-test-\(UUID().uuidString).mp3")
}

@Suite("動画の MP3 変換", .enabled(if: audioDir != nil))
struct VideoConversionTests {
    init() { TestLocalization.setUp() }

    /// macOS（AVFoundation）で読めることを確認した動画の組み合わせ
    @Test(arguments: ["ja1.mp4", "ja1_hevc.mp4", "ja1.mov", "ja1_alac.mov", "ja1_pcm.mov", "ja1_prores.mov",
                      "ja1.m4v", "ja1.3gp", "ja1.mpg", "ja1.ts"])
    func convertsVideoAudioToMP3(file: String) async throws {
        let source = media(file)
        let before = try sha256(source)
        let info = try await MediaInspector.inspect(source)
        #expect(info.kind == .video)
        #expect(abs(info.duration - 7.68) < 0.3)

        let out = tempMP3()
        defer { try? FileManager.default.removeItem(at: out) }
        try await MP3Converter.convert(source: source, destination: out, progress: { _ in })
        // 出力は MP3 として読める音声で、長さが元と同じ
        let mp3 = try await MediaInspector.inspect(out)
        #expect(mp3.kind == .audio)
        #expect(abs(mp3.duration - info.duration) < 0.3)
        let header = try FileHandle(forReadingFrom: out).read(upToCount: 2) ?? Data()
        #expect(header.count == 2 && header[0] == 0xFF && (header[1] & 0xE0) == 0xE0, "MPEG フレーム同期で始まる")
        // 元の動画は変わらない
        #expect(try sha256(source) == before)
    }

    @Test func audioFilesAreNotTreatedAsVideo() async throws {
        #expect(try await MediaInspector.inspect(media("ja1.m4a")).kind == .audio)
        #expect(try await MediaInspector.inspect(media("ja1.wav")).kind == .audio)
    }

    @Test(arguments: ["ja1.mkv", "ja1_video.webm", "ja1.avi"])
    func unreadableVideosFailClearly(file: String) async {
        do {
            _ = try await MediaInspector.inspect(media(file))
            Issue.record("\(file) は読み込めないはず")
        } catch let error as WhisperBatchError {
            #expect(error.errorDescription?.contains(file) == true)
        } catch {
            Issue.record("WhisperBatchError ではない: \(error)")
        }
    }

    @Test func videoWithoutAudio() async {
        await #expect(throws: WhisperBatchError.videoHasNoAudio(name: "silent.mp4")) {
            _ = try await MediaInspector.inspect(media("silent.mp4"))
        }
        let out = tempMP3()
        await #expect(throws: WhisperBatchError.videoHasNoAudio(name: "silent.mp4")) {
            try await MP3Converter.convert(source: media("silent.mp4"), destination: out, progress: { _ in })
        }
        #expect(!FileManager.default.fileExists(atPath: out.path))
    }

    @Test func missingSourceIsReportedAsNotFound() async {
        await #expect(throws: WhisperBatchError.fileNotFound(name: "nothing.mp4")) {
            try await MP3Converter.convert(source: media("nothing.mp4"), destination: tempMP3(), progress: { _ in })
        }
    }

    /// 途中でキャンセルすると、書きかけの MP3 は残らない
    @Test func cancellationRemovesPartialFile() async throws {
        let out = tempMP3()
        let progress = Recorder()
        let task = Task {
            try await MP3Converter.convert(source: media("long.mp4"), destination: out, progress: { progress.set($0) })
        }
        while progress.value < 0.05 { try await Task.sleep(for: .milliseconds(10)) }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(!FileManager.default.fileExists(atPath: out.path))
    }

    /// 空き容量が足りない場所へは書き出さない（WB_SMALL_VOLUME に小さいボリュームのパスを指定したときだけ）
    @Test(.enabled(if: env["WB_SMALL_VOLUME"] != nil))
    func insufficientDiskSpace() async {
        let out = URL(fileURLWithPath: env["WB_SMALL_VOLUME"]!).appendingPathComponent("out.mp3")
        do {
            try await MP3Converter.convert(source: media("long.mp4"), destination: out, progress: { _ in })
            Issue.record("容量不足になるはず")
        } catch let error as WhisperBatchError {
            if case .insufficientDiskSpace = error {} else { Issue.record("想定外のエラー: \(error)") }
        } catch {
            Issue.record("想定外のエラー: \(error)")
        }
        #expect(!FileManager.default.fileExists(atPath: out.path))
    }

    /// 動画から音声を直接読み出して文字起こしできる（アプリの処理と同じ。対応している動画の形式すべて）
    @Test(.enabled(if: modelPath != nil))
    func transcribesVideoDirectly() async throws {
        let url = try #require(modelPath)
        let model = ModelCatalog.all.first { $0.files.first?.name == url.lastPathComponent } ?? ModelCatalog.all[0]
        let ctx = try await WhisperContext.load(model: model, fileURL: url)
        for file in ["ja1.mp4", "ja1_hevc.mp4", "ja1.mov", "ja1_alac.mov", "ja1_pcm.mov", "ja1_prores.mov",
                     "ja1.m4v", "ja1.3gp", "ja1.mpg", "ja1.ts"] {
            let progress = Recorder()
            let t = try await TranscriptionEngine.transcribe(fileURL: media(file), context: ctx, options: .init(language: .japanese),
                                                             progress: { progress.set($0) })
            let text = TranscriptFormatter.plainText(t)
            print("video \(file):", text)
            #expect(text.contains("晴天") || text.contains("テスト"), "\(file)")
            #expect(progress.value == 1, "\(file)")
        }
    }

    /// 動画を直接読み出して短いチャンクに分けても、各文が欠けず二重にもならないこと（音声ファイルの同じテストの動画版）
    @Test(.enabled(if: modelPath != nil), arguments: [30.0, 45.0])
    func chunkedLongVideoHasNoGapsOrDuplicates(chunk: Double) async throws {
        let url = try #require(modelPath)
        let model = ModelCatalog.all.first { $0.files.first?.name == url.lastPathComponent } ?? ModelCatalog.all[0]
        let ctx = try await WhisperContext.load(model: model, fileURL: url)
        let planner = ChunkPlanner(chunkDuration: chunk, tailMargin: 3)
        let t = try await TranscriptionEngine.transcribe(fileURL: media("long.mp4"), context: ctx,
                                                         options: .init(language: .japanese, planner: planner), progress: { _ in })
        for (a, b) in zip(t.segments, t.segments.dropFirst()) {
            #expect(b.start >= a.start - 0.01)
        }
        let text = TranscriptFormatter.plainText(t)
        // 「一番目」のように漢数字で出ることもあるため、漢数字も数える（文が出ていれば欠落ではない）
        let numbers = text.matches(of: /([0-9]+|[一二三四五六七八九十]+)\s*番目/).compactMap { number(String($0.1)) }
        let counts = Dictionary(numbers.map { ($0, 1) }, uniquingKeysWith: +)
        let duplicated = counts.filter { $0.value > 1 }.keys.sorted()
        let missing = (1 ... 40).filter { counts[$0] == nil }
        print("long video (chunk \(chunk)s) duplicated:", duplicated, "missing:", missing)
        #expect(duplicated.isEmpty)
        #expect(missing.count <= 2)
    }
}

/// 算用数字か漢数字（九十九まで）を数にする
private func number(_ text: String) -> Int? {
    if let n = Int(text) { return n }
    let digits: [Character: Int] = ["一": 1, "二": 2, "三": 3, "四": 4, "五": 5, "六": 6, "七": 7, "八": 8, "九": 9]
    let parts = text.split(separator: "十", omittingEmptySubsequences: false)
    switch parts.count {
    case 1: return text.count == 1 ? digits[text.first!] : nil
    case 2:
        let tens = parts[0].isEmpty ? 1 : (parts[0].count == 1 ? digits[parts[0].first!] : nil)
        let ones = parts[1].isEmpty ? 0 : (parts[1].count == 1 ? digits[parts[1].first!] : nil)
        guard let tens, let ones else { return nil }
        return tens * 10 + ones
    default: return nil
    }
}

private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = 0.0
    func set(_ v: Double) { lock.lock(); _value = v; lock.unlock() }
    var value: Double { lock.lock(); defer { lock.unlock() }; return _value }
}
