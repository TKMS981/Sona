import Foundation
import Synchronization
internal import llama
import WhisperBatchCore

/// ローカルの言語モデル（GGUF）を llama.cpp で読み込んで保持する。
///
/// - 一度に読み込むモデルは 1 つだけ。別のモデルを使うときは、前のモデルを使い終わるのを待ち、解放してから読み込む。
/// - 物理メモリの 60% を超えそうなモデルは読み込まない（`LocalLLMCatalog.memoryBudget`）。
/// - 推論は専用のシリアルキューで行う（llama_context は同時に 1 スレッドからしか使えない）。
/// - モデルのファイルは読み込む前に呼び出し側が SHA-256 で照合する（`ModelStorage.verifyContents`）。
/// - 渡した生成器を誰かが持っている間は「使用中」とし、解放しない（`release()` は使い終わるまで延ばす）。
///   使い終わってから `idleTimeout` の間使われなければ解放する。メモリが逼迫したとき（macOS の通知）も、使用中でなければ解放する。
///   推論の設定（文脈の長さ・サンプリングなど）は変えない。読み込み直すときも同じ設定で読み込む。
public actor LlamaModelHost {
    private var loaded: LoadedLlamaModel?
    /// 解放・読み込みの途中（この間に別の読み込みを始めない）
    private var transitioning = false
    /// 使用中の生成器の数（生成器が手放されると、その場で減る）
    private let usage = LlamaUsage()
    /// 使い終わったら解放する（使用中に解放を頼まれた）
    private var releaseWhenIdle = false
    private var idleTimer: Task<Void, Never>?
    private var memoryPressure: (any DispatchSourceMemoryPressure)?
    /// 状態が変わるのを待っている呼び出し（別のモデルへの切り替えなど）
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var observer: (@Sendable (String?) -> Void)?

    /// 使い終わってから自動で解放するまでの時間（nil なら自動では解放しない）
    public let idleTimeout: Duration?

    public init(idleTimeout: Duration? = .seconds(180)) {
        self.idleTimeout = idleTimeout
    }

    /// 読み込んでいるモデルの id
    public var loadedModelID: String? { loaded?.spec.id }

    /// 使用中の生成器の数
    public var activeUseCount: Int { usage.count }

    /// 読み込んでいるモデルが変わったら呼ぶ（表示の更新用。nil は解放した）
    public func setObserver(_ observer: (@Sendable (String?) -> Void)?) {
        self.observer = observer
    }

    /// モデルを用意する（同じモデルが読み込み済みならそれを使う）。返した生成器を持っている間は使用中になる。
    public func generator(for model: LocalLLM, fileURL: URL) async throws -> any TextGenerator {
        while true {
            try Task.checkCancellation()
            if transitioning {
                try await waitForChange()
                continue
            }
            if let loaded {
                if loaded.spec.id == model.id { return lease(loaded) }
                // 別のモデルが使用中なら、使い終わるまで待つ（処理中のモデルは解放しない。2 つを同時にメモリに置かない）
                if usage.count > 0 {
                    try await waitForChange()
                    continue
                }
                await unload()
                continue
            }
            guard LocalLLMCatalog.fitsInMemory(model) else {
                throw WhisperBatchError.onDeviceAIUnavailable(reason: L("ai.guidance.tooLarge", model.displayName))
            }
            transitioning = true
            do {
                let new = try await LoadedLlamaModel.load(spec: model, fileURL: fileURL)
                loaded = new
                releaseWhenIdle = false
                transitioning = false
                startWatchingMemoryPressure()
                observer?(new.spec.id)
                resumeWaiters()
                return lease(new)
            } catch {
                transitioning = false
                resumeWaiters()
                throw error
            }
        }
    }

    /// 読み込んでいるモデルを解放する。使用中なら、使い終わったときに解放する（処理中のモデルは解放しない）。
    public func release() async {
        guard loaded != nil else { return }
        if usage.count > 0 || transitioning {
            releaseWhenIdle = true
            return
        }
        await unload()
    }

    /// 使用中でなければ解放する（解放したら true）
    @discardableResult
    public func releaseIfIdle() async -> Bool {
        guard loaded != nil, usage.count == 0, !transitioning else { return false }
        await unload()
        return true
    }

    /// アプリの終了時: 実行中の推論を打ち切って解放する
    public func shutdown() async {
        idleTimer?.cancel()
        idleTimer = nil
        guard let model = loaded else { return }
        model.abortAll()
        loaded = nil
        transitioning = true
        await model.close()
        transitioning = false
        stopWatchingMemoryPressure()
        observer?(nil)
        resumeWaiters()
    }

    // MARK: 使用中の管理

    private func lease(_ model: LoadedLlamaModel) -> any TextGenerator {
        idleTimer?.cancel()
        idleTimer = nil
        usage.begin()
        return LlamaGenerator(model: model, lease: LlamaLease(usage: usage, host: self))
    }

    /// 生成器が手放された（`LlamaLease` から呼ぶ）
    func useEnded() async {
        guard usage.count == 0 else { return }
        resumeWaiters()
        guard loaded != nil, !transitioning else { return }
        if releaseWhenIdle {
            await unload()
        } else {
            scheduleIdleRelease()
        }
    }

    private func scheduleIdleRelease() {
        idleTimer?.cancel()
        guard let idleTimeout else { return }
        idleTimer = Task { [weak self] in
            try? await Task.sleep(for: idleTimeout)
            guard !Task.isCancelled else { return }
            await self?.idleTimerFired()
        }
    }

    private func idleTimerFired() async {
        idleTimer = nil
        await releaseIfIdle()
    }

    private func unload() async {
        idleTimer?.cancel()
        idleTimer = nil
        guard let model = loaded else { return }
        loaded = nil
        releaseWhenIdle = false
        transitioning = true
        await model.close()
        transitioning = false
        stopWatchingMemoryPressure()
        observer?(nil)
        resumeWaiters()
    }

    // MARK: メモリの逼迫

    private func startWatchingMemoryPressure() {
        guard memoryPressure == nil else { return }
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .global(qos: .utility))
        source.setEventHandler { [weak self] in
            Task { await self?.releaseIfIdle() }
        }
        source.resume()
        memoryPressure = source
    }

    private func stopWatchingMemoryPressure() {
        memoryPressure?.cancel()
        memoryPressure = nil
    }

    // MARK: 待ち合わせ

    private func waitForChange() async throws {
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                if Task.isCancelled {
                    continuation.resume()
                } else {
                    waiters[id] = continuation
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
        try Task.checkCancellation()
    }

    private func cancelWaiter(_ id: UUID) {
        waiters.removeValue(forKey: id)?.resume()
    }

    private func resumeWaiters() {
        let pending = waiters
        waiters.removeAll()
        for continuation in pending.values { continuation.resume() }
    }
}

