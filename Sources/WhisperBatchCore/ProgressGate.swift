import Synchronization

/// 進捗の通知を間引く（画面の更新のための通知だけ。処理そのものには関わらない）。
///
/// 変換や認識の進捗は音声のまとまりごとに届き、1 秒に数百回になることがある。通知のたびにメインアクターへ移って
/// キューを書き換えると、そのたびに画面が描き直される。前に通した値から `step` 以上進んだときと、
/// 最初の値・完了（1）だけを通す。値が戻るもの（前の値以下）は通さない（表示も戻さないため）。
public final class ProgressGate: Sendable {
    /// 通す最小の進み（0.002 = 0.2%。表示の幅が 500 ピクセルでも 1 ピクセル未満）
    public static let defaultStep = 0.002

    private let step: Double
    private let last = Mutex<Double>(-1)

    public init(step: Double = ProgressGate.defaultStep) {
        self.step = step
    }

    /// この値を通すか（通すなら、次からはこの値を基準にする）
    public func pass(_ value: Double) -> Bool {
        last.withLock { previous in
            guard value > previous else { return false }
            guard previous < 0 || value >= 1 || value - previous >= step else { return false }
            previous = value
            return true
        }
    }
}
