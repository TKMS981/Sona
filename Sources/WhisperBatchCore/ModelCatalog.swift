import Foundation

/// 文字起こしエンジン（認識方式）
public enum SpeechEngine: String, CaseIterable, Identifiable, Sendable {
    /// whisper.cpp で動かす OpenAI Whisper
    case whisper
    /// sherpa-onnx で動かす ReazonSpeech（日本語専用）
    case reazonSpeech
    /// macOS 標準の音声認識（Speech フレームワークの SpeechAnalyzer）
    case apple
    /// llama.cpp で動かす Qwen3-ASR（Alibaba。音声を直接読む言語モデル。Vantage だけ）
    case qwen3ASR
    /// llama.cpp で動かす Granite Speech（IBM。音声を直接読む言語モデル。Vantage だけ）
    case graniteSpeech

    public var id: String { rawValue }

    /// 表示名と説明（表示言語に従う）
    public var displayName: String { L("engine.\(rawValue).name") }
    public var summary: String { L("engine.\(rawValue).summary") }

    /// 取得元とライセンスの説明
    public var sourceDescription: String { L("engine.\(rawValue).source") }

    /// ファイルをダウンロードしてアプリ内に保存するか（Apple は OS が言語データを管理する）
    public var usesDownloadedFiles: Bool { self != .apple }

    /// AI の実装（llama.cpp。Vantage だけにある `AIRuntime`）が必要か。Air ではこの方式を表示しない。
    public var requiresAIRuntime: Bool {
        switch self {
        case .qwen3ASR, .graniteSpeech: true
        case .whisper, .reazonSpeech, .apple: false
        }
    }

    /// 選べる方式（AI の実装がなければ、それが必要な方式を除く）
    public static func available(hasAIRuntime: Bool) -> [SpeechEngine] {
        allCases.filter { hasAIRuntime || !$0.requiresAIRuntime }
    }

    /// 文字起こしの言語に対応しているか。Apple の実際の対応言語は OS に問い合わせて確かめる。
    public func supports(_ language: LanguageOption) -> Bool {
        switch self {
        case .whisper: true
        case .reazonSpeech: language == .japanese
        case .apple: language != .auto
        // Qwen3-ASR は 30 言語（一覧の言語はすべて）と自動判定
        case .qwen3ASR: true
        // Granite Speech 5.0 は英・仏・独・西・葡・日の 6 言語（言語を指定しなければ、この中から判定して書き起こす）
        case .graniteSpeech: [.auto, .japanese, .english, .french, .german, .spanish].contains(language)
        }
    }

    /// 言語の選択肢（この方式で選べるもの）
    public var languageOptions: [LanguageOption] {
        LanguageOption.allCases.filter { supports($0) }
    }

    public var defaultModelID: String {
        switch self {
        case .whisper: "large-v3-turbo-q5_0"
        case .reazonSpeech: "reazonspeech-k2-v2-int8"
        case .apple: "apple-speech"
        case .qwen3ASR: "qwen3-asr-1.7b"
        case .graniteSpeech: "granite-speech-5.0-2b"
        }
    }
}

/// モデルを構成する 1 ファイル
public struct ModelFile: Hashable, Sendable {
    /// 保存するファイル名
    public let name: String
    public let url: URL
    /// ダウンロードサイズ（バイト）
    public let sizeBytes: Int64
    /// SHA-256（Hugging Face の LFS メタデータと同じ値。LFS 外のファイルは取得して確認した値）
    public let sha256: String

    public init(name: String, url: URL, sizeBytes: Int64, sha256: String) {
        self.name = name
        self.url = url
        self.sizeBytes = sizeBytes
        self.sha256 = sha256
    }
}

/// モデルの用途
public enum ModelPurpose: String, Sendable {
    /// 文字起こし
    case transcription
    /// 話者識別（文字起こしの結果に話者を付ける。sherpa-onnx で動かす）
    case speakerDiarization
    /// ローカルの言語モデル（AI の修正・整形・要約・翻訳。llama.cpp で動かす。`LocalLLMCatalog`）
    case textGeneration
}

