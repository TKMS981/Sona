import Foundation
import Synchronization
internal import llama
import WhisperBatchCore

/// ローカルの言語モデル（GGUF）を llama.cpp で読み込んで保持する。
///
/// - 一度に読み込むモデルは 1 つだけ。別のモデルを使うときは、前のモデルを解放してから読み込む。
/// - 物理メモリの 60% を超えそうなモデルは読み込まない（`LocalLLMCatalog.memoryBudget`）。
/// - 推論は専用のシリアルキューで行う（llama_context は同時に 1 スレッドからしか使えない）。
/// - モデルのファイルは読み込む前に呼び出し側が SHA-256 で照合する（`ModelStorage.verifyContents`）。
public actor LlamaModelHost {
    private var loaded: LoadedLlamaModel?

    public init() {}

    /// 読み込んでいるモデルの id
    public var loadedModelID: String? { loaded?.spec.id }

    /// モデルを用意する（同じモデルが読み込み済みならそれを使う）
    public func generator(for model: LocalLLM, fileURL: URL) async throws -> any TextGenerator {
        if let loaded, loaded.spec.id == model.id { return LlamaGenerator(model: loaded) }
        // 前のモデルを先に解放する（2 つを同時にメモリに置かない）
        await release()
        guard LocalLLMCatalog.fitsInMemory(model) else {
            throw WhisperBatchError.onDeviceAIUnavailable(reason: L("ai.guidance.tooLarge", model.displayName))
        }
        let new = try await LoadedLlamaModel.load(spec: model, fileURL: fileURL)
        loaded = new
        return LlamaGenerator(model: new)
    }

    /// 読み込んでいるモデルを解放する（推論中なら終わるのを待つ）
    public func release() async {
        guard let model = loaded else { return }
        loaded = nil
        await model.close()
    }
}

/// 読み込んだモデル 1 つ（モデル・文脈・語彙）。以降はこのクラスのキューの上でだけ使う。
final class LoadedLlamaModel: @unchecked Sendable {
    let spec: LocalLLM
    private let queue: DispatchQueue
    private var model: OpaquePointer?
    private var context: OpaquePointer?
    private let batchSize: Int32 = 512

    private init(spec: LocalLLM, model: OpaquePointer, context: OpaquePointer, queue: DispatchQueue) {
        self.spec = spec
        self.model = model
        self.context = context
        self.queue = queue
    }

    static func load(spec: LocalLLM, fileURL: URL) async throws -> LoadedLlamaModel {
        LlamaLogging.configure()
        let queue = DispatchQueue(label: "Sona.llama", qos: .userInitiated)
        let path = fileURL.path
        let threads = Int32(max(2, min(8, ProcessInfo.processInfo.activeProcessorCount - 2)))
        let handle: (OpaquePointer?, OpaquePointer?) = await withCheckedContinuation { continuation in
            queue.async {
                var mparams = llama_model_default_params()
                mparams.n_gpu_layers = -1 // すべての層を Metal（GPU）で扱う
                guard let model = llama_model_load_from_file(path, mparams) else {
                    continuation.resume(returning: (nil, nil))
                    return
                }
                var cparams = llama_context_default_params()
                cparams.n_ctx = UInt32(spec.contextTokens)
                cparams.n_batch = 512
                cparams.n_ubatch = 512
                cparams.n_seq_max = 1
                cparams.n_threads = threads
                cparams.n_threads_batch = threads
                guard let context = llama_init_from_model(model, cparams) else {
                    llama_model_free(model)
                    continuation.resume(returning: (nil, nil))
                    return
                }
                continuation.resume(returning: (model, context))
            }
        }
        guard let model = handle.0, let context = handle.1 else {
            throw WhisperBatchError.modelLoadFailed(modelName: spec.displayName)
        }
        return LoadedLlamaModel(spec: spec, model: model, context: context, queue: queue)
    }

