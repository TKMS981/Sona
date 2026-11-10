import Foundation
import Testing
@testable import WhisperBatchCore

private func seg(_ start: Double, _ end: Double, _ text: String) -> TranscriptSegment {
    TranscriptSegment(start: start, end: end, text: text)
}

/// 指定した区間だけ音（正弦波）があり、ほかは無音の 16kHz の音声
private func speechLike(duration: Double, voiced: [ClosedRange<Double>], amplitude: Float = 0.3, rate: Double = 16_000) -> [Float] {
    var out = [Float](repeating: 0, count: Int(duration * rate))
    for range in voiced {
        let a = Int(range.lowerBound * rate), b = min(Int(range.upperBound * rate), out.count)
        for i in a ..< b { out[i] = amplitude * Float(sin(2 * Double.pi * 220 * Double(i) / rate)) }
    }
    return out
}

@Suite("ライブ文字起こし: 入力の選択")
struct LiveSourceSelectionTests {
    @Test func microphoneIsOffByDefault() {
        let s = LiveSourceSelection()
        #expect(s.microphone == false)
        #expect(s.window == true)
        #expect(s.system == false)
        #expect(s.screenInput == .window)
    }

    @Test func systemAudioCoversWindowAudio() {
        let s = LiveSourceSelection(window: true, system: true, microphone: true)
        #expect(s.screenInput == .system)
        #expect(s.windowIsCoveredBySystem)
        #expect(LiveSourceSelection(window: false, system: false, microphone: true).screenInput == nil)
        #expect(LiveSourceSelection(window: false, system: false, microphone: false).isEmpty)
    }
}

@Suite("ライブ文字起こし: 確定と暫定の決め方")
struct LiveCommitPolicyTests {
    let policy = LiveCommitPolicy()

    @Test func keepsEverythingProvisionalWhileSpeaking() {
        let d = policy.decide(segments: [seg(0, 2, "こんにちは")], windowDuration: 2.5, pauses: [], isFinal: false)
        #expect(d.confirmed.isEmpty)
        #expect(d.provisional.map(\.text) == ["こんにちは"])
        #expect(d.advance == 0)
    }

    @Test func confirmsAtAPause() {
        let d = policy.decide(segments: [seg(0, 1.5, "一文目。"), seg(1.6, 2.2, "二文目。")],
                              windowDuration: 3.2, pauses: [2.2 ... 3.2], isFinal: false)
        #expect(d.confirmed.map(\.text) == ["一文目。", "二文目。"])
        #expect(d.provisional.isEmpty)
        // 無音の一部（最大 0.3 秒）だけ残して捨てる
        #expect(abs(d.advance - 2.9) < 1e-9)
    }

    @Test func confirmsAtAPauseInTheMiddle() {
        let d = policy.decide(segments: [seg(0, 1.5, "一文目。"), seg(2.3, 3.0, "二文")],
                              windowDuration: 3.2, pauses: [1.5 ... 2.3], isFinal: false)
        #expect(d.confirmed.map(\.text) == ["一文目。"])
        #expect(d.provisional.map(\.text) == ["二文"])
        #expect(abs(d.advance - 1.9) < 1e-9)
    }

    @Test func doesNotCutThroughASegmentThatSpansThePause() {
        // Whisper が前後の文を 1 区間にまとめた場合、そこで区切ると後ろ半分の音声を失う
        let d = policy.decide(segments: [seg(0, 3.0, "一文目。二文目")],
                              windowDuration: 3.2, pauses: [1.0 ... 1.8], isFinal: false)
        #expect(d.confirmed.isEmpty)
        #expect(d.advance == 0)
        // 区切れる切れ目が前にあれば、そこまでで区切る
        let e = policy.decide(segments: [seg(0, 0.8, "はい"), seg(2.0, 5.0, "長い文")],
                              windowDuration: 5.2, pauses: [0.8 ... 1.9, 3.0 ... 3.8], isFinal: false)
        #expect(e.confirmed.map(\.text) == ["はい"])
        #expect(e.provisional.map(\.text) == ["長い文"])
        #expect(abs(e.advance - 1.35) < 1e-9)
    }

