import CryptoKit
import Foundation

/// AI の処理結果の再利用（同じ依頼を同じ条件でもう一度処理しない）。
///
/// - キーは、依頼の全文（指示・依頼文・翻訳の言語）、処理の種類、モデルの id・リビジョン・ファイルの SHA-256・形式・文脈の長さ、
///   推論の設定、プロンプトの版を並べて SHA-256 にしたもの。1 つでも違えば別のキーになり、もう一度処理する。
/// - 結果はメモリの中だけに置く（ディスクに書かない）。アプリが終われば消えるので、異常終了しても残らない・壊れない。
/// - 処理が最後まで終わった返答だけを入れる。中止・失敗した依頼は入れない。
/// - 対象（キューの項目・ライブ）ごと、モデルごとに消せる（編集・削除・モデルの削除や更新のとき）。
/// - 件数と大きさに上限があり、超えたら長く使っていないものから消す。
public actor AIResultCache {
    public struct Limits: Sendable {
        public var maxEntries: Int
        public var maxBytes: Int
        public init(maxEntries: Int = 256, maxBytes: Int = 8 * 1_048_576) {
            self.maxEntries = maxEntries
            self.maxBytes = maxBytes
        }
    }

    private struct Entry {
        var value: String
        var scopes: Set<String>
        var modelID: String
        var bytes: Int
        var lastUse: UInt64
    }

    private var entries: [String: Entry] = [:]
    private var totalBytes = 0
    private var clock: UInt64 = 0
    private let limits: Limits
    public private(set) var hits = 0
    public private(set) var misses = 0

    public init(limits: Limits = Limits()) {
        self.limits = limits
    }

    public var count: Int { entries.count }

    /// 同じキーの結果（なければ nil）。`scope` から使ったら、その対象にも属させる（その対象の編集・削除でも消えるように）。
    public func value(for key: AIResultCacheKey, scope: String? = nil) -> String? {
        guard var entry = entries[key.digest] else {
            misses += 1
            return nil
        }
        clock += 1
        entry.lastUse = clock
        if let scope { entry.scopes.insert(scope) }
        entries[key.digest] = entry
        hits += 1
        return entry.value
    }

    /// 結果を入れる（`scope` は消すときの単位。同じ結果を別の対象から使ったら、両方の対象に属する）
    public func store(_ value: String, for key: AIResultCacheKey, scope: String?) {
        let bytes = value.utf8.count + key.digest.utf8.count
        guard bytes <= limits.maxBytes else { return }
        clock += 1
        if var existing = entries[key.digest] {
            totalBytes -= existing.bytes
            existing.value = value
            existing.bytes = bytes
            existing.lastUse = clock
            if let scope { existing.scopes.insert(scope) }
            entries[key.digest] = existing
        } else {
            entries[key.digest] = Entry(value: value, scopes: scope.map { [$0] } ?? [], modelID: key.modelID,
                                        bytes: bytes, lastUse: clock)
        }
        totalBytes += bytes
        evictIfNeeded()
    }

    /// 対象（キューの項目の id・"live"）の結果を消す
    public func invalidate(scope: String) {
        remove { $0.scopes.contains(scope) }
    }

    /// モデルの結果を消す（削除・更新したとき）
    public func invalidate(modelID: String) {
        remove { $0.modelID == modelID }
    }

    public func removeAll() {
        entries.removeAll()
        totalBytes = 0
    }

    private func remove(where predicate: (Entry) -> Bool) {
        for (key, entry) in entries where predicate(entry) {
            entries.removeValue(forKey: key)
            totalBytes -= entry.bytes
        }
    }

    private func evictIfNeeded() {
        while entries.count > limits.maxEntries || totalBytes > limits.maxBytes,
              let oldest = entries.min(by: { $0.value.lastUse < $1.value.lastUse }) {
            entries.removeValue(forKey: oldest.key)
            totalBytes -= oldest.value.bytes
        }
    }
}

/// 結果の再利用のキー
public struct AIResultCacheKey: Hashable, Sendable {
    /// 条件をすべて並べたものの SHA-256（16 進）
    public let digest: String
    public let modelID: String