/// 使用中の生成器の数（生成器が手放されたときに、待たずに減らせるようにアクターの外に置く）
final class LlamaUsage: Sendable {
    private let state = Mutex(0)
    var count: Int { state.withLock { $0 } }
    func begin() { state.withLock { $0 += 1 } }
    func end() { state.withLock { $0 = max($0 - 1, 0) } }
}

/// 生成器 1 つ分の使用（生成器のコピーがすべて手放されると終わる）
final class LlamaLease: Sendable {
    private let usage: LlamaUsage
    private let host: LlamaModelHost

    init(usage: LlamaUsage, host: LlamaModelHost) {
        self.usage = usage
        self.host = host
    }

    deinit {
        usage.end()
        let host = host
        Task { await host.useEnded() }
    }
}

/// 推論の設定（読み込みと生成で実際に使う値）。結果の再利用（`AIResultCache`）の条件にも、この値をそのまま含める。
public enum LlamaInferenceSettings {
    /// llama.cpp の版（Package.swift の XCFramework）
    public static let runtimeVersion = "llama.cpp b11976"
    /// GPU に置く層の数（-1 はすべて）
    static let gpuLayers: Int32 = -1
    /// 入力をまとめて処理する数（n_batch・n_ubatch）
    static let batch: UInt32 = 512
    static let threads = Int32(max(2, min(8, ProcessInfo.processInfo.activeProcessorCount - 2)))
    // greedy でないときのサンプリング（要約）
    static let topK: Int32 = 40
    static let topP: Float = 0.9
    static let temperature: Float = 0.3
    static let seed: UInt32 = 1234

    /// 結果の再利用の条件に含める文字列（値が 1 つでも変われば別の条件になる）
    public static var signature: String {
        "\(runtimeVersion);gpu_layers=\(gpuLayers);n_batch=\(batch);n_ubatch=\(batch);n_seq_max=1;threads=\(threads)"
            + ";top_k=\(topK);top_p=\(topP);temp=\(temperature);seed=\(seed)"
    }
}