    /// 解放する（キューに積んで、実行中の推論が終わってから解放する）
    func close() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async { [self] in
                if let context { llama_free(context) }
                if let model { llama_model_free(model) }
                context = nil
                model = nil
                continuation.resume()
            }
        }
    }

    deinit {
        if let context { llama_free(context) }
        if let model { llama_model_free(model) }
    }

    /// 入力の文字列（特別なトークンを含む）から続きを生成する
    func complete(prompt: String, greedy: Bool, maxTokens: Int) async throws -> String {
        let flag = LlamaCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, any Error>) in
                queue.async { [self] in
                    continuation.resume(with: Result { try run(prompt: prompt, greedy: greedy, maxTokens: maxTokens, flag: flag) })
                }
            }
        } onCancel: {
            flag.cancel()
        }
    }

    private func run(prompt: String, greedy: Bool, maxTokens: Int, flag: LlamaCancellation) throws -> String {
        guard let model, let context else { throw CancellationError() }
        if flag.isCancelled { throw CancellationError() }
        let vocab = llama_model_get_vocab(model)
        // 前回の内容を消す（依頼ごとに独立して処理する）
        llama_memory_clear(llama_get_memory(context), true)

        var tokens = tokenize(vocab: vocab, text: prompt)
        let nCtx = Int(llama_n_ctx(context))
        let budget = min(maxTokens, nCtx - tokens.count - 8)
        guard budget >= 32 else { throw WhisperBatchError.onDeviceAIFailed(detail: L("ai.error.tooLong")) }

        // 中止の要求を、入力の処理の途中でも伝える
        let flagPtr = Unmanaged.passUnretained(flag).toOpaque()
        llama_set_abort_callback(context, { data in
            guard let data else { return false }
            return Unmanaged<LlamaCancellation>.fromOpaque(data).takeUnretainedValue().isCancelled
        }, flagPtr)
        defer { llama_set_abort_callback(context, nil, nil) }

        // 入力をまとめて処理する
        var start = 0
        while start < tokens.count {
            if flag.isCancelled { throw CancellationError() }
            let n = min(Int(batchSize), tokens.count - start)
            let code = tokens.withUnsafeMutableBufferPointer { buf in
                llama_decode(context, llama_batch_get_one(buf.baseAddress! + start, Int32(n)))
            }
            if flag.isCancelled { throw CancellationError() }
            guard code == 0 else { throw WhisperBatchError.onDeviceAIFailed(detail: "llama_decode \(code)") }
            start += n
        }
        tokens.removeAll()

        let sampler = llama_sampler_chain_init(llama_sampler_chain_default_params())
        defer { llama_sampler_free(sampler) }
        if greedy {
            llama_sampler_chain_add(sampler, llama_sampler_init_greedy())
        } else {
            llama_sampler_chain_add(sampler, llama_sampler_init_top_k(40))
            llama_sampler_chain_add(sampler, llama_sampler_init_top_p(0.9, 1))
            llama_sampler_chain_add(sampler, llama_sampler_init_temp(0.3))
            llama_sampler_chain_add(sampler, llama_sampler_init_dist(1234))
        }

        let stops = spec.format.stopStrings.map { Array($0.utf8) }
        let isHarmony = spec.format == .harmonyLLMJP || spec.format == .harmonyGPTOSS
        var output: [UInt8] = []
        for _ in 0 ..< budget {
            if flag.isCancelled { throw CancellationError() }
            var token = llama_sampler_sample(sampler, context, -1)
            let piece = self.piece(vocab: vocab, token: token)
            if llama_vocab_is_eog(vocab, token) {
                // Harmony 形式では、思考（analysis）の終わりの <|end|> を終わりとして扱う版がある。最終の回答がまだなら続ける
                let text = String(decoding: piece, as: UTF8.self)
                guard isHarmony, text == "<|end|>",
                      !String(decoding: output, as: UTF8.self).contains("<|channel|>final") else { break }
            }
            output += piece
            if stops.contains(where: { output.ends(with: $0) }) { break }
            let code = withUnsafeMutablePointer(to: &token) { ptr in
                llama_decode(context, llama_batch_get_one(ptr, 1))
            }
            // 中止の要求で処理が打ち切られた場合（llama_decode は 2 を返す）は、失敗ではなく中止として扱う
            if flag.isCancelled { throw CancellationError() }
            guard code == 0 else { throw WhisperBatchError.onDeviceAIFailed(detail: "llama_decode \(code)") }
        }
        return String(decoding: output, as: UTF8.self)
    }

    private func tokenize(vocab: OpaquePointer?, text: String) -> [llama_token] {
        let utf8 = Array(text.utf8CString)
        let length = Int32(utf8.count - 1)
        var tokens = [llama_token](repeating: 0, count: Int(length) + 8)
        // 特別なトークン（<|im_start|> など）は文字列から読み取る。BOS は入力の文字列に含めているので足さない。
        var n = utf8.withUnsafeBufferPointer { buf in
            llama_tokenize(vocab, buf.baseAddress, length, &tokens, Int32(tokens.count), false, true)
        }
        if n < 0 {
            tokens = [llama_token](repeating: 0, count: Int(-n))
            n = utf8.withUnsafeBufferPointer { buf in
                llama_tokenize(vocab, buf.baseAddress, length, &tokens, Int32(tokens.count), false, true)
            }
        }
        return Array(tokens.prefix(max(Int(n), 0)))
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

/// llama.cpp で読み込んだモデルを使う生成器
struct LlamaGenerator: TextGenerator {
    let model: LoadedLlamaModel

    var displayName: String { AITextEngine.local(model.spec).displayName }
    var isTranslationOnly: Bool { model.spec.isTranslationOnly }

    /// 文脈の長さから、指示（約 600 トークン）と返答（約 1,200 トークン）の分を除いた文字数。
    /// 日本語は 1 文字が 1 トークン前後になるので、文字数＝トークン数として見積もる。
    var maxInputCharacters: Int { max(400, model.spec.contextTokens - 1_800) }

    func generate(_ request: GenerationRequest) async throws -> String {
        guard !model.spec.isTranslationOnly else {
            throw WhisperBatchError.onDeviceAIUnavailable(reason: L("ai.guidance.unsupportedTask", model.spec.displayName))
        }
        let prompt = model.spec.format.render(system: request.instructions, user: request.prompt)
        let raw = try await model.complete(prompt: prompt, greedy: request.greedy, maxTokens: request.maxTokens)
        return model.spec.format.extractAnswer(raw)
    }

    func translate(_ text: String, from source: String?, to target: String) async throws -> String {
        if model.spec.format == .plamoTranslate {
            let prompt = ChatFormat.plamo(text: text, source: source, target: target)
            let raw = try await model.complete(prompt: prompt, greedy: true, maxTokens: max(256, text.count * 3))
            return model.spec.format.extractAnswer(raw)
        }
        let request = GenerationRequest(instructions: LocalAIText.translationInstructions(target: target),
                                        prompt: text, greedy: true, maxTokens: max(256, text.count * 3))
        return try await generate(request)
    }
}

final class LlamaCancellation: Sendable {
    private let state = Atomic<Bool>(false)
    func cancel() { state.store(true, ordering: .relaxed) }
    var isCancelled: Bool { state.load(ordering: .relaxed) }
}

/// llama.cpp / ggml のログはアプリの出力に混ぜない（WHISPER_BATCH_VERBOSE=1 のときだけ標準エラーへ）
enum LlamaLogging {
    private static let once: Void = {
        llama_backend_init()
        let verbose = ProcessInfo.processInfo.environment["WHISPER_BATCH_VERBOSE"] == "1"
        if verbose {
            llama_log_set({ _, text, _ in if let text { fputs(text, stderr) } }, nil)
        } else {
            llama_log_set({ _, _, _ in }, nil)
        }
    }()

    static func configure() { _ = once }
}

private extension Array where Element == UInt8 {
    func ends(with suffix: [UInt8]) -> Bool {
        count >= suffix.count && Array(self[(count - suffix.count)...]) == suffix
    }
}
