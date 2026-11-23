import Foundation
internal import llama
import WhisperBatchCore

/// 音声を直接読める言語モデル（llama.cpp のマルチモーダル＝mtmd）で、短い音声を文字にする。
///
/// - 対応するモデル: Qwen3-ASR（Alibaba）、Granite Speech（IBM）。どちらもモデル本体の GGUF と、
///   音声エンコーダー（mmproj）の GGUF の 2 つを読み込む。
/// - 1 回に渡す音声は短く（数秒〜数十秒）する。長い音声は呼び出し側が発話の切れ目で区切る。
/// - 推論は専用のシリアルキューで行う（llama_context・mtmd_context は同時に 1 スレッドからしか使えない）。
/// - 出力は greedy（毎回もっとも確からしい語）で、同じ入力なら同じ結果になるようにする。
public final class LlamaSpeechRecognizer: @unchecked Sendable {
    /// モデルの種類（プロンプトの形と、返答の読み方が違う）
    public enum Family: String, Sendable {
        case qwen3ASR
        case graniteSpeech
    }

    /// 1 回の認識の結果
    public struct Output: Sendable, Equatable {
        /// 認識した文（前後の空白は除く）
        public var text: String
        /// モデルが判定した言語コード（Qwen3-ASR の自動判定のときだけ）
        public var languageCode: String?
        /// 生成したトークン数
        public var generatedTokens: Int
        /// 繰り返しを検出して打ち切った
        public var stoppedRepetition: Bool
    }

    public let family: Family
    private let queue: DispatchQueue
    private var model: OpaquePointer?
    private var context: OpaquePointer?
    private var media: OpaquePointer?
    private let sampleRate: Int
    /// アプリの終了時などに、実行中の推論を打ち切る
    private let aborted = LlamaCancellation()

    /// 文脈の長さ。Granite は 2 分の音声で約 1,200 トークン、Qwen3-ASR は 1 秒あたり約 13 トークン。
    /// 呼び出し側は 1 回 30 秒以下に区切るので、返答を含めて十分に収まる。
    static let contextTokens: UInt32 = 4096
    /// 入力をまとめて処理する数（音声の埋め込みは 1 回で渡す必要があるので、文脈の長さと同じにする）
    static let batch: UInt32 = 4096

    private init(family: Family, model: OpaquePointer, context: OpaquePointer, media: OpaquePointer,
                 sampleRate: Int, queue: DispatchQueue) {
        self.family = family
        self.model = model
        self.context = context
        self.media = media
        self.sampleRate = sampleRate
        self.queue = queue
    }

    deinit {
        if let media { mtmd_free(media) }
        if let context { llama_free(context) }
        if let model { llama_model_free(model) }
    }

    /// 音声エンコーダーが受け取る標本化周波数（どちらのモデルも 16 kHz）
    public var audioSampleRate: Int { sampleRate }

    /// モデル本体と音声エンコーダーを読み込む（読み込めない・音声に対応していなければ nil を返さずエラー）
    public static func load(family: Family, modelURL: URL, projectorURL: URL, displayName: String) async throws -> LlamaSpeechRecognizer {
        LlamaLogging.configure()
        let queue = DispatchQueue(label: "Sona.llama.speech", qos: .userInitiated)
        let modelPath = modelURL.path
        let projectorPath = projectorURL.path
        let threads = LlamaLoadConfig.standard.threads
        typealias Handles = (model: OpaquePointer?, context: OpaquePointer?, media: OpaquePointer?, rate: Int)
        let handles: Handles = await withCheckedContinuation { continuation in
            queue.async {
                var mparams = llama_model_default_params()
                mparams.n_gpu_layers = -1
                guard let model = llama_model_load_from_file(modelPath, mparams) else {
                    continuation.resume(returning: (nil, nil, nil, 0))
                    return
                }
                var cparams = llama_context_default_params()
                cparams.n_ctx = contextTokens
                cparams.n_batch = batch
                cparams.n_ubatch = batch
                cparams.n_seq_max = 1
                cparams.n_threads = threads
                cparams.n_threads_batch = threads
                guard let context = llama_init_from_model(model, cparams) else {
                    llama_model_free(model)
                    continuation.resume(returning: (nil, nil, nil, 0))
                    return
                }
                var params = mtmd_context_params_default()
                params.use_gpu = true
                params.print_timings = false
                params.n_threads = threads
                params.warmup = false
                guard let media = mtmd_init_from_file(projectorPath, model, params), mtmd_support_audio(media) else {
                    llama_free(context)
                    llama_model_free(model)
                    continuation.resume(returning: (nil, nil, nil, 0))
                    return
                }
                continuation.resume(returning: (model, context, media, Int(mtmd_get_audio_sample_rate(media))))
            }
        }
        guard let model = handles.model, let context = handles.context, let media = handles.media else {
            throw WhisperBatchError.modelLoadFailed(modelName: displayName)
        }
        return LlamaSpeechRecognizer(family: family, model: model, context: context, media: media,
                                     sampleRate: handles.rate > 0 ? handles.rate : 16_000, queue: queue)
    }

