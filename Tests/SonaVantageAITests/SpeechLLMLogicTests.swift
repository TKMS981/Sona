import Foundation
import Testing
import WhisperBatchCore
@testable import SonaLLM

// 音声を読む言語モデル（Qwen3-ASR・Granite Speech）の、モデルを使わない部分
@Suite("音声を読む言語モデルの入出力")
struct SpeechLLMLogicTests {
    init() { TestLocalization.setUp() }

    @Test("Qwen3-ASR: 自動判定の返答から言語と本文を取り出す")
    func qwenParsesDetectedLanguage() {
        let r = LlamaSpeechRecognizer.parse(family: .qwen3ASR, raw: "language Japanese<asr_text>本日は晴天なり。", forcedLanguage: nil)
        #expect(r.text == "本日は晴天なり。")
        #expect(r.languageCode == "ja")
        let en = LlamaSpeechRecognizer.parse(family: .qwen3ASR, raw: "language English<asr_text> Hello there.<|im_end|>", forcedLanguage: nil)
        #expect(en.text == "Hello there.")
        #expect(en.languageCode == "en")
    }

    @Test("Qwen3-ASR: 言語を指定したときは返答がそのまま本文")
    func qwenForcedLanguage() {
        let r = LlamaSpeechRecognizer.parse(family: .qwen3ASR, raw: "これはテストです。", forcedLanguage: "ja")
        #expect(r.text == "これはテストです。")
        #expect(r.languageCode == "ja")
        let prompt = LlamaSpeechRecognizer.prompt(family: .qwen3ASR, marker: "<M>", languageCode: "ja")
        #expect(prompt == "<|im_start|>user\n<M><|im_end|>\n<|im_start|>assistant\nlanguage Japanese<asr_text>")
        let auto = LlamaSpeechRecognizer.prompt(family: .qwen3ASR, marker: "<M>", languageCode: nil)
        #expect(auto.hasSuffix("<|im_start|>assistant\n"))
    }

    @Test("Granite: 音声の後ろに指示を置き、言語を指定するときは言語名を書く")
    func granitePrompt() {
        let ja = LlamaSpeechRecognizer.prompt(family: .graniteSpeech, marker: "<M>", languageCode: "ja")
        #expect(ja.hasPrefix("USER: <M>The speech is in Japanese."))
        #expect(ja.hasSuffix("\n ASSISTANT:"))
        let auto = LlamaSpeechRecognizer.prompt(family: .graniteSpeech, marker: "<M>", languageCode: nil)
        #expect(auto == "USER: <M>transcribe the speech with proper punctuation and capitalization.\n ASSISTANT:")
    }

    @Test("全角の英数字だけを半角にし、カタカナ・句読点は変えない")
    func halfwidth() {
        #expect(LlamaSpeechRecognizer.halfwidthASCII("生成ａｉ基礎の第３回。カタカナ！") == "生成ai基礎の第3回。カタカナ!")
    }

    @Test("同じ並びが続く生成を繰り返しとみなし、1 回分だけ残す")
    func repetition() {
        #expect(LlamaSpeechRecognizer.isRepeating(Array(repeating: 7, count: 12)))
        #expect(!LlamaSpeechRecognizer.isRepeating(Array(repeating: 7, count: 11)))
        #expect(LlamaSpeechRecognizer.isRepeating([1, 2, 3] + Array(repeating: [4, 5], count: 4).flatMap { $0 }))
        #expect(!LlamaSpeechRecognizer.isRepeating(Array(1 ... 100)))
        #expect(LlamaSpeechRecognizer.trimRepetition("はい。ありがとうございます。ありがとうございます。ありがとうございます。") == "はい。ありがとうございます。")
        #expect(LlamaSpeechRecognizer.trimRepetition("普通の文です。") == "普通の文です。")
    }

    @Test("Qwen3-ASR・Granite は AI の実装があるときだけ選べ、対応言語が正しい")
    func engines() {
        #expect(!SpeechEngine.available(hasAIRuntime: false).contains(.qwen3ASR))
        #expect(!SpeechEngine.available(hasAIRuntime: false).contains(.graniteSpeech))
        #expect(SpeechEngine.available(hasAIRuntime: true) == SpeechEngine.allCases)
        #expect(SpeechEngine.qwen3ASR.languageOptions == LanguageOption.allCases)
        #expect(SpeechEngine.graniteSpeech.languageOptions == [.auto, .japanese, .english, .spanish, .french, .german])
        for engine in [SpeechEngine.qwen3ASR, .graniteSpeech] {
            let model = ModelCatalog.defaultModel(for: engine)
            #expect(model.files.count == 2, "本体と音声エンコーダー")
            #expect(model.files[1].name.hasPrefix("mmproj"))
            #expect(model.folder != nil)
            #expect(!model.displayName.hasPrefix("model."))
        }
    }
}