    @Test func wordStampedInsideThePauseIsReadAgainNotConfirmed() {
        // 「まず」の開始時刻が無音の中に置かれた。確定すると、残した音声からもう一度「まず」が出てしまう。
        let d = policy.decide(segments: [seg(0, 2.0, "始めます"), seg(2.6, 3.4, "まず")],
                              windowDuration: 3.6, pauses: [2.0 ... 3.2], isFinal: false)
        #expect(d.confirmed.map(\.text) == ["始めます"])
        #expect(d.provisional.map(\.text) == ["まず"])
        // 残す区間の始まりの 0.1 秒手前で区切る（頭の音を落とさない）
        #expect(abs(d.advance - 2.5) < 1e-9)
    }

    @Test func dropsTextMadeUpFromSilence() {
        let d = policy.decide(segments: [seg(0, 1.2, "最後に質問はありますか"), seg(1.6, 2.4, "はい")],
                              windowDuration: 3, pauses: [1.3 ... 3.0], isFinal: false)
        #expect(d.confirmed.map(\.text) == ["最後に質問はありますか"])
        let f = policy.decide(segments: [seg(0.5, 1.0, "はい")], windowDuration: 2, pauses: [0 ... 2], isFinal: true)
        #expect(f.confirmed.isEmpty)
    }

    @Test func shortPausesAreNotUsed() {
        let d = policy.decide(segments: [seg(0, 1, "a"), seg(1.4, 2, "b")], windowDuration: 2.1,
                              pauses: [1.0 ... 1.4], isFinal: false)
        #expect(d.confirmed.isEmpty)
    }

    @Test func confirmsOlderPartWhenTheWindowIsFull() {
        let segments = [seg(0, 6, "A"), seg(6, 12, "B"), seg(12, 18.5, "C"), seg(18.5, 20, "D")]
        let d = policy.decide(segments: segments, windowDuration: 20, pauses: [], isFinal: false)
        // 末尾 3 秒以内に終わる区間（C, D）は暫定に残し、C の頭から読み直す
        #expect(d.confirmed.map(\.text) == ["A", "B"])
        #expect(d.provisional.map(\.text) == ["C", "D"])
        #expect(d.advance == 12)
    }

    @Test func finalConfirmsEverything() {
        let d = policy.decide(segments: [seg(0, 1, "X"), seg(1, 2, " ")], windowDuration: 2, pauses: [], isFinal: true)
        #expect(d.confirmed.map(\.text) == ["X"])
        #expect(d.advance == 2)
    }

    @Test func silenceIsDroppedButTheLastSecondKept() {
        #expect(policy.silentAdvance(windowDuration: 5, isFinal: false) == 4)
        #expect(policy.silentAdvance(windowDuration: 0.5, isFinal: false) == 0)
        #expect(policy.silentAdvance(windowDuration: 5, isFinal: true) == 5)
    }

    @Test func transcriptShiftsSegmentsToSessionTime() {
        var t = LiveTranscript()
        t.apply(.init(confirmed: [seg(0, 1, "A")], provisional: [seg(1, 2, "B")]), windowStart: 10)
        #expect(t.confirmed == [seg(10, 11, "A")])
        #expect(t.provisional == [seg(11, 12, "B")])
        // 暫定は毎回置き換わる
        t.apply(.init(confirmed: [], provisional: [seg(0, 1, "B2")]), windowStart: 11)
        #expect(t.provisionalText == "B2")
        #expect(t.transcript.segments == [seg(10, 11, "A")])
        t.clearProvisional()
        #expect(t.provisional.isEmpty)
    }
}

extension LiveCommitPolicy.Decision {
    init(confirmed: [TranscriptSegment], provisional: [TranscriptSegment]) {
        self.init(confirmed: confirmed, provisional: provisional, advance: 0)
    }
}

@Suite("ライブ文字起こし: 音声のバッファと混合")
struct LiveAudioBufferTests {
    @Test func windowNeverExceedsItsCapacity() {
        var w = LiveAudioWindow(sampleRate: 100, capacity: 2)
        #expect(w.append([Float](repeating: 1, count: 150)) == 0)
        #expect(w.append([Float](repeating: 2, count: 100)) == 50)
        #expect(w.samples.count == 200)
        #expect(w.startFrame == 50)
        #expect(w.droppedFrames == 50)
        w.discard(before: 120)
        #expect(w.startFrame == 120)
        #expect(w.samples.count == 130)
        w.discard(before: 10) // 既に捨てた位置
        #expect(w.startFrame == 120)
        w.discardAll()
        #expect(w.samples.isEmpty)
        #expect(w.startFrame == 250)
    }