/// 文字起こしモデル（と、話者識別などの補助のモデル）
public struct SpeechModel: Identifiable, Hashable, Sendable {
    public let id: String
    /// 認識方式。補助のモデルでは、動かすライブラリが同じ方式（話者識別は sherpa-onnx なので ReazonSpeech）にする。
    public let engine: SpeechEngine
    /// ダウンロードするファイル（Apple のモデルは空）
    public let files: [ModelFile]
    /// 保存先フォルダ内のサブフォルダ（nil なら保存先の直下。Whisper は以前の版と同じ場所に置く）
    public let folder: String?
    public let purpose: ModelPurpose

    public init(id: String, engine: SpeechEngine, files: [ModelFile], folder: String? = nil,
                purpose: ModelPurpose = .transcription) {
        self.id = id
        self.engine = engine
        self.files = files
        self.folder = folder
        self.purpose = purpose
    }

    /// 表示名と説明（表示言語に従う。ローカルの言語モデルはモデル名）
    public var displayName: String {
        if purpose == .textGeneration, let llm = LocalLLMCatalog.all.first(where: { id.hasPrefix("llm-\($0.id)") }) {
            return llm.displayName
        }
        return L("model.\(id).name")
    }
    public var summary: String {
        purpose == .textGeneration ? "" : L("model.\(id).summary")
    }

    public var isDownloadable: Bool { !files.isEmpty }

    /// ダウンロードサイズの合計（バイト）
    public var sizeBytes: Int64 { files.reduce(0) { $0 + $1.sizeBytes } }

    /// 必要な空き容量の目安。ダウンロード中の一時ファイル分として 10% と 50MB の余裕を見る。
    public var requiredFreeSpace: Int64 {
        sizeBytes + max(sizeBytes / 10, 50_000_000)
    }

    /// サイズの表示。OS が管理するモデルはサイズを表示しない。
    public var sizeText: String {
        isDownloadable ? ByteCountFormatter.fileSize.string(fromByteCount: sizeBytes) : L("model.size.osManaged")
    }

    public var requiredSpaceText: String { ByteCountFormatter.fileSize.string(fromByteCount: requiredFreeSpace) }

    public var isDefaultForEngine: Bool { id == engine.defaultModelID }
}

public enum ModelCatalog {
    public static let all: [SpeechModel] = whisper + reazonSpeech + apple + speechLLM

    /// whisper.cpp 用（ggml 形式）。多言語モデルのみ（日本語を扱うため .en モデルは含めない）。
    /// https://huggingface.co/ggerganov/whisper.cpp から、コミットを固定して取得する。
    /// サイズと SHA-256 はそのコミットの LFS メタデータの値（2026-10 確認）。
    static let whisper: [SpeechModel] = [
        whisperModel("tiny", "ggml-tiny.bin", 77_691_713,
                     "be07e048e1e599ad46341c8d2a135645097a538221678b7acdd1b1919c6e1b21"),
        whisperModel("base", "ggml-base.bin", 147_951_465,
                     "60ed5bc3dd14eea856493d334349b405782ddcaf0028d4b5df4088345fba2efe"),
        whisperModel("small", "ggml-small.bin", 487_601_967,
                     "1be3a9b2063867b937e64e2ec7483364a79917e157fa98c5d94b5c1fffea987b"),
        whisperModel("medium", "ggml-medium.bin", 1_533_763_059,
                     "6c14d5adee5f86394037b4e4e8b59f1673b6cee10e3cf0b11bbdbee79c156208"),
        whisperModel("large-v3-turbo-q5_0", "ggml-large-v3-turbo-q5_0.bin", 574_041_195,
                     "394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2"),
        whisperModel("large-v3-turbo", "ggml-large-v3-turbo.bin", 1_624_555_275,
                     "1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69"),
        whisperModel("large-v3", "ggml-large-v3.bin", 3_095_033_483,
                     "64d182b440b98d5203c4f9bd541544d84c605196c4f7b845dfa11fb23594d1e2"),
    ]

