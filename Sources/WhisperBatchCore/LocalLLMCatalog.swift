import Foundation

/// ローカルの言語モデルの分類（用途の表示と、自動選択に使う）
public enum LLMCategory: String, Sendable, CaseIterable, Identifiable, Hashable {
    /// 日本語を重視して作られた
    case japanese
    /// 英語を重視して作られた（ほかの言語も扱えることがある）
    case english
    /// 多言語
    case multilingual
    /// 翻訳専用
    case translation
    /// 軽量（小さい・速い）
    case lightweight
    /// 高性能（大きい・遅い）
    case highQuality

    public var id: String { rawValue }
    public var displayName: String { L("llm.category.\(rawValue)") }
}

/// 実行に使うランタイム
public enum LLMRuntime: String, Sendable, Hashable {
    /// llama.cpp（GGUF）。バージョンは Package.swift の llama の XCFramework（b11976）
    case llamaCpp

    public var displayName: String {
        switch self {
        case .llamaCpp: "llama.cpp b11976 (GGUF)"
        }
    }
}

/// この環境での動作の確認
public enum LLMVerification: String, Sendable, Hashable {
    /// この Mac（Apple M5 / 32GB / macOS 27.2）で、読み込みと日本語・英語の生成を確認した
    case verified
    /// 同じ系列・同じ形式の小さいモデルで確認した（このモデル自体は読み込んでいない）
    case familyVerified
    /// 確認していない
    case unverified
    /// 読み込めない・正しく動かないことを確認した
    case incompatible

    public var displayName: String { L("llm.verification.\(rawValue)") }
}

public struct LLMLicense: Hashable, Sendable {
    public var name: String
    public var url: URL

    public init(name: String, url: String) {
        self.name = name
        self.url = URL(string: url)!
    }
}

/// ローカルの言語モデル（1 ファイルの GGUF）。取得元・リビジョン・SHA-256・ライセンスを固定して管理する。
public struct LocalLLM: Identifiable, Hashable, Sendable {
    public struct File: Hashable, Sendable {
        public var name: String
        public var sizeBytes: Int64
        public var sha256: String
        public init(name: String, sizeBytes: Int64, sha256: String) {
            self.name = name
            self.sizeBytes = sizeBytes
            self.sha256 = sha256
        }
    }

    public let id: String
    /// モデル名（固有名詞なので表示言語によらない）
    public let name: String
    public let publisher: String
    public let parameters: String
    public let quantization: String
    /// Hugging Face のリポジトリ
    public let repository: String
    /// 取得するコミット（固定）
    public let revision: String
    public let file: File
    public let license: LLMLicense
    public let runtime: LLMRuntime
    public let format: ChatFormat
    public let categories: Set<LLMCategory>
    public let tasks: Set<AITask>
    /// 読み込むときの文脈の長さ（トークン。モデルの上限より小さくして、メモリを抑える）
    public let contextTokens: Int
    public let verification: LLMVerification
    /// 以前のカタログで使っていたリビジョンのファイル（残っていれば、更新するまでそのまま使える）
    public let previousFiles: [PreviousFile]

    public struct PreviousFile: Hashable, Sendable {
        public var revision: String
        public var file: File
        public init(revision: String, file: File) {
            self.revision = revision
            self.file = file
        }
    }

    public init(id: String, name: String, publisher: String, parameters: String, quantization: String,
                repository: String, revision: String, file: File, license: LLMLicense, runtime: LLMRuntime = .llamaCpp,
                format: ChatFormat, categories: Set<LLMCategory>, tasks: Set<AITask>, contextTokens: Int,
                verification: LLMVerification = .unverified, previousFiles: [PreviousFile] = []) {
        self.id = id
        self.name = name
        self.publisher = publisher
        self.parameters = parameters
        self.quantization = quantization
        self.repository = repository
        self.revision = revision
        self.file = file
        self.license = license
        self.runtime = runtime
        self.format = format
        self.categories = categories
        self.tasks = tasks
        self.contextTokens = contextTokens
        self.verification = verification
        self.previousFiles = previousFiles
    }