    @Test func singleInputPassesThrough() {
        var m = AudioMixer<LiveInputKind>(sampleRate: 100)
        m.setInputs([.window])
        m.append([0.1, 0.2, 0.3], to: .window)
        m.append([9], to: .microphone) // 使っていない入力は無視
        #expect(m.drain() == [0.1, 0.2, 0.3])
        #expect(m.drain().isEmpty)
    }

    @Test func twoInputsAreSummedAndLimitedSmoothly() {
        var m = AudioMixer<LiveInputKind>(sampleRate: 100)
        m.setInputs([.system, .microphone])
        m.append([0.5, 0.9, 0.1], to: .system)
        m.append([0.25, 0.9], to: .microphone)
        let out = m.drain()
        #expect(out.count == 2)
        #expect(out[0] == 0.75)                 // 小さい音は足し合わせたまま
        #expect(out[1] > 0.95 && out[1] < 1)    // 大きい音は 1 を超えないよう、なめらかに圧縮する
        m.append([0.2], to: .microphone)
        #expect(m.drain() == [0.3])
    }

    @Test func limiterIsMonotonicAndBounded() {
        var previous: Float = -2
        for i in 0 ... 400 {
            let x = Float(i) / 100 - 2  // -2...2
            let y = AudioMixer<LiveInputKind>.limit(x)
            #expect(y >= previous)
            #expect(abs(y) < 1)
            if abs(x) <= 0.8 { #expect(y == x) }
            previous = y
        }
    }

    @Test func laggingInputIsTreatedAsSilence() {
        var m = AudioMixer<LiveInputKind>(sampleRate: 100, maxLag: 0.1) // 10 サンプル
        m.setInputs([.system, .microphone])
        m.append([Float](repeating: 0.5, count: 30), to: .system)
        let out = m.drain()
        #expect(out.count == 20)
        #expect(out.allSatisfy { $0 == 0.5 })
        #expect(m.pendingFrames == 10)
    }

    @Test func bufferedAudioIsBounded() {
        var m = AudioMixer<LiveInputKind>(sampleRate: 100, maxLag: 0.1, capacity: 1)
        m.setInputs([.microphone])
        m.append([Float](repeating: 0.1, count: 250), to: .microphone)
        #expect(m.pendingFrames == 100)
        #expect(m.droppedFrames == 150)
        m.setInputs([])
        #expect(m.drain().isEmpty)
    }
}

@Suite("ライブ文字起こし: 発話の検出")
struct VoiceActivityTests {
    let vad = VoiceActivityDetector()

    @Test func digitalSilenceHasNoSpeech() {
        let a = vad.analyze([Float](repeating: 0, count: 32_000), sampleRate: 16_000)
        #expect(!a.hasSpeech)
        #expect(abs(a.trailingSilence - 2) < 0.03)
    }

    @Test func faintNoiseBelowTheFloorIsIgnored() {
        var rng = SystemRandomNumberGenerator()
        let noise = (0 ..< 32_000).map { _ in Float.random(in: -0.002 ... 0.002, using: &rng) }
        #expect(!vad.analyze(noise, sampleRate: 16_000).hasSpeech)
    }

    @Test func detectsSpeechAndTheTrailingPause() {
        let audio = speechLike(duration: 3, voiced: [0.5 ... 2.0])
        let a = vad.analyze(audio, sampleRate: 16_000)
        #expect(a.hasSpeech)
        #expect(abs(a.trailingSilence - 1.0) < 0.05)
        #expect(a.peakLevel > 0.1)
    }

    @Test func findsPausesBetweenUtterances() {
        let audio = speechLike(duration: 4, voiced: [0.5 ... 1.5, 2.5 ... 3.5])
        let pauses = vad.analyze(audio, sampleRate: 16_000).pauses
        #expect(pauses.count == 3)
        #expect(abs(pauses[1].lowerBound - 1.5) < 0.03)
        #expect(abs(pauses[1].upperBound - 2.5) < 0.03)
        #expect(abs(pauses[2].upperBound - 4.0) < 0.001)
    }