/// 読み込んだモデル 1 つ（モデル・文脈・語彙）。以降はこのクラスのキューの上でだけ使う。
final class LoadedLlamaModel: @unchecked Sendable {
    let spec: LocalLLM
    private let queue: DispatchQueue
    private var model: OpaquePointer?
    private var context: OpaquePointer?
    private let batchSize = Int32(LlamaInferenceSettings.batch)
    /// アプリの終了時に、実行中の推論を打ち切る
    private let aborted = LlamaCancellation()
    /// 最後に終わった生成の内訳（計測用。推論には影響しない）
    private let stats = Mutex<LlamaRunStats?>(nil)
    var lastRunStats: LlamaRunStats? { stats.withLock { $0 } }

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
        let settings = LlamaInferenceSettings.self
        let threads = settings.threads
        let handle: (OpaquePointer?, OpaquePointer?) = await withCheckedContinuation { continuation in
            queue.async {
                var mparams = llama_model_default_params()
                mparams.n_gpu_layers = settings.gpuLayers // すべての層を Metal（GPU）で扱う
                guard let model = llama_model_load_from_file(path, mparams) else {
                    continuation.resume(returning: (nil, nil))
                    return
                }
                var cparams = llama_context_default_params()
                cparams.n_ctx = UInt32(spec.contextTokens)
                cparams.n_batch = settings.batch
                cparams.n_ubatch = settings.batch
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

    /// 実行中・これからの推論を打ち切る（アプリの終了時）
    func abortAll() { aborted.cancel() }

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
        let flag = LlamaCancellation(parent: aborted)
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
        let clock = ContinuousClock()
        let promptStart = clock.now
        let promptTokens = tokens.count
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
        // 入力の処理が終わるのを待ってから時間を測る（Metal では llama_decode が計算の終わりを待たずに戻るため）
        llama_synchronize(context)
        let promptDuration = clock.now - promptStart

        let sampler = llama_sampler_chain_init(llama_sampler_chain_default_params())
        defer { llama_sampler_free(sampler) }
        if greedy {
            llama_sampler_chain_add(sampler, llama_sampler_init_greedy())
        } else {
            let settings = LlamaInferenceSettings.self
            llama_sampler_chain_add(sampler, llama_sampler_init_top_k(settings.topK))
            llama_sampler_chain_add(sampler, llama_sampler_init_top_p(settings.topP, 1))
            llama_sampler_chain_add(sampler, llama_sampler_init_temp(settings.temperature))
            llama_sampler_chain_add(sampler, llama_sampler_init_dist(settings.seed))
        }

        let stops = spec.format.stopStrings.map { Array($0.utf8) }
        let isHarmony = spec.format == .harmonyLLMJP || spec.format == .harmonyGPTOSS
        var output: [UInt8] = []
        let decodeStart = clock.now
        var generated = 0
        defer {
            stats.withLock {
                $0 = LlamaRunStats(promptTokens: promptTokens, promptDuration: promptDuration,
                                   generatedTokens: generated, decodeDuration: clock.now - decodeStart, budget: budget)
            }
        }
        for _ in 0 ..< budget {
            if flag.isCancelled { throw CancellationError() }
            var token = llama_sampler_sample(sampler, context, -1)
            generated += 1
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

/// 1 回の生成の内訳（計測用）
struct LlamaRunStats: Sendable {
    /// 入力のトークン数
    var promptTokens: Int
    /// 入力の処理（prompt eval）にかかった時間
    var promptDuration: Duration
    /// 生成したトークン数（終わりのトークンを含む）
    var generatedTokens: Int
    /// 生成（decode）にかかった時間
    var decodeDuration: Duration
    /// 生成できるトークン数の上限
    var budget: Int
}

/// llama.cpp で読み込んだモデルを使う生成器
struct LlamaGenerator: TextGenerator {
    let model: LoadedLlamaModel
    /// 持っている間は使用中（モデルを解放しない）
    let lease: LlamaLease

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
    /// こちらが中止されたら、これも中止とみなす（アプリの終了時の打ち切り）
    private let parent: LlamaCancellation?
    init(parent: LlamaCancellation? = nil) { self.parent = parent }
    func cancel() { state.store(true, ordering: .relaxed) }
    var isCancelled: Bool { state.load(ordering: .relaxed) || parent?.isCancelled == true }
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
