import Foundation

/// 複数の入力（画面の音声とマイク）を 1 本の音声にまとめる。入力はどれも同じサンプルレートのモノラル。
///
/// 入力ごとに届いた分をためておき、すべての入力にある分だけを足し合わせて取り出す。
/// ある入力が `maxLag` 以上遅れている（届かない）ときは、その入力を無音とみなして先へ進める。
/// ためておく量は入力ごとに `capacity` までで、超えた分は古い方から捨てる。
public struct AudioMixer<Input: Hashable & Sendable>: Sendable {
    public let maxLag: Int
    public let capacity: Int
    private var buffers: [Input: [Float]] = [:]
    /// 上限を超えて捨てたサンプルの合計
    public private(set) var droppedFrames = 0

    public init(sampleRate: Double, maxLag: TimeInterval = 0.5, capacity: TimeInterval = 10) {
        self.maxLag = max(Int(maxLag * sampleRate), 1)
        self.capacity = max(Int(capacity * sampleRate), self.maxLag)
    }

    public var inputs: Set<Input> { Set(buffers.keys) }

    /// 使う入力を決める。外した入力のためていた分は捨てる。
    public mutating func setInputs(_ inputs: Set<Input>) {
        for key in buffers.keys where !inputs.contains(key) { buffers[key] = nil }
        for key in inputs where buffers[key] == nil { buffers[key] = [] }
    }

    /// 入力の音声を足す（使っていない入力の音声は無視する）
    public mutating func append(_ samples: [Float], to input: Input) {
        guard buffers[input] != nil else { return }
        buffers[input]!.append(contentsOf: samples)
        let over = buffers[input]!.count - capacity
        if over > 0 {
            buffers[input]!.removeFirst(over)
            droppedFrames += over
        }
    }

    /// 取り出せる分を足し合わせて返す（-1...1 に収める）
    public mutating func drain() -> [Float] {
        guard let longest = buffers.values.map(\.count).max(), longest > 0 else { return [] }
        // 大きく遅れている入力は、遅れの上限まで無音で埋める
        let floor = longest - maxLag
        for key in buffers.keys where buffers[key]!.count < floor {
            buffers[key]!.append(contentsOf: repeatElement(0, count: floor - buffers[key]!.count))
        }
        let n = buffers.values.map(\.count).min() ?? 0
        guard n > 0 else { return [] }
        if buffers.count == 1, let key = buffers.keys.first {
            let out = Array(buffers[key]![..<n])
            buffers[key]!.removeFirst(n)
            return out
        }
        var out = [Float](repeating: 0, count: n)
        for key in buffers.keys {
            buffers[key]!.withUnsafeBufferPointer { src in
                for i in 0 ..< n { out[i] += src[i] }
            }
            buffers[key]!.removeFirst(n)
        }
        for i in 0 ..< n { out[i] = Self.limit(out[i]) }
        return out
    }

    /// 足し合わせて大きくなった音を -1...1 に収める。`knee` までの音はそのまま通し、
    /// それを超える部分だけをなめらかに圧縮する（単純に切り詰めると波形が角張って音が割れ、認識が乱れるため）。
    static func limit(_ x: Float, knee: Float = 0.8) -> Float {
        let a = abs(x)
        guard a > knee else { return x }
        let room = 1 - knee
        let y = knee + room * tanh((a - knee) / room)
        return x < 0 ? -y : y
    }

    /// ためている量（サンプル数、入力ごとの最大）
    public var pendingFrames: Int { buffers.values.map(\.count).max() ?? 0 }
}

/// 音声に発話（ある程度の大きさの音）が含まれるかを、音量だけで簡易に判定する。
///
/// Whisper は無音や小さな雑音から文章を作ってしまうことがあるため、発話がない音声は認識に渡さない。
public struct VoiceActivityDetector: Sendable, Equatable {
    /// 音量を測る単位（秒）
    public var frameDuration: TimeInterval
    /// これより小さい音（RMS、約 -50 dBFS）は常に無音とみなす
    public var absoluteFloor: Float
    /// 発話とみなすのに必要な連続した長さ（秒）。クリック音などを除くため。
    public var minSpeech: TimeInterval
    /// `pauses` に含める無音の最小の長さ（秒）
    public var minPause: TimeInterval
    /// `gaps` に含める短い間の最小の長さ（秒）
    public var gapMinimum: TimeInterval = 0.15

    public init(frameDuration: TimeInterval = 0.02, absoluteFloor: Float = 0.003, minSpeech: TimeInterval = 0.1,
                minPause: TimeInterval = 0.3) {
        self.frameDuration = frameDuration
        self.absoluteFloor = absoluteFloor
        self.minSpeech = minSpeech
        self.minPause = minPause
    }

    public struct Analysis: Equatable, Sendable {
        /// 発話が含まれる
        public var hasSpeech: Bool
        /// 末尾に続く無音の長さ（秒）
        public var trailingSilence: TimeInterval
        /// `minPause` 秒以上続く無音の範囲（秒、昇順。末尾まで続く無音を含む）。
        /// 周りより静かな部分を含む（音楽の静かな部分も入りうる）ので、話の切れ目の候補として使う。
        public var pauses: [ClosedRange<TimeInterval>]
        /// `minPause` 秒以上続く、ほとんど音のない範囲（秒、昇順）。
        /// 背景の雑音と同じくらいの大きさか、それより小さい部分だけ。ここで認識された文は無音から作られた誤認識とみなす。
        public var silences: [ClosedRange<TimeInterval>]
        /// `gapMinimum` 秒以上続く、周りより静かな部分（話の切れ目より短い、文と文や話者の間の短い間）
        public var gaps: [ClosedRange<TimeInterval>]
        /// 音量の最大値（RMS、0...1。入力レベルの表示用）
        public var peakLevel: Float
        /// フレームごとの平均二乗振幅（`frameSeconds` 秒ごと）
        public var framePower: [Float]
        public var frameSeconds: TimeInterval