    public var displayName: String { name }

    /// 翻訳専用（翻訳以外の用途には使わない）
    public var isTranslationOnly: Bool { categories.contains(.translation) }

    /// 取得元のページ
    public var sourceURL: URL { URL(string: "https://huggingface.co/\(repository)/tree/\(revision)")! }

    /// 動かすのに必要なメモリの目安（ファイルの大きさ＋文脈・計算用の領域）
    public var estimatedMemoryBytes: Int64 { file.sizeBytes + 1_500_000_000 }

    /// 補足（ライセンスの条件・研究用など）。なければ nil。
    public var note: String? {
        let key = "llm.note.\(id)"
        let text = L(key)
        return text == key ? nil : text
    }

    /// ダウンロードと保存に使う形（`ModelDownloader` / `ModelStorage` と共通）
    public var downloadModel: SpeechModel {
        let url = URL(string: "https://huggingface.co/\(repository)/resolve/\(revision)/\(file.name)")!
        return SpeechModel(id: "llm-\(id)", engine: .whisper,
                           files: [ModelFile(name: file.name, url: url, sizeBytes: file.sizeBytes, sha256: file.sha256)],
                           folder: "llm/\(id)", purpose: .textGeneration)
    }

    /// 以前のリビジョンのダウンロードの形（残っているかの確認と、読み込む前の照合に使う）
    public func downloadModel(for previous: PreviousFile) -> SpeechModel {
        let url = URL(string: "https://huggingface.co/\(repository)/resolve/\(previous.revision)/\(previous.file.name)")!
        return SpeechModel(id: "llm-\(id)@\(previous.revision.prefix(12))", engine: .whisper,
                           files: [ModelFile(name: previous.file.name, url: url, sizeBytes: previous.file.sizeBytes,
                                             sha256: previous.file.sha256)],
                           folder: "llm/\(id)", purpose: .textGeneration)
    }
}