    @Test func shortClickIsNotSpeech() {
        let audio = speechLike(duration: 2, voiced: [1.0 ... 1.04])
        #expect(!vad.analyze(audio, sampleRate: 16_000).hasSpeech)
    }
}

@Suite("ライブ文字起こし: 長時間でも音声がたまり続けない")
struct LiveLongRunTests {
    /// 3 時間分を 0.1 秒ずつ流し、1 秒ごとに「認識」して確定させる。保持する音声が上限を超えないこと。
    @Test func windowStaysBoundedOverThreeHours() {
        let rate = 16_000.0
        let policy = LiveCommitPolicy()
        var window = LiveAudioWindow(sampleRate: rate, capacity: policy.hardLimit)
        var transcript = LiveTranscript()
        var lastRecognized = 0
        var maxHeld = 0
        let chunk = [Float](repeating: 0.1, count: 1600)
        for tick in 0 ..< 3 * 3600 * 10 {
            window.append(chunk)
            maxHeld = max(maxHeld, window.samples.count)
            guard window.endFrame - lastRecognized >= Int(policy.step * rate) else { continue }
            lastRecognized = window.endFrame
            // 5 秒ごとに話の切れ目がある想定
            let pause = (tick / 10) % 5 == 4 ? 0.8 : 0.0
            let d = window.duration
            let segments = d > 1 ? [seg(0, d - pause, "x")] : []
            let decision = policy.decide(segments: segments, windowDuration: d, pauses: pause > 0 ? [(d - pause) ... d] : [], isFinal: false)
            transcript.apply(decision, windowStart: window.startTime)
            window.discard(before: window.startFrame + Int(decision.advance * rate))
        }
        #expect(maxHeld <= Int(policy.hardLimit * rate))
        #expect(maxHeld <= Int((policy.maxWindow + policy.step) * rate) + 1600)
        #expect(window.droppedFrames == 0)
        #expect(transcript.confirmed.count > 1000)
    }
}

@Suite("ライブ文字起こし: 設定")
@MainActor
struct LiveSettingsTests {
    private let suiteName = "WhisperBatchLiveTests.\(UUID().uuidString)"
    private var defaults: UserDefaults { UserDefaults(suiteName: suiteName)! }

    @Test func ghostModeIsOffByDefaultAndPersists() {
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = SettingsStore(defaults: defaults)
        #expect(store.ghostMode == false)
        #expect(store.liveStopShortcut == .controlOptionCommandS)
        #expect(store.liveShowShortcut == .controlOptionCommandL)
        #expect(store.liveModel.engine == .whisper)
        store.ghostMode = true
        store.liveStopShortcut = .off
        store.liveShowShortcut = .controlOptionCommandW
        let again = SettingsStore(defaults: defaults)
        #expect(again.ghostMode == true)
        #expect(again.liveStopShortcut == .off)
        #expect(again.liveShowShortcut == .controlOptionCommandW)
    }

    @Test func vocabularyHintPersistsAndIsLimited() {
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = SettingsStore(defaults: defaults)
        #expect(store.liveVocabularyHint.isEmpty)
        store.liveVocabularyHint = String(repeating: "語", count: 150)
        #expect(store.liveVocabularyHint.count == LivePromptBuilder.hintLimit)
        store.liveVocabularyHint = "ミナト精機"
        #expect(SettingsStore(defaults: defaults).liveVocabularyHint == "ミナト精機")
    }

    @Test func invalidStoredValuesFallBack() {
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("controlOptionCommandL", forKey: "liveStopShortcut") // 表示用の候補を停止に入れた
        defaults.set("reazonspeech-k2-v2-int8", forKey: "liveModelID")           // Whisper 以外
        let store = SettingsStore(defaults: defaults)
        #expect(store.liveStopShortcut == LiveShortcut.defaultStop)
        #expect(store.liveModel.engine == .whisper)
    }

    @Test func shortcutSymbols() {
        #expect(LiveShortcut.controlOptionCommandS.symbol == "⌃⌥⌘S")
        #expect(LiveShortcut.off.symbol == nil)
        #expect(Set(LiveShortcut.stopChoices).intersection(LiveShortcut.showChoices) == [.off])
    }
}

@Suite("ライブ文字起こし: 区切りと確定の改善")
struct LiveCommitImprovementTests {
    let policy = LiveCommitPolicy()