    /// 実行中・これからの認識を打ち切る（アプリの終了時）
    public func abortAll() { aborted.cancel() }

    /// 解放する（実行中の認識が終わってから解放する）
    public func close() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async { [self] in
                if let media { mtmd_free(media) }
                if let context { llama_free(context) }
                if let model { llama_model_free(model) }
                media = nil
                context = nil
                model = nil
                continuation.resume()
            }
        }
    }

    /// 16 kHz モノラルの音声を文字にする。
    /// - Parameter languageCode: 認識する言語（"ja" など）。nil なら自動判定。
    public func transcribe(samples: [Float], languageCode: String?) async throws -> Output {
        let flag = LlamaCancellation(parent: aborted)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Output, any Error>) in
                queue.async { [self] in
                    continuation.resume(with: Result { try run(samples: samples, languageCode: languageCode, flag: flag) })
                }
            }
        } onCancel: {
            flag.cancel()
        }
    }

    // MARK: プロンプトと返答

    /// 入力の文字列（音声の位置に mtmd の目印を置く）
    static func prompt(family: Family, marker: String, languageCode: String?) -> String {
        switch family {
        case .qwen3ASR:
            // 言語を指定するときは、返答の最初（言語の判定）をこちらで書いておく（公式の推論コードと同じ）
            let forced = languageCode.flatMap(qwenLanguageName(for:)).map { "language \($0)<asr_text>" } ?? ""
            return "<|im_start|>user\n\(marker)<|im_end|>\n<|im_start|>assistant\n" + forced
        case .graniteSpeech:
            // 音声を先に置き、文の後ろに指示を書く（モデルカードの推奨の指示。言語の指定は英語で書く形）。
            // 日本語で指示しても句読点の付き方は変わらなかった（講義動画 3 分で比較）ため、英語で指示する。
            let instruction = languageCode.flatMap(graniteLanguageName(for:)).map {
                "The speech is in \($0). Transcribe it exactly; do not translate. transcribe the speech with proper punctuation and capitalization."
            } ?? "transcribe the speech with proper punctuation and capitalization."
            return "USER: \(marker)\(instruction)\n ASSISTANT:"
        }
    }

    /// 返答から文と判定した言語を取り出す
    static func parse(family: Family, raw: String, forcedLanguage: String?) -> (text: String, languageCode: String?) {
        switch family {
        case .qwen3ASR:
            // 自動判定のときは「language Japanese<asr_text>本文」の形で返る
            var text = raw
            var detected: String?
            if let range = raw.range(of: "<asr_text>") {
                let head = raw[..<range.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
                if head.hasPrefix("language ") {
                    detected = qwenLanguageCode(for: String(head.dropFirst("language ".count)))
                }
                text = String(raw[range.upperBound...])
            }
            text = text.replacingOccurrences(of: "<|im_end|>", with: "")
            return (halfwidthASCII(text).trimmingCharacters(in: .whitespacesAndNewlines), forcedLanguage ?? detected)
        case .graniteSpeech:
            return (halfwidthASCII(raw).trimmingCharacters(in: .whitespacesAndNewlines), forcedLanguage)
        }
    }

    /// 全角の英数字・記号（U+FF01〜FF5E）を半角にする。Granite は日本語の中の英字を「ａｉ」のように全角で書くことがあるため。
    /// （カタカナや「。」は変えない。`applyingTransform(.fullwidthToHalfwidth)` はカタカナも半角にしてしまう）
    static func halfwidthASCII(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.map { scalar in
            (0xFF01 ... 0xFF5E).contains(scalar.value) ? Unicode.Scalar(scalar.value - 0xFEE0)! : scalar
        }))
    }

    private static let qwenLanguages: [(code: String, name: String)] = [
        ("ja", "Japanese"), ("en", "English"), ("zh", "Chinese"), ("ko", "Korean"),
        ("es", "Spanish"), ("fr", "French"), ("de", "German"), ("pt", "Portuguese"), ("it", "Italian"),
        ("ru", "Russian"), ("ar", "Arabic"), ("vi", "Vietnamese"), ("th", "Thai"), ("id", "Indonesian"),
    ]

    static func qwenLanguageName(for code: String) -> String? {
        qwenLanguages.first { $0.code == code }?.name
    }

    static func qwenLanguageCode(for name: String) -> String? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return qwenLanguages.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.code
    }

    static func graniteLanguageName(for code: String) -> String? {
        ["ja": "Japanese", "en": "English", "fr": "French", "de": "German", "es": "Spanish", "pt": "Portuguese"][code]
    }

    /// 生成できるトークン数の上限（音声の長さから決める。早口の日本語でも 1 秒あたり 10 トークンほど）
    static func maxTokens(seconds: Double) -> Int {
        Int(seconds * 15) + 64
    }

    // MARK: 推論

    private func run(samples: [Float], languageCode: String?, flag: LlamaCancellation) throws -> Output {
        guard let model, let context, let media else { throw CancellationError() }
        if flag.isCancelled { throw CancellationError() }
        guard !samples.isEmpty else { return Output(text: "", languageCode: languageCode, generatedTokens: 0, stoppedRepetition: false) }
        let vocab = llama_model_get_vocab(model)
        llama_memory_clear(llama_get_memory(context), true)

        let flagPtr = Unmanaged.passUnretained(flag).toOpaque()
        llama_set_abort_callback(context, { data in
            guard let data else { return false }
            return Unmanaged<LlamaCancellation>.fromOpaque(data).takeUnretainedValue().isCancelled
        }, flagPtr)
        defer { llama_set_abort_callback(context, nil, nil) }

        // 音声と文を、モデルに渡す単位（チャンク）に分ける
        guard let bitmap = samples.withUnsafeBufferPointer({ mtmd_bitmap_init_from_audio($0.count, $0.baseAddress) }) else {
            throw WhisperBatchError.onDeviceAIFailed(detail: "mtmd_bitmap_init_from_audio")
        }
        defer { mtmd_bitmap_free(bitmap) }
        guard let chunks = mtmd_input_chunks_init() else { throw WhisperBatchError.onDeviceAIFailed(detail: "mtmd_input_chunks_init") }
        defer { mtmd_input_chunks_free(chunks) }
        let marker = String(cString: mtmd_default_marker())
        let promptText = Self.prompt(family: family, marker: marker, languageCode: languageCode)
        let tokenized: Int32 = promptText.withCString { cText in
            var input = mtmd_input_text(text: cText, text_len: strlen(cText), add_special: false, parse_special: true)
            var bitmaps: [OpaquePointer?] = [bitmap]
            return bitmaps.withUnsafeMutableBufferPointer { buf in
                mtmd_tokenize(media, chunks, &input, buf.baseAddress, 1)
            }
        }
        guard tokenized == 0 else { throw WhisperBatchError.onDeviceAIFailed(detail: "mtmd_tokenize \(tokenized)") }
        let inputTokens = mtmd_helper_get_n_tokens(chunks)
        let budget = min(Self.maxTokens(seconds: Double(samples.count) / Double(sampleRate)),
                         Int(llama_n_ctx(context)) - inputTokens - 8)
        guard budget >= 16 else { throw WhisperBatchError.onDeviceAIFailed(detail: L("ai.error.tooLong")) }

        // 音声（エンコーダーで埋め込みにする）と文をまとめてモデルに渡す
        var nPast: llama_pos = 0
        let evaluated = mtmd_helper_eval_chunks(media, context, chunks, 0, 0, Int32(Self.batch), true, &nPast)
        if flag.isCancelled { throw CancellationError() }
        guard evaluated == 0 else { throw WhisperBatchError.onDeviceAIFailed(detail: "mtmd_helper_eval_chunks \(evaluated)") }

        let sampler = llama_sampler_chain_init(llama_sampler_chain_default_params())
        defer { llama_sampler_free(sampler) }
        llama_sampler_chain_add(sampler, llama_sampler_init_greedy())

        var batch = llama_batch_init(1, 0, 1)
        defer { llama_batch_free(batch) }
        var output: [UInt8] = []
        var tokens: [llama_token] = []
        var stoppedRepetition = false
        for _ in 0 ..< budget {
            if flag.isCancelled { throw CancellationError() }
            let token = llama_sampler_sample(sampler, context, -1)
            if llama_vocab_is_eog(vocab, token) { break }
            tokens.append(token)
            output += piece(vocab: vocab, token: token)
            if Self.isRepeating(tokens) {
                stoppedRepetition = true
                break
            }
            // 位置を明示して 1 トークンずつ渡す（Qwen3-ASR は M-RoPE。音声の後ろから位置を続ける）
            batch.n_tokens = 1
            batch.token[0] = token
            batch.pos[0] = nPast
            batch.n_seq_id[0] = 1
            batch.seq_id[0]![0] = 0
            batch.logits[0] = 1
            nPast += 1
            let code = llama_decode(context, batch)
            if flag.isCancelled { throw CancellationError() }
            guard code == 0 else { throw WhisperBatchError.onDeviceAIFailed(detail: "llama_decode \(code)") }
        }
        var raw = String(decoding: output, as: UTF8.self)
        if stoppedRepetition { raw = Self.trimRepetition(raw) }
        let parsed = Self.parse(family: family, raw: raw, forcedLanguage: languageCode)
        return Output(text: parsed.text, languageCode: parsed.languageCode, generatedTokens: tokens.count,
                      stoppedRepetition: stoppedRepetition)
    }

    /// 同じ並びのトークンが続けて何度も出た（音声にない繰り返しを作り続けている）
    static func isRepeating(_ tokens: [llama_token]) -> Bool {
        // 長さ 2〜24 トークンの並びが末尾で 4 回以上、同じ 1 トークンなら 12 回以上続いていれば繰り返しとみなす
        // （「ーーー」のような同じトークンの短い連続は普通の文にもあるため、1 トークンの並びは長めに見る）
        let count = tokens.count
        for length in 1 ... 24 {
            let repeats = length == 1 ? 12 : 4
            guard count >= length * repeats else { continue }
            let tail = tokens[(count - length)...]
            // 同じトークンだけの並びは、長さ 1 の判定に任せる
            if length > 1, tail.allSatisfy({ $0 == tail.first }) { continue }
            var same = true
            for r in 1 ..< repeats {
                let start = count - length * (r + 1)
                if !tokens[start ..< start + length].elementsEqual(tail) { same = false; break }
            }
            if same { return true }
        }
        return false
    }

    /// 繰り返しの部分を 1 回分だけ残す（文字の単位で、末尾から同じ並びを取り除く）
    static func trimRepetition(_ text: String) -> String {
        let chars = Array(text)
        for length in 1 ... min(80, chars.count / 2) {
            var end = chars.count
            var removed = 0
            while end - length * 2 >= 0, chars[(end - length) ..< end] == chars[(end - length * 2) ..< (end - length)] {
                end -= length
                removed += 1
            }
            if removed >= 2 { return String(chars[..<end]) }
        }
        return text
    }

    private func piece(vocab: OpaquePointer?, token: llama_token) -> [UInt8] {
        var buffer = [CChar](repeating: 0, count: 64)
        var n = llama_token_to_piece(vocab, token, &buffer, Int32(buffer.count), 0, true)
        if n < 0 {
            buffer = [CChar](repeating: 0, count: Int(-n))
            n = llama_token_to_piece(vocab, token, &buffer, Int32(buffer.count), 0, true)
        }
        return buffer.prefix(max(Int(n), 0)).map { UInt8(bitPattern: $0) }
    }
}