/// ローカルの言語モデルの一覧。
///
/// 2026-11 に Hugging Face の公式・準公式のリポジトリを調べ、ライセンス・ゲートの有無・形式（GGUF）・
/// アーキテクチャ（llama.cpp b11976 が対応しているか）を確かめたもの。サイズと SHA-256 は各リビジョンの
/// LFS メタデータの値。比較した候補と選ばなかった理由は README の「ローカル AI モデル」に書いた。
public enum LocalLLMCatalog {
    public static let all: [LocalLLM] = [
        LocalLLM(id: "tinyswallow-1.5b", name: "TinySwallow 1.5B Instruct", publisher: "Sakana AI", parameters: "1.5B", quantization: "Q5_K_M",
                 repository: "SakanaAI/TinySwallow-1.5B-Instruct-GGUF", revision: "38c003aaf8be9d17af11dece1fbabeb873c567fa",
                 file: .init(name: "tinyswallow-1.5b-instruct-q5_k_m.gguf", sizeBytes: 1_125_051_232, sha256: "85aab0b1776d358eb04e79f47af7856f21ffc60514dad072c97debb94b7782f2"),
                 license: .init(name: "Apache-2.0", url: "https://www.apache.org/licenses/LICENSE-2.0"), format: .chatML,
                 categories: [.japanese, .lightweight], tasks: [.correction, .polish, .summary], contextTokens: 8192, verification: .verified),
        LocalLLM(id: "llm-jp-4.1-8b", name: "LLM-jp-4.1 8B thinking", publisher: "LLM-jp (NII)", parameters: "8B", quantization: "Q4_K_M",
                 repository: "llm-jp/llm-jp-4.1-8b-thinking-gguf", revision: "7e48aef0e5bd12168494267608deff5e18302884",
                 file: .init(name: "llm-jp-4.1-8b-thinking-Q4_K_M.gguf", sizeBytes: 5_499_918_304, sha256: "9ff25cfc47967fa85639a2ea5ed0ecf2ebf5014f8bd89479bbb948d94614b8ef"),
                 license: .init(name: "Apache-2.0", url: "https://www.apache.org/licenses/LICENSE-2.0"), format: .harmonyLLMJP,
                 categories: [.japanese, .highQuality], tasks: [.correction, .polish, .summary, .translation], contextTokens: 8192, verification: .verified),
        LocalLLM(id: "elyza-jp-8b", name: "Llama-3-ELYZA-JP-8B", publisher: "ELYZA", parameters: "8B", quantization: "Q4_K_M",
                 repository: "elyza/Llama-3-ELYZA-JP-8B-GGUF", revision: "4367e810791b8f647b1cb14452ec390654ad9ef9",
                 file: .init(name: "Llama-3-ELYZA-JP-8B-q4_k_m.gguf", sizeBytes: 4_920_733_984, sha256: "91553c45080b11d95be21bb67961c9a5d2ed7556275423efaaad6df54ba9beae"),
                 license: .init(name: "Meta Llama 3 Community License", url: "https://www.llama.com/llama3/license/"), format: .llama3,
                 categories: [.japanese], tasks: [.correction, .polish, .summary], contextTokens: 8192, verification: .verified),
        LocalLLM(id: "qwen3-1.7b", name: "Qwen3 1.7B", publisher: "Qwen (Alibaba)", parameters: "1.7B", quantization: "Q8_0",
                 repository: "Qwen/Qwen3-1.7B-GGUF", revision: "90862c4b9d2787eaed51d12237eafdfe7c5f6077",
                 file: .init(name: "Qwen3-1.7B-Q8_0.gguf", sizeBytes: 1_834_426_016, sha256: "061b54daade076b5d3362dac252678d17da8c68f07560be70818cace6590cb1a"),
                 license: .init(name: "Apache-2.0", url: "https://www.apache.org/licenses/LICENSE-2.0"), format: .qwen3NoThinking,
                 categories: [.multilingual, .lightweight], tasks: [.correction, .polish, .summary, .translation], contextTokens: 8192, verification: .verified),
        LocalLLM(id: "qwen3-4b", name: "Qwen3 4B", publisher: "Qwen (Alibaba)", parameters: "4B", quantization: "Q4_K_M",
                 repository: "Qwen/Qwen3-4B-GGUF", revision: "bc640142c66e1fdd12af0bd68f40445458f3869b",
                 file: .init(name: "Qwen3-4B-Q4_K_M.gguf", sizeBytes: 2_497_280_256, sha256: "7485fe6f11af29433bc51cab58009521f205840f5b4ae3a32fa7f92e8534fdf5"),
                 license: .init(name: "Apache-2.0", url: "https://www.apache.org/licenses/LICENSE-2.0"), format: .qwen3NoThinking,
                 categories: [.multilingual], tasks: [.correction, .polish, .summary, .translation], contextTokens: 8192, verification: .verified),
        LocalLLM(id: "qwen3-8b", name: "Qwen3 8B", publisher: "Qwen (Alibaba)", parameters: "8B", quantization: "Q4_K_M",
                 repository: "Qwen/Qwen3-8B-GGUF", revision: "7c41481f57cb95916b40956ab2f0b139b296d974",
                 file: .init(name: "Qwen3-8B-Q4_K_M.gguf", sizeBytes: 5_027_783_488, sha256: "d98cdcbd03e17ce47681435b5150e34c1417f50b5c0019dd560e4882c5745785"),
                 license: .init(name: "Apache-2.0", url: "https://www.apache.org/licenses/LICENSE-2.0"), format: .qwen3NoThinking,
                 categories: [.multilingual, .highQuality], tasks: [.correction, .polish, .summary, .translation], contextTokens: 8192, verification: .verified),
        LocalLLM(id: "gemma-4-e2b", name: "Gemma 4 E2B", publisher: "Google (GGUF: ggml-org)", parameters: "E2B", quantization: "Q4_0",
                 repository: "ggml-org/gemma-4-E2B-it-GGUF", revision: "63f6c6f23b3e9e5f9737708daec2f88c9ac2e921",
                 file: .init(name: "gemma-4-E2B-it-Q4_0.gguf", sizeBytes: 2_841_481_184, sha256: "8e30dff3ac4c8434c49a7036fa15564bdbb6044e42bf04550bf1a096ad7e6a52"),
                 license: .init(name: "Apache-2.0", url: "https://www.apache.org/licenses/LICENSE-2.0"), format: .gemma4,
                 categories: [.multilingual, .lightweight], tasks: [.correction, .polish, .summary, .translation], contextTokens: 8192, verification: .verified),
        LocalLLM(id: "gemma-4-e4b", name: "Gemma 4 E4B", publisher: "Google (GGUF: ggml-org)", parameters: "E4B", quantization: "Q4_0",
                 repository: "ggml-org/gemma-4-E4B-it-GGUF", revision: "27cd6836f8e2a6e5e6b57ea0e77fa72490706985",
                 file: .init(name: "gemma-4-E4B-it-Q4_0.gguf", sizeBytes: 4_590_807_392, sha256: "a555b900214b477d8880e7832e0b8925e139b0159640036b09fe472b6f2097f2"),
                 license: .init(name: "Apache-2.0", url: "https://www.apache.org/licenses/LICENSE-2.0"), format: .gemma4,
                 categories: [.multilingual], tasks: [.correction, .polish, .summary, .translation], contextTokens: 8192, verification: .verified),
        LocalLLM(id: "granite-4.2-3b", name: "Granite 4.2 3B", publisher: "IBM", parameters: "3B", quantization: "Q4_K_M",
                 repository: "ibm-granite/granite-4.2-3b-GGUF", revision: "c40945d71cd90f249a56985e8155551a9188dc30",
                 file: .init(name: "granite-4.2-3b-Q4_K_M.gguf", sizeBytes: 2_244_011_552, sha256: "e0406663965846ae22a403456eb826ccce5f450840491f71952f18a7cb78e7d5"),
                 license: .init(name: "Apache-2.0", url: "https://www.apache.org/licenses/LICENSE-2.0"), format: .graniteNoThinking,
                 categories: [.english, .lightweight], tasks: [.correction, .polish, .summary, .translation], contextTokens: 8192, verification: .verified),
        LocalLLM(id: "ministral-3-3b", name: "Ministral 3 3B Instruct", publisher: "Mistral AI", parameters: "3B", quantization: "Q4_K_M",
                 repository: "mistralai/Ministral-3-3B-Instruct-2512-GGUF", revision: "eb599d408350ea2bb60452cb86be7c7b2fc28227",
                 file: .init(name: "Ministral-3-3B-Instruct-2512-Q4_K_M.gguf", sizeBytes: 2_147_023_008, sha256: "9ed150d4367e68df0ac8e1540f6ddc65b42d0ee26378329d1ecbca60f93fc5f8"),
                 license: .init(name: "Apache-2.0", url: "https://www.apache.org/licenses/LICENSE-2.0"), format: .mistral3,
                 categories: [.english, .lightweight], tasks: [.correction, .polish, .summary, .translation], contextTokens: 8192, verification: .verified),
        LocalLLM(id: "phi-4", name: "Phi-4", publisher: "Microsoft", parameters: "14B", quantization: "Q4_K",
                 repository: "microsoft/phi-4-gguf", revision: "6edc2ef6664b739a8e11e62f2672ff6afe0c15ac",
                 file: .init(name: "phi-4-Q4_K.gguf", sizeBytes: 9_053_114_560, sha256: "5652b9be0ea4ae2842130d04fe31bc869fcb99a2b7106c53b4e754a343fd688f"),
                 license: .init(name: "MIT", url: "https://huggingface.co/microsoft/phi-4-gguf/blob/6edc2ef6664b739a8e11e62f2672ff6afe0c15ac/LICENSE"), format: .phi4,
                 categories: [.english, .highQuality], tasks: [.correction, .polish, .summary], contextTokens: 8192, verification: .verified),
        LocalLLM(id: "gpt-oss-20b", name: "gpt-oss 20B", publisher: "OpenAI (GGUF: ggml-org)", parameters: "21B (MoE)", quantization: "MXFP4",
                 repository: "ggml-org/gpt-oss-20b-GGUF", revision: "15dcfc7e7c608c6161507211ed43c5b590801b4b",
                 file: .init(name: "gpt-oss-20b-MXFP4.gguf", sizeBytes: 12_109_566_624, sha256: "27cd6c432c7672cb812a92f611cf3ba7bbc35928262bb1e1253ff4ee6ae35901"),
                 license: .init(name: "Apache-2.0", url: "https://www.apache.org/licenses/LICENSE-2.0"), format: .harmonyGPTOSS,
                 categories: [.english, .highQuality], tasks: [.correction, .polish, .summary, .translation], contextTokens: 8192, verification: .verified),
        LocalLLM(id: "plamo-3-translate-2b", name: "PLaMo 3 Translate 2B", publisher: "Preferred Networks", parameters: "2B", quantization: "Q4_K_M",
                 repository: "pfnet/plamo-3-translate-2b-GGUF", revision: "4f672106b847200bfdc0f6af6c321cd94eba1aed",
                 file: .init(name: "plamo-3-translate-2b-Q4_K_M.gguf", sizeBytes: 1_807_203_040, sha256: "1ffd9073afcc70e35ccc942428aa2b73d7aa2b9ea779bf504b775369e0276c13"),
                 license: .init(name: "PLaMo Community License", url: "https://plamo.preferredai.jp/info/plamo-community-license-en"), format: .plamoTranslate,
                 categories: [.translation, .lightweight], tasks: [.translation], contextTokens: 8192, verification: .verified),
        LocalLLM(id: "plamo-3-translate-8b", name: "PLaMo 3 Translate 8B", publisher: "Preferred Networks", parameters: "8B", quantization: "Q4_K_M",
                 repository: "pfnet/plamo-3-translate-8b-GGUF", revision: "c67efa4eefdc14d3c97bf8f4f35ee58e2ecd2f42",
                 file: .init(name: "plamo-3-translate-8b-Q4_K_M.gguf", sizeBytes: 5_280_445_728, sha256: "94e5d3f91b421f7c8900ddaac27b11a19f7441426c954bbb25a2fd60a1640187"),
                 license: .init(name: "PLaMo Community License", url: "https://plamo.preferredai.jp/info/plamo-community-license-en"), format: .plamoTranslate,
                 categories: [.translation, .highQuality], tasks: [.translation], contextTokens: 8192, verification: .verified),
    ]

    public static func model(id: String) -> LocalLLM? {
        all.first { $0.id == id }
    }

    /// `downloadModel` の id（"llm-…"）から探す
    public static func model(downloadID: String) -> LocalLLM? {
        all.first { $0.downloadModel.id == downloadID }
    }

    /// 1 つのモデルに使えるメモリの上限（物理メモリの 60%。32GB なら約 19GB）
    public static func memoryBudget(physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory) -> Int64 {
        Int64(Double(physicalMemory) * 0.6)
    }

    /// この Mac で読み込めるか（メモリの目安が上限以内）
    public static func fitsInMemory(_ model: LocalLLM, physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory) -> Bool {
        model.estimatedMemoryBytes <= memoryBudget(physicalMemory: physicalMemory)
    }
}