        public init(hasSpeech: Bool, trailingSilence: TimeInterval, pauses: [ClosedRange<TimeInterval>],
                    silences: [ClosedRange<TimeInterval>] = [], gaps: [ClosedRange<TimeInterval>]? = nil,
                    peakLevel: Float, framePower: [Float] = [], frameSeconds: TimeInterval = 0.02) {
            self.hasSpeech = hasSpeech
            self.trailingSilence = trailingSilence
            self.pauses = pauses
            self.silences = silences
            self.gaps = gaps ?? pauses
            self.peakLevel = peakLevel
            self.framePower = framePower
            self.frameSeconds = frameSeconds
        }

        /// range の中で最も静かな位置（秒）。0.1 秒の幅で平均した音量が最も小さいところの中央。
        /// 同じくらい静かなら前の方を選ぶ。フレームの情報がなければ nil。
        public func quietestTime(in range: ClosedRange<TimeInterval>) -> TimeInterval? {
            guard !framePower.isEmpty, frameSeconds > 0 else { return nil }
            let lower = max(Int((range.lowerBound / frameSeconds).rounded(.down)), 0)
            let upper = min(Int((range.upperBound / frameSeconds).rounded(.up)), framePower.count - 1)
            guard upper >= lower else { return nil }
            let half = 2 // 前後 2 フレーム（約 0.1 秒）で平均する
            var best = lower
            var bestPower = Float.greatestFiniteMagnitude
            for f in lower ... upper {
                let a = max(f - half, 0), b = min(f + half, framePower.count - 1)
                var sum: Float = 0
                for i in a ... b { sum += framePower[i] }
                let mean = sum / Float(b - a + 1)
                if mean < bestPower * 0.999 {
                    bestPower = mean
                    best = f
                }
            }
            let t = (Double(best) + 0.5) * frameSeconds
            return min(max(t, range.lowerBound), range.upperBound)
        }
    }

    public func analyze(_ samples: [Float], sampleRate: Double) -> Analysis {
        let frame = max(Int(frameDuration * sampleRate), 1)
        let frameCount = samples.count / frame
        guard frameCount > 0 else {
            let d = Double(samples.count) / sampleRate
            let all: [ClosedRange<TimeInterval>] = d > 0 ? [0 ... d] : []
            return Analysis(hasSpeech: false, trailingSilence: d, pauses: all, silences: all, peakLevel: 0,
                            frameSeconds: frameDuration)
        }
        var power = [Float](repeating: 0, count: frameCount)
        samples.withUnsafeBufferPointer { buf in
            for f in 0 ..< frameCount {
                var sum: Float = 0
                for i in f * frame ..< (f + 1) * frame { sum += buf[i] * buf[i] }
                power[f] = sum / Float(frame)
            }
        }
        // 相対的な基準（静かな部分より大きい音）と、絶対的な下限の両方を超えたフレームを音ありとする
        let relativeSilence = UtteranceSplitter.silenceFlags(power)
        let floorPower = absoluteFloor * absoluteFloor
        let voiced = (0 ..< frameCount).map { !relativeSilence[$0] && power[$0] > floorPower }

        let needed = max(Int((minSpeech / frameDuration).rounded()), 1)
        var run = 0
        var hasSpeech = false
        for v in voiced {
            run = v ? run + 1 : 0
            if run >= needed { hasSpeech = true; break }
        }
        let trailingFrames = voiced.reversed().prefix { !$0 }.count
        let tail = Double(samples.count - frameCount * frame) / sampleRate
        let frameSeconds = Double(frame) / sampleRate
        let total = Double(samples.count) / sampleRate

        // 無音の続く範囲（末尾の端数は無音とみなす）
        func ranges(minimum: TimeInterval? = nil, _ isQuiet: (Int) -> Bool) -> [ClosedRange<TimeInterval>] {
            let minimum = minimum ?? minPause
            var result: [ClosedRange<TimeInterval>] = []
            var runStart: Int?
            for f in 0 ... frameCount {
                let quiet = f < frameCount && isQuiet(f)
                if quiet, runStart == nil { runStart = f }
                if !quiet, let start = runStart {
                    let lower = Double(start) * frameSeconds
                    let upper = f == frameCount ? total : Double(f) * frameSeconds
                    if upper - lower >= minimum { result.append(lower ... upper) }
                    runStart = nil
                }
            }
            return result
        }
        let pauses = ranges { !voiced[$0] }
        // ほとんど音のない部分: 背景の雑音（静かな方から 10% の位置）の 4 倍（+6dB）以下で、かつ最も大きい部分より
        // 20dB 以上小さいところ。どちらにも当たらないほど小さい音（絶対的な下限以下）も含める。
        // 音楽の静かな部分や小さな声は、周りより静かでもここには入らない。
        let sorted = power.sorted()
        let noise = sorted[sorted.count / 10]
        let loud = sorted[min(sorted.count * 99 / 100, sorted.count - 1)]
        let deep = max(min(noise * 4, loud * 0.01), floorPower)
        let silences = ranges { !voiced[$0] && power[$0] <= deep }
        let gaps = ranges(minimum: gapMinimum) { !voiced[$0] }
        return Analysis(
            hasSpeech: hasSpeech,
            trailingSilence: Double(trailingFrames) * frameSeconds + tail,
            pauses: pauses,
            silences: silences,
            gaps: gaps,
            peakLevel: sqrt(power.max() ?? 0),
            framePower: power,
            frameSeconds: frameSeconds
        )
    }
}
