import AVFoundation
import CoreGraphics
import Foundation
import ScreenCaptureKit
import Synchronization
import WhisperBatchCore

/// 入力から届く知らせ
public enum LiveSourceEvent: Equatable, Sendable {
    /// 取り込みが止まった（理由つき）
    case stopped(LiveSourceStopReason)
    /// 使うマイクが切り替わった（新しい機器名）
    case switchedDevice(String)
}

public enum LiveSourceStopReason: Equatable, Sendable {
    /// 対象のアプリやウィンドウがなくなった
    case targetClosed
    /// macOS のメニュー（画面共有の表示など）から停止された
    case stoppedBySystem
    /// マイクが外された・使えなくなった
    case deviceLost
    case failed(String)
}

/// 入力から届いた音声と知らせを受け取る。入力はそれぞれのスレッドから呼び、セッションが定期的にまとめて取り出す。
public final class LiveAudioSink: Sendable {
    public static let sampleRate: Double = 16_000

    struct Drained {
        var samples: [Float]
        var levels: [LiveInputKind: Float]
        var events: [(LiveInputKind, LiveSourceEvent)]
        var droppedFrames: Int
    }

    private struct State {
        var mixer = AudioMixer<LiveInputKind>(sampleRate: LiveAudioSink.sampleRate)
        var levels: [LiveInputKind: Float] = [:]
        var events: [(LiveInputKind, LiveSourceEvent)] = []
        var reportedDrops = 0
    }

    private let state = Mutex(State())

    public init() {}

    /// 16kHz モノラルの音声を足す
    public func push(_ samples: [Float], from kind: LiveInputKind) {
        guard !samples.isEmpty else { return }
        var sum: Float = 0
        for s in samples { sum += s * s }
        let rms = sqrt(sum / Float(samples.count))
        state.withLock { s in
            s.mixer.append(samples, to: kind)
            // 表示用のレベルは、上がるときはすぐに、下がるときはゆっくり追う
            let previous = s.levels[kind] ?? 0
            s.levels[kind] = rms > previous ? rms : max(rms, previous * 0.85)
        }
    }

    public func report(_ event: LiveSourceEvent, from kind: LiveInputKind) {
        state.withLock { $0.events.append((kind, event)) }
    }

    func setInputs(_ kinds: Set<LiveInputKind>) {
        state.withLock { s in
            s.mixer.setInputs(kinds)
            for key in s.levels.keys where !kinds.contains(key) { s.levels[key] = nil }
        }
    }

    func drain() -> Drained {
        state.withLock { s in
            let samples = s.mixer.drain()
            let dropped = s.mixer.droppedFrames - s.reportedDrops
            s.reportedDrops = s.mixer.droppedFrames
            let events = s.events
            s.events = []
            return Drained(samples: samples, levels: s.levels, events: events, droppedFrames: dropped)
        }
    }
}

/// 音声の入力（画面の音声・マイク。テストでは差し替える）
@MainActor
public protocol LiveAudioSource: AnyObject {
    var kind: LiveInputKind { get }
    /// 取り込みを始める。音声と知らせは `sink` に届ける。一時停止後にもう一度呼ばれることがある。
    func start(sink: LiveAudioSink) async throws
    /// 取り込みを止める（既に止まっていても呼んでよい）
    func stop() async
}

// MARK: - 画面の音声（ScreenCaptureKit）

/// 利用者が選んだウィンドウまたは画面の音声を取り込む。映像は使わない（最小の大きさ・頻度にする）。
///
/// macOS 27.2 で確かめた動き:
/// - ウィンドウを選んでも、そのウィンドウを持つアプリ全体の音声が届く（同じアプリの別ウィンドウの音も入る）。
///   ほかのアプリの音は入らない。
/// - 選んだウィンドウを閉じても、アプリが動いている間は音声が届き続ける（エラーにならない）。
///   そのため、ウィンドウの有無は `WindowPresence` で別に確かめる。アプリが終了すると -3815 で止まる。
/// - 画面を選ぶと、ウィンドウのないアプリを含むすべてのアプリの音声が届く。このアプリ自身の音は除く。
@MainActor
public final class ScreenAudioSource: NSObject, LiveAudioSource {
    public let kind: LiveInputKind
    private let filter: SCContentFilter
    private var stream: SCStream?
    private var output: StreamOutput?