    /// ReazonSpeech k2 v2（Zipformer RNN-T、159M パラメーター、Apache-2.0）。
    /// 公式リポジトリ https://huggingface.co/reazon-research/reazonspeech-k2-v2 の ONNX ファイルを、
    /// コミットを固定して取得する。サイズと SHA-256 は LFS メタデータの値（tokens.txt は取得して確認、2026-10）。
    static let reazonSpeech: [SpeechModel] = [
        SpeechModel(id: "reazonspeech-k2-v2-int8", engine: .reazonSpeech, files: [
            reazonFile("encoder-epoch-99-avg-1.int8.onnx", 154_670_139,
                       "2c7bd08a8a99f9ddd0d9e458456577b1f6279214e51426f114f9eced44c54e1d"),
            reazonFile("decoder-epoch-99-avg-1.int8.onnx", 2_959_337,
                       "8f0bff94d38797b03b762634ed03211a8e303d06cc4603cdd0cf4199d6eb1485"),
            reazonFile("joiner-epoch-99-avg-1.int8.onnx", 2_696_970,
                       "49cc7ea1d3d35a40a27442db5e89996da64bf0e683a903dce76e99e57a12e4de"),
            reazonTokens,
        ], folder: "reazonspeech-k2-v2-int8"),
        SpeechModel(id: "reazonspeech-k2-v2", engine: .reazonSpeech, files: [
            reazonFile("encoder-epoch-99-avg-1.onnx", 592_347_848,
                       "ecdb0b771e16104aaf8e579cb3c1e32fbd589eb641c5946d82b615bd366c5f96"),
            reazonFile("decoder-epoch-99-avg-1.onnx", 11_767_836,
                       "58b18211ae06265466bfa17172dab574df94f76c8bcb61a3640c28ba860e4124"),
            reazonFile("joiner-epoch-99-avg-1.onnx", 10_720_115,
                       "d38a81d1191c9ed6de6a1719503692e07e3e973e2364adde0abae5eaaded1174"),
            reazonTokens,
        ], folder: "reazonspeech-k2-v2"),
    ]

    /// 話者識別のモデル（文字起こしのモデルの一覧 `all` には含めない）。
    /// - 発話区間の検出: pyannote segmentation-3.0（MIT、CNRS）を sherpa-onnx 用に変換したもの
    /// - 話者の特徴: 3D-Speaker CAM++（中国語・英語で学習、Apache-2.0）
    /// どちらも https://huggingface.co/csukuangfj の sherpa-onnx 用の変換済みファイルを、コミットを固定して取得する。
    /// サイズと SHA-256 は LFS メタデータの値（取得して一致を確認、2026-11）。
    public static let speakerDiarization = SpeechModel(id: "speaker-diarization", engine: .reazonSpeech, files: [
        ModelFile(name: "pyannote-segmentation-3-0.onnx",
                  url: URL(string: "https://huggingface.co/csukuangfj/sherpa-onnx-pyannote-segmentation-3-0/resolve/9403a6902bb58e3d5ae8c7e77c3422de279db2e0/model.onnx")!,
                  sizeBytes: 5_992_913, sha256: "220ad67ca923bef2fa91f2390c786097bf305bceb5e261d4af67b38e938e1079"),
        ModelFile(name: "3dspeaker-campplus-zh-en-advanced.onnx",
                  url: URL(string: "https://huggingface.co/csukuangfj/speaker-embedding-models/resolve/0743f301363dec56491a490f6d6cbc9d67f9a3bf/3dspeaker_speech_campplus_sv_zh_en_16k-common_advanced.onnx")!,
                  sizeBytes: 28_281_164, sha256: "aa3cfc16963a10586a9393f5035d6d6b57e98d358b347f80c2a30bf4f00ceba2"),
    ], folder: "speaker-diarization", purpose: .speakerDiarization)

    /// 文字起こし以外の、ダウンロードして使うモデル
    public static let auxiliary: [SpeechModel] = [speakerDiarization]