    @Test func agreedSegmentsAreConfirmedWithoutAPause() {
        // 間のない音声（音楽や早口）。前回と同じ結果の区間は、末尾から 2 秒以上前に終わっていれば確定する
        let current = [seg(0, 3.1, "一つ目の文。"), seg(3.1, 6.0, "二つ目の文。"), seg(6.0, 8.8, "三つ目")]
        let previous = [seg(0, 3.0, "一つ目の文。"), seg(3.0, 6.1, "二つ目の文"), seg(6.1, 7.9, "三つ")]
        let d = policy.decide(segments: current, windowDuration: 9, pauses: [], previous: previous, isFinal: false)
        #expect(d.confirmed.map(\.text) == ["一つ目の文。", "二つ目の文。"])
        #expect(d.provisional.map(\.text) == ["三つ目"])
        // 次の区間の始まりより後ろでは切らない（頭を落とさない）
        #expect(d.advance <= 6.0 && d.advance > 3.1)
    }

    @Test func agreementDoesNotConfirmInTheMiddleOfASentence() {
        // 「、」で終わり、境目に間もない区間は、2 回同じでも確定しない（Whisper が途中で切って続きを補うことがある）
        let current = [seg(0, 3, "そのため、リアルタイムの"), seg(3, 6, "文字起こしでは")]
        var d = policy.decide(segments: current, windowDuration: 9, pauses: [], previous: current, isFinal: false)
        #expect(d.confirmed.isEmpty)
        // 境目に短い間があれば確定する（句読点のない歌詞など）
        d = policy.decide(segments: current, windowDuration: 9, pauses: [2.9 ... 3.3], previous: current, isFinal: false)
        #expect(d.confirmed.map(\.text) == ["そのため、リアルタイムの"])
        // 文の終わりの区間までは確定し、その後ろの途中の区間は残す
        let mixed = [seg(0, 2, "一つ目です。"), seg(2, 4, "二つ目の、"), seg(4, 6, "続き")]
        d = policy.decide(segments: mixed, windowDuration: 9, pauses: [], previous: mixed, isFinal: false)
        #expect(d.confirmed.map(\.text) == ["一つ目です。"])
        #expect(d.advance <= 2)
    }

    @Test func overlappingTimestampsAreNotConfirmedByAgreement() {
        // 次の区間が確定する区間の途中から始まっている（時刻が当てにならない）。区切ると同じ音声を読み直して重複する
        let current = [seg(0, 4, "予定では十一月二十日です。"), seg(2.5, 6, "価格は")]
        let d = policy.decide(segments: current, windowDuration: 9, pauses: [], previous: current, isFinal: false)
        #expect(d.confirmed.isEmpty)
    }

    @Test func disagreementOrRecentEndKeepsSegmentsProvisional() {
        let current = [seg(0, 3, "一つ目の文"), seg(3, 6, "二つ目")]
        // 文字が違う
        var d = policy.decide(segments: current, windowDuration: 9, pauses: [],
                              previous: [seg(0, 3, "一つ目の分"), seg(3, 6, "二つ目")], isFinal: false)
        #expect(d.confirmed.isEmpty && d.advance == 0)
        // 末尾に近い（続きがありうる）
        d = policy.decide(segments: current, windowDuration: 4.5, pauses: [],
                          previous: [seg(0, 3, "一つ目の文")], isFinal: false)
        #expect(d.confirmed.isEmpty)
        // 時刻が大きくずれている
        d = policy.decide(segments: current, windowDuration: 9, pauses: [],
                          previous: [seg(1, 4, "一つ目の文")], isFinal: false)
        #expect(d.confirmed.isEmpty)
        // 無効にできる
        let off = LiveCommitPolicy(commitsOnAgreement: false)
        d = off.decide(segments: current, windowDuration: 9, pauses: [], previous: current, isFinal: false)
        #expect(d.confirmed.isEmpty)
    }

    @Test func cutSnapsToTheQuietestPointBeforeTheNextSegment() {
        let current = [seg(0, 3, "一つ目の文。"), seg(3.4, 6, "二つ目")]
        let d = policy.decide(segments: current, windowDuration: 9, pauses: [], previous: [seg(0, 3, "一つ目の文")],
                              quietest: { range in
                                  #expect(range.upperBound <= 3.4)
                                  return 3.2
                              }, isFinal: false)
        #expect(d.confirmed.count == 1)
        #expect(d.advance == 3.2)
    }