    /// キーの形式の版（キーの作り方を変えたら上げる）
    public static let formatVersion = "sona-ai-result-cache/1"

    /// モデルを特定する情報
    public struct Model: Hashable, Sendable {
        public var id: String
        public var revision: String
        /// 読み込んだファイルの SHA-256
        public var fileSHA256: String
        /// 入力の形式（ChatFormat）
        public var format: String
        public var contextTokens: Int
        /// 推論の設定（ランタイムの版・サンプリングなど）
        public var inferenceSettings: String

        public init(id: String, revision: String, fileSHA256: String, format: String, contextTokens: Int, inferenceSettings: String) {
            self.id = id
            self.revision = revision
            self.fileSHA256 = fileSHA256
            self.format = format
            self.contextTokens = contextTokens
            self.inferenceSettings = inferenceSettings
        }
    }

    /// 文章の生成（指示と依頼）
    public static func generate(_ request: GenerationRequest, model: Model) -> AIResultCacheKey {
        make(operation: "generate", model: model, fields: [
            "instructions": request.instructions,
            "prompt": request.prompt,
            "greedy": request.greedy ? "1" : "0",
            "maxTokens": String(request.maxTokens),
        ])
    }

    /// 翻訳
    public static func translate(_ text: String, source: String?, target: String, model: Model) -> AIResultCacheKey {
        make(operation: "translate", model: model, fields: [
            "text": text,
            "source": source ?? "",
            "target": target,
        ])
    }

    static func make(operation: String, model: Model, fields: [String: String]) -> AIResultCacheKey {
        var parts: [(String, String)] = [
            ("format", formatVersion),
            ("operation", operation),
            ("promptVersion", LocalAIText.promptVersion),
            ("model.id", model.id),
            ("model.revision", model.revision),
            ("model.sha256", model.fileSHA256),
            ("model.format", model.format),
            ("model.contextTokens", String(model.contextTokens)),
            ("inference", model.inferenceSettings),
        ]
        parts += fields.sorted { $0.key < $1.key }.map { ("request.\($0.key)", $0.value) }
        // 長さを前に付けて並べる（区切り文字を含む文でも、別の条件と同じ並びにならない）
        var hasher = SHA256()
        for (name, value) in parts {
            for piece in [name, value] {
                let data = Data(piece.utf8)
                withUnsafeBytes(of: UInt64(data.count).bigEndian) { hasher.update(bufferPointer: $0) }
                hasher.update(data: data)
            }
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return AIResultCacheKey(digest: digest, modelID: model.id)
    }
}

/// 結果を再利用する生成器（同じ条件の依頼は、生成器を呼ばずに前の結果を返す）。
/// 結果が決まった手順で決まるもの（ローカルの言語モデル）だけに使う。
public struct CachingTextGenerator: TextGenerator {
    public let base: any TextGenerator
    public let cache: AIResultCache
    public let model: AIResultCacheKey.Model
    /// 消すときの単位（キューの項目の id・"live"）
    public let scope: String?

    public init(base: any TextGenerator, cache: AIResultCache, model: AIResultCacheKey.Model, scope: String?) {
        self.base = base
        self.cache = cache
        self.model = model
        self.scope = scope
    }

    public var displayName: String { base.displayName }
    public var maxInputCharacters: Int { base.maxInputCharacters }
    public var isTranslationOnly: Bool { base.isTranslationOnly }

    public func generate(_ request: GenerationRequest) async throws -> String {
        let key = AIResultCacheKey.generate(request, model: model)
        if let hit = await cache.value(for: key, scope: scope) { return hit }
        let result = try await base.generate(request)
        // 中止されたときは入れない（途中で打ち切られた返答を残さない）
        try Task.checkCancellation()
        await cache.store(result, for: key, scope: scope)
        return result
    }

    public func translate(_ text: String, from source: String?, to target: String) async throws -> String {
        let key = AIResultCacheKey.translate(text, source: source, target: target, model: model)
        if let hit = await cache.value(for: key, scope: scope) { return hit }
        let result = try await base.translate(text, from: source, to: target)
        try Task.checkCancellation()
        await cache.store(result, for: key, scope: scope)
        return result
    }
}