    /// 音声を直接読む言語モデル（llama.cpp のマルチモーダルで動かす。Vantage だけ）。
    /// どちらもモデル本体の GGUF と音声エンコーダー（mmproj）の GGUF の 2 つで、1 つめが本体・2 つめがエンコーダー。
    /// 量子化はモデルの公開元が推奨・既定とするもの（Granite は本体 Q8_0 とエンコーダー f16。Qwen3-ASR はどちらも Q8_0）。
    /// コミットを固定して取得する。サイズと SHA-256 はそのコミットの LFS メタデータの値（2026-11 確認）。
    static let speechLLM: [SpeechModel] = [
        // Qwen3-ASR 1.7B（Apache-2.0）。llama.cpp の公式の変換（ggml-org）
        SpeechModel(id: "qwen3-asr-1.7b", engine: .qwen3ASR, files: [
            hfFile("ggml-org/Qwen3-ASR-1.7B-GGUF", qwen3ASRRevision, "Qwen3-ASR-1.7B-Q8_0.gguf", 2_165_035_232,
                   "cd5f5ce9d7c9c03ff47d54d7f2726e63a39e61e3001640c5d08b6e4d3aed1e6d"),
            hfFile("ggml-org/Qwen3-ASR-1.7B-GGUF", qwen3ASRRevision, "mmproj-Qwen3-ASR-1.7B-Q8_0.gguf", 355_709_376,
                   "24eaf9a96fa94fe36ed0c1de68d44cccdb3f2229ee614e5b1b5bab951bc37883"),
        ], folder: "qwen3-asr-1.7b"),
        // Granite Speech 5.0 2B（Apache-2.0）。IBM の公式の GGUF
        SpeechModel(id: "granite-speech-5.0-2b", engine: .graniteSpeech, files: [
            hfFile("ibm-granite/granite-speech-5.0-2b-GGUF", graniteSpeechRevision, "granite-speech-5.0-2b-Q8_0.gguf", 1_956_155_104,
                   "4972786fa455b71ee1f020e8ae1b147ca6cd2b1e5b0818048011d7f1da242790"),
            hfFile("ibm-granite/granite-speech-5.0-2b-GGUF", graniteSpeechRevision, "mmproj-model-f16.gguf", 1_159_354_752,
                   "c0d108e1a3cf345b22c411245fc2762319f1c6b6e56bb15bdffe748c9342ca7d"),
        ], folder: "granite-speech-5.0-2b"),
    ]

    /// macOS 標準の音声認識。言語データは OS がダウンロード・管理する。
    static let apple: [SpeechModel] = [
        SpeechModel(id: "apple-speech", engine: .apple, files: []),
        SpeechModel(id: "apple-dictation", engine: .apple, files: []),
    ]

    /// 以前の版の既定（設定が保存されていないときに使う）
    public static let defaultModelID = SpeechEngine.whisper.defaultModelID

    public static var defaultModel: SpeechModel { model(id: defaultModelID)! }

    public static func model(id: String) -> SpeechModel? {
        all.first { $0.id == id }
    }

    public static func models(for engine: SpeechEngine) -> [SpeechModel] {
        all.filter { $0.engine == engine }
    }

    public static func defaultModel(for engine: SpeechEngine) -> SpeechModel {
        model(id: engine.defaultModelID)!
    }

    // MARK: 定義用

    /// ggerganov/whisper.cpp のコミット（2024-10-29 更新）。main が更新されても同じファイルを取得できるよう固定する。
    private static let whisperRevision = "5359861c739e955e79d9a303bcbc70fb988958b1"

    private static func whisperModel(_ id: String, _ fileName: String, _ size: Int64, _ sha256: String) -> SpeechModel {
        let url = URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/\(whisperRevision)/\(fileName)")!
        return SpeechModel(id: id, engine: .whisper,
                           files: [ModelFile(name: fileName, url: url, sizeBytes: size, sha256: sha256)])
    }

    /// ggml-org/Qwen3-ASR-1.7B-GGUF（2026-11-21 更新）
    private static let qwen3ASRRevision = "3b2c29585c2180452ccb14d3b6b58127f352400d"
    /// ibm-granite/granite-speech-5.0-2b-GGUF（2026-11-19 更新）
    private static let graniteSpeechRevision = "3205b0b3adbd6c4982fb502f40503d668b63b145"

    private static func hfFile(_ repo: String, _ revision: String, _ name: String, _ size: Int64, _ sha256: String) -> ModelFile {
        ModelFile(name: name, url: URL(string: "https://huggingface.co/\(repo)/resolve/\(revision)/\(name)")!,
                  sizeBytes: size, sha256: sha256)
    }

    private static let reazonRevision = "291488c8151be24d7da4bf7af26e533fad96e407"

    private static func reazonFile(_ name: String, _ size: Int64, _ sha256: String) -> ModelFile {
        let url = URL(string: "https://huggingface.co/reazon-research/reazonspeech-k2-v2/resolve/\(reazonRevision)/\(name)")!
        return ModelFile(name: name, url: url, sizeBytes: size, sha256: sha256)
    }

    private static let reazonTokens = reazonFile("tokens.txt", 45_754,
                                                 "2c3ac659818a48a0c04010e0593bbc4d7c8a24a054340b01131499c05fd52def")
}