    public init(kind: LiveInputKind, filter: SCContentFilter) {
        self.kind = kind
        self.filter = filter
    }

    public func start(sink: LiveAudioSink) async throws {
        await stop()
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = Int(LiveAudioSink.sampleRate)
        config.channelCount = 1
        // 映像は使わないので、最小の大きさと頻度にする（ScreenCaptureKit は映像を止められない）
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.showsCursor = false
        config.queueDepth = 3

        let output = StreamOutput(kind: kind, sink: sink)
        let stream = SCStream(filter: filter, configuration: config, delegate: output)
        do {
            try stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: output.queue)
            try await stream.startCapture()
        } catch {
            throw Self.mapStartError(error)
        }
        self.stream = stream
        self.output = output
    }

    public func stop() async {
        guard let stream else { return }
        self.stream = nil
        output?.isStopping.store(true, ordering: .relaxed)
        output = nil
        // 既に止まっている（対象が閉じたなど）場合のエラーは無視する
        try? await stream.stopCapture()
    }

    nonisolated static func mapStartError(_ error: any Error) -> LiveCaptureError {
        let ns = error as NSError
        if ns.domain == SCStreamErrorDomain, ns.code == SCStreamError.Code.userDeclined.rawValue {
            return .screenCaptureDenied
        }
        return .screenCaptureFailed(detail: ns.localizedDescription)
    }

    nonisolated static func stopReason(for error: any Error) -> LiveSourceStopReason {
        let ns = error as NSError
        guard ns.domain == SCStreamErrorDomain else { return .failed(ns.localizedDescription) }
        switch SCStreamError.Code(rawValue: ns.code) {
        case .noCaptureSource, .noWindowList, .noDisplayList: return .targetClosed
        case .userStopped, .systemStoppedStream: return .stoppedBySystem
        case .userDeclined: return .failed(LiveCaptureError.screenCaptureDenied.localizedDescription)
        default: return .failed(ns.localizedDescription)
        }
    }

    /// ScreenCaptureKit のコールバックを受ける（専用のキューで呼ばれる）
    private final class StreamOutput: NSObject, SCStreamOutput, SCStreamDelegate, Sendable {
        let kind: LiveInputKind
        let sink: LiveAudioSink
        let queue = DispatchQueue(label: "WhisperBatch.live.screen", qos: .userInitiated)
        let isStopping = Atomic<Bool>(false)
        private let resampler = Mutex<MonoResampler?>(nil)

        init(kind: LiveInputKind, sink: LiveAudioSink) {
            self.kind = kind
            self.sink = sink
        }

        func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
            guard type == .audio, sampleBuffer.isValid, let pcm = Self.pcmBuffer(from: sampleBuffer) else { return }
            let samples = resampler.withLock { r -> [Float] in
                if r == nil || r?.inputFormat != pcm.format { r = MonoResampler(input: pcm.format) }
                return r?.convert(pcm) ?? []
            }
            sink.push(samples, from: kind)
        }

        func stream(_ stream: SCStream, didStopWithError error: any Error) {
            guard !isStopping.load(ordering: .relaxed) else { return }
            sink.report(.stopped(ScreenAudioSource.stopReason(for: error)), from: kind)
        }

        static func pcmBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
            guard let description = sampleBuffer.formatDescription,
                  let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description) else { return nil }
            var streamDescription = asbd.pointee
            let frames = CMSampleBufferGetNumSamples(sampleBuffer)
            guard frames > 0,
                  let format = AVAudioFormat(streamDescription: &streamDescription),
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else { return nil }
            buffer.frameLength = AVAudioFrameCount(frames)
            let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
                sampleBuffer, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList)
            return status == noErr ? buffer : nil
        }
    }
}

// MARK: - マイク（AVAudioEngine）