    @Test func pauseCutKeepsTheAudioOfAProvisionalSegment() {
        // 周りより静かな部分（音楽の静かな所など）で始まる区間は、その頭の音声を捨てない
        let segments = [seg(0, 2.0, "前の文"), seg(2.2, 3.4, "小さな声の文")]
        let d = policy.decide(segments: segments, windowDuration: 4, pauses: [2.0 ... 3.5], silences: [], isFinal: false)
        #expect(d.confirmed.map(\.text) == ["前の文"])
        #expect(d.provisional.map(\.text) == ["小さな声の文"])
        #expect(d.advance <= 2.1)
    }

    @Test func onlyDeepSilenceDropsText() {
        // 周りより静かなだけの範囲（pauses）にある文は残し、ほとんど音のない範囲（silences）の文だけ捨てる
        let segments = [seg(0, 1.5, "話し始め"), seg(2.1, 2.9, "静かな歌詞"), seg(4.2, 4.6, "はい")]
        let d = policy.decide(segments: segments, windowDuration: 6, pauses: [2.0 ... 3.0, 4.0 ... 6.0],
                              silences: [4.0 ... 6.0], isFinal: true)
        #expect(d.confirmed.map(\.text) == ["話し始め", "静かな歌詞"])
    }

    @Test func forcedCommitSnapsBeforeTheNextSegment() {
        let segments = (0 ..< 10).map { seg(Double($0) * 2, Double($0) * 2 + 1.8, "文\($0)") }
        // 末尾から 3 秒以内に終わる区間（16〜17.8 秒）から後ろは暫定に残し、その手前の静かな位置で切る
        let d = policy.decide(segments: segments, windowDuration: 20, pauses: [], quietest: { $0.lowerBound + 0.1 }, isFinal: false)
        #expect(d.confirmed.count == 8)
        #expect(d.advance > 15.6 && d.advance <= 16)
        // 範囲の外を返されても、次の区間の始まりより後ろでは切らない
        let wild = policy.decide(segments: segments, windowDuration: 20, pauses: [], quietest: { _ in 19 }, isFinal: false)
        #expect(wild.advance <= 16)
    }

    @Test func analysisSeparatesDeepSilenceFromQuietParts() {
        let rate = 16_000.0
        // 大きな音 2 秒、小さな音（-26dB）1 秒、無音 1 秒、大きな音 1 秒
        var x = speechLike(duration: 5, voiced: [0 ... 2, 4 ... 5], amplitude: 0.4)
        for i in Int(2 * rate) ..< Int(3 * rate) { x[i] = 0.02 * Float(sin(2 * Double.pi * 300 * Double(i) / rate)) }
        let a = VoiceActivityDetector().analyze(x, sampleRate: rate)
        #expect(a.pauses.contains { $0.lowerBound <= 3.05 && $0.upperBound >= 3.95 })
        // 小さな音の部分は、ほとんど音のない範囲には入らない
        #expect(a.silences.count == 1)
        #expect(a.silences.allSatisfy { $0.lowerBound >= 2.95 && $0.upperBound <= 4.05 })
        // 最も静かな位置は無音の中
        let q = try! #require(a.quietestTime(in: 1.5 ... 4.5))
        #expect(q > 3 && q < 4)
    }

    @Test func confirmedSegmentsAreSplitAtSentenceEnds() {
        let parts = LiveText.splitSentences(seg(10, 16, "一方で客足が落ちています。 来月の新製品です。"))
        #expect(parts.map(\.text) == ["一方で客足が落ちています。", "来月の新製品です。"])
        #expect(parts.first?.start == 10 && parts.last?.end == 16)
        #expect(parts[0].end > 12 && parts[0].end < 14)   // 文字数で按分
        #expect(LiveText.splitSentences(seg(0, 4, "Thank you. See you next week!")).map(\.text) == ["Thank you.", "See you next week!"])
        // 小数点や、文の終わりのない区間はそのまま
        #expect(LiveText.splitSentences(seg(0, 2, "3.5 percent")).count == 1)
        #expect(LiveText.splitSentences(seg(0, 2, "はい。")).count == 1)
        #expect(LiveText.splitSentences(seg(0, 2, "えっ！？そう")).map(\.text) == ["えっ！？", "そう"])
        #expect(LiveText.splitSentences(seg(0, 4, "いつですか?予定では20日です")).map(\.text) == ["いつですか?", "予定では20日です"])
        // 確定した区間だけを分ける
        var t = LiveTranscript()
        t.apply(.init(confirmed: [seg(0, 4, "一つ目です。二つ目です。")], provisional: [seg(4, 6, "暫定です。続きです。")], advance: 4), windowStart: 0)
        #expect(t.confirmed.count == 2)
        #expect(t.provisional.count == 1)
    }

