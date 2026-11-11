import Foundation

/// ライブ文字起こしの認識品質と遅れの記録（画面表示用）。測った値だけを使う。
///
/// - 確定までの遅れ: 話し終わり（区間の終わり）から、その区間が確定するまでの時間
/// - 認識 1 回の処理時間: Whisper が 1 回の認識にかかった時間（`LiveCommitPolicy.step` を超え続けると追いつかなくなる）
/// - 確からしさ: 確定した区間の、認識方式が返した確からしさの平均（返されないときは nil）
public struct LiveQualityMeter: Equatable, Sendable {
    /// 直近の何件で平均するか
    public static let window = 20

    public private(set) var latencies: [TimeInterval] = []
    public private(set) var processingTimes: [TimeInterval] = []
    public private(set) var confidences: [Double] = []

    public init() {}

    public mutating func recordRecognition(processingSeconds: TimeInterval) {
        guard processingSeconds.isFinite, processingSeconds >= 0 else { return }
        Self.push(processingSeconds, into: &processingTimes)
    }

    /// 新しく確定した区間を記録する
    /// - Parameter elapsed: 確定した時点の経過時間（セッションの時刻、秒）
    public mutating func recordConfirmed(_ segments: [TranscriptSegment], elapsed: TimeInterval) {
        for segment in segments {
            Self.push(max(elapsed - segment.end, 0), into: &latencies)
            if let c = segment.confidence, c.isFinite { Self.push(min(max(c, 0), 1), into: &confidences) }
        }
    }

    public struct Snapshot: Equatable, Sendable {
        public var lastLatency: TimeInterval?
        public var averageLatency: TimeInterval?
        public var maxLatency: TimeInterval?
        public var averageProcessing: TimeInterval?
        /// 確からしさの平均（認識方式が値を返さないときは nil）
        public var averageConfidence: Double?
    }

    public var snapshot: Snapshot {
        Snapshot(lastLatency: latencies.last,
                 averageLatency: Self.mean(latencies),
                 maxLatency: latencies.max(),
                 averageProcessing: Self.mean(processingTimes),
                 averageConfidence: Self.mean(confidences))
    }

    /// 全体の状態
    public enum Status: String, Equatable, Sendable {
        /// まだ確定した区間がない
        case measuring
        case good
        /// 確定までの遅れが大きい
        case delayed
        /// 認識が追いついていない（待っている音声がたまっている・取りこぼした）
        case behind
    }

    /// 遅れがこの秒数を超えたら「遅れ気味」
    public static let delayedThreshold: TimeInterval = 4
    /// 待っている音声がこの秒数以上なら「追いついていない」（画面の「認識が追いついていません」と同じ基準）
    public static let backlogThreshold: TimeInterval = 3

    /// - Parameters:
    ///   - backlog: まだ一度も認識していない音声（秒）
    ///   - recentlyDropped: 直近に取りこぼした音声がある
    public func status(backlog: TimeInterval, recentlyDropped: Bool) -> Status {
        if backlog >= Self.backlogThreshold || recentlyDropped { return .behind }
        guard let average = Self.mean(latencies) else { return .measuring }
        let processingTooSlow = (Self.mean(processingTimes) ?? 0) > Self.delayedThreshold
        return average > Self.delayedThreshold || processingTooSlow ? .delayed : .good
    }

    private static func push<T>(_ value: T, into array: inout [T]) {
        array.append(value)
        if array.count > window { array.removeFirst(array.count - window) }
    }

    private static func mean(_ values: [Double]) -> Double? {
        values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }
}