/// macOS で入力に選ばれているマイクの音声を取り込む。
/// マイクが外されたり切り替わったりしたら、新しい入力で取り込み直す。入力がなくなったら止まったことを知らせる。
@MainActor
public final class MicrophoneSource: LiveAudioSource {
    public let kind: LiveInputKind = .microphone
    private var engine: AVAudioEngine?
    private var sink: LiveAudioSink?
    private var observer: (any NSObjectProtocol)?

    public init() {}

    /// 今の入力機器の名前（なければ nil）
    public static var currentDeviceName: String? {
        AVCaptureDevice.default(for: .audio)?.localizedName
    }

    public func start(sink: LiveAudioSink) async throws {
        await stop()
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .denied, .restricted: throw LiveCaptureError.microphoneDenied
        default: break
        }
        self.sink = sink
        try startEngine()
    }

    public func stop() async {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil
        sink = nil
    }

    private func startEngine() throws {
        guard let sink else { return }
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw LiveCaptureError.microphoneUnavailable }
        let resampler = MonoResampler(input: format)
        let kind = kind
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            sink.push(resampler.convert(buffer), from: kind)
        }
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw LiveCaptureError.microphoneFailed(detail: (error as NSError).localizedDescription)
        }
        self.engine = engine
        // 入力機器の変更（外された・別の機器が選ばれた）でエンジンが止まったら、取り込み直す
        observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.restartAfterDeviceChange() }
        }
    }

    private func restartAfterDeviceChange() {
        guard let sink, let old = engine else { return }
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        old.inputNode.removeTap(onBus: 0)
        old.stop()
        engine = nil
        do {
            try startEngine()
            sink.report(.switchedDevice(Self.currentDeviceName ?? ""), from: kind)
        } catch {
            self.sink = nil
            sink.report(.stopped(.deviceLost), from: kind)
        }
    }
}

// MARK: - 変換

/// 任意の PCM を 16kHz モノラル Float32 にする。複数チャンネルは平均してまとめる。
final class MonoResampler: @unchecked Sendable {
    let inputFormat: AVAudioFormat
    private let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: LiveAudioSink.sampleRate,
                                             channels: 1, interleaved: false)!
    private let converter: AVAudioConverter?

    init(input: AVAudioFormat) {
        inputFormat = input
        if input.commonFormat == .pcmFormatFloat32, input.sampleRate == LiveAudioSink.sampleRate, input.channelCount == 1 {
            converter = nil
        } else {
            converter = AVAudioConverter(from: input, to: outputFormat)
            converter?.downmix = true
        }
    }

    /// 1 つのスレッドから順に呼ぶ（変換器は前の呼び出しの続きとして処理する）
    func convert(_ buffer: AVAudioPCMBuffer) -> [Float] {
        guard buffer.frameLength > 0 else { return [] }
        guard let converter else {
            guard let data = buffer.floatChannelData else { return [] }
            return Array(UnsafeBufferPointer(start: data[0], count: Int(buffer.frameLength)))
        }
        let ratio = LiveAudioSink.sampleRate / inputFormat.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return [] }
        final class Supply: @unchecked Sendable { var buffer: AVAudioPCMBuffer? }
        let supply = Supply()
        supply.buffer = buffer
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, outStatus in
            guard let next = supply.buffer else {
                outStatus.pointee = .noDataNow
                return nil
            }
            supply.buffer = nil
            outStatus.pointee = .haveData
            return next
        }
        guard status != .error, let data = out.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: data[0], count: Int(out.frameLength)))
    }
}

// MARK: - ウィンドウの有無

/// 選んだウィンドウがまだあるか。画面収録の許可がなくても、ウィンドウの番号と表示状態は分かる。
public enum WindowPresence: Equatable, Sendable {
    /// 画面に表示されている
    case visible
    /// あるが表示されていない（最小化・非表示・閉じられたが破棄されていない）
    case notVisible
    /// なくなった
    case gone

    public static func of(_ windowID: CGWindowID) -> WindowPresence {
        guard let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], windowID) as? [[String: Any]],
              let info = list.first(where: { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == windowID })
        else { return .gone }
        return (info[kCGWindowIsOnscreen as String] as? Bool) == true ? .visible : .notVisible
    }
}