    @Test func reReadDuplicatesAreNotConfirmedTwice() {
        var t = LiveTranscript()
        t.apply(.init(confirmed: [seg(0, 2, "質問があればどうぞ")], provisional: [], advance: 1.5), windowStart: 0)
        // 同じ音声を読み直して、時刻の重なる同じ文が出た
        t.apply(.init(confirmed: [seg(0, 1.2, "質問があればどうぞ。"), seg(1.4, 3, "次の文")], provisional: [], advance: 3), windowStart: 1.5)
        #expect(t.confirmed.map(\.text) == ["質問があればどうぞ", "次の文"])
        // 時刻が重ならない同じ文（繰り返し話された）は残す
        t.apply(.init(confirmed: [seg(0, 2, "次の文")], provisional: [], advance: 2), windowStart: 5)
        #expect(t.confirmed.count == 3)
    }

    @Test func overlapWithTheLastConfirmedTextIsRemoved() {
        #expect(LiveText.removingOverlap(of: "わかりました。じゃあ", from: "じゃあ、その前に案を用意しましょう。") == "その前に案を用意しましょう。")
        #expect(LiveText.removingOverlap(of: "どのくらい", from: "どのくらいずれそうですか") == "ずれそうですか")
        #expect(LiveText.removingOverlap(of: "はい。", from: "了解です") == nil)
        // 英語は単語単位（単語の一部の一致では除かない）
        #expect(LiveText.removingOverlap(of: "B. At the hotel near the station.", from: "online meeting today") == nil)
        #expect(LiveText.removingOverlap(of: "Sure, it leaves at ten", from: "at ten fifteen from platform three") == "fifteen from platform three")
        // 時刻が重なっているときだけ除く。重ならない言い直しは残す
        var t = LiveTranscript()
        t.apply(.init(confirmed: [seg(0, 2.0, "どのくらい")], provisional: [], advance: 1.2), windowStart: 0)
        t.apply(.init(confirmed: [seg(0.3, 2.5, "どのくらいずれそうですか")], provisional: [], advance: 2.5), windowStart: 1.2)
        #expect(t.confirmed.map(\.text) == ["どのくらい", "ずれそうですか"])
        t.apply(.init(confirmed: [seg(0.5, 2.0, "ずれそうですかね")], provisional: [], advance: 2), windowStart: 4)
        #expect(t.confirmed.last?.text == "ずれそうですかね")
    }

    @Test func segmentMostlyAfterThePauseIsReadAgain() {
        // 「じゃあ」の開始時刻が切れ目の直前に置かれたが、終わりは切れ目の後ろ（音声の大半が後ろにある）
        let segments = [seg(0, 1.5, "わかりました。"), seg(1.6, 3.2, "じゃあ")]
        let d = LiveCommitPolicy().decide(segments: segments, windowDuration: 4, pauses: [1.7 ... 2.5], silences: [], isFinal: false)
        #expect(d.confirmed.map(\.text) == ["わかりました。"])
        #expect(d.provisional.map(\.text) == ["じゃあ"])
        #expect(d.advance <= 1.5)  // 「じゃあ」の頭より前で区切る
        // 終わりの時刻が無音の中へ延びただけの文は確定する
        let late = LiveCommitPolicy().decide(segments: [seg(0, 2.4, "わかりました。")], windowDuration: 4,
                                             pauses: [1.7 ... 3.0], silences: [], isFinal: false)
        #expect(late.confirmed.count == 1)
    }

    @Test func shortGapsLetAgreedSegmentsWithoutPunctuationCommit() {
        // 文末の記号がなくても、境目に短い間（0.15 秒以上）があれば 2 回一致で確定する
        let current = [seg(0, 3, "一方で札幌の店舗は客足が落ちています"), seg(3.3, 6, "来月の新製品は")]
        let d = LiveCommitPolicy().decide(segments: current, windowDuration: 9, pauses: [], previous: current,
                                          gaps: [2.95 ... 3.25], isFinal: false)
        #expect(d.confirmed.count == 1)
        #expect(d.reason == .agreement)
    }

    @Test func runawayRepetitionIsDetected() {
        #expect(LiveText.hasRunawayRepetition("ありがとうございますありがとうございますありがとうございますありがとうございます"))
        #expect(LiveText.hasRunawayRepetition("la la la la la"))
        #expect(LiveText.hasRunawayRepetition("ーーーーーーーー"))
        #expect(!LiveText.hasRunawayRepetition("価格は10000円です"))
        #expect(!LiveText.hasRunawayRepetition("本日の会議を始めます。まず、先週の売上について報告します。"))
        #expect(LiveText.normalized("Hello, World。") == "helloworld")
    }
}

@Suite("ライブ文字起こし: 手がかりの文")
struct LivePromptAndLevelTests {
    @Test func hintIsCleanedAndLimited() {
        #expect(LivePromptBuilder.sanitizedHint("  ミナト精機\n カザハヤ研究所  ") == "ミナト精機 カザハヤ研究所")
        let long = String(repeating: "あ", count: 300)
        #expect(LivePromptBuilder.sanitizedHint(long).count == LivePromptBuilder.hintLimit)
    }

    @Test func promptUsesHintAndRecentConfirmedText() {
        let builder = LivePromptBuilder(contextLimit: 20, usesContext: true)
        let confirmed = [seg(0, 2, "最初の文です。"), seg(2, 4, "次に予算の話です。"), seg(4, 6, "以上です。")]
        let p = builder.prompt(hint: "ミナト精機", confirmed: confirmed, windowStart: 6.3)
        #expect(p == "ミナト精機 次に予算の話です。 以上です。")
        // 何もなければ nil
        #expect(builder.prompt(hint: " ", confirmed: [], windowStart: 0) == nil)
        // 既定では直前の文を使わず、ヒントだけ
        let noContext = LivePromptBuilder()
        #expect(noContext.prompt(hint: "語", confirmed: confirmed, windowStart: 6.3) == "語")
    }

    @Test func verbatimHintEchoIsDetected() {
        let hint = "ミナト精機、カザハヤ研究所"
        #expect(LivePromptBuilder.isHintEcho("ミナト精機、カザハヤ研究所。", hint: hint))
        #expect(LivePromptBuilder.isHintEcho("ミナト精機 カザハヤ研究所", hint: hint))
        #expect(!LivePromptBuilder.isHintEcho("ミナト精機と共同で開発しています。", hint: hint))
        #expect(!LivePromptBuilder.isHintEcho("ミナト精機", hint: hint))
        // 1 語だけのヒントは、その語だけの発話もありうるので捨てない
        #expect(!LivePromptBuilder.isHintEcho("Northwind Labs.", hint: "Northwind Labs"))
        #expect(LivePromptBuilder.isHintEcho("Northwind Labs, Kazahaya.", hint: "Northwind Labs, Kazahaya"))
    }

    @Test func staleOrRepetitiveContextIsNotUsed() {
        let builder = LivePromptBuilder(usesContext: true)
        // 時間が空いた
        #expect(builder.prompt(hint: "", confirmed: [seg(0, 2, "前の話")], windowStart: 30) == nil)
        // 同じ文が続いた（繰り返しの誤りを手がかりにして強めない）
        #expect(builder.prompt(hint: "", confirmed: [seg(0, 2, "はい。"), seg(2, 4, "はい")], windowStart: 4) == nil)
        #expect(builder.prompt(hint: "", confirmed: [seg(0, 2, "そうそうそうそうそう")], windowStart: 2) == nil)
        // 長い文は末尾だけ
        let long = String(String.UnicodeScalarView((0 ..< 100).compactMap { Unicode.Scalar(0x4E00 + $0 * 7) }))
        let p = try! #require(LivePromptBuilder(contextLimit: 15, usesContext: true).prompt(hint: "", confirmed: [seg(0, 9, long)], windowStart: 9))
        #expect(p.count == 15)
        #expect(long.hasSuffix(p))
    }
}
