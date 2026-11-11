import Foundation

/// ローカルの言語モデルに渡す入力の形式（モデルの系列ごと）。
///
/// llama.cpp のライブラリは Jinja のテンプレートを実行しないため、各モデルの GGUF に入っているテンプレートを
/// 描画した結果（2026-11 に確認）と同じ文字列をここで組み立てる。思考（推論の過程）を出力するモデルは、
/// テンプレートが用意している方法で思考を止める（止められない形式は、最終の回答だけを取り出す）。
public enum ChatFormat: String, Sendable, Codable, CaseIterable {
    /// ChatML（Qwen2.5 系。TinySwallow）
    case chatML
    /// ChatML ＋ 空の思考（Qwen3。テンプレートの enable_thinking=false と同じ）
    case qwen3NoThinking
    /// ChatML ＋ 空の思考（Granite 4.2。テンプレートの enable_thinking=false と同じ）
    case graniteNoThinking
    /// Llama 3（ELYZA）
    case llama3
    /// Gemma 4（既定で思考しない）
    case gemma4
    /// Mistral（Ministral 3）
    case mistral3
    /// Phi-4
    case phi4
    /// Harmony 形式（LLM-jp-4.1。推論は low にして、final の回答だけを取り出す）
    case harmonyLLMJP
    /// Harmony 形式（gpt-oss）
    case harmonyGPTOSS
    /// PLaMo 3 翻訳（翻訳専用の形式）
    case plamoTranslate

    /// 指示と依頼から入力の文字列を作る（BOS などの特別なトークンも文字列として含める。
    /// トークン化するときに特別なトークンとして読み取らせる）
    public func render(system: String, user: String, date: Date = Date()) -> String {
        switch self {
        case .chatML:
            return "<|im_start|>system\n\(system)<|im_end|>\n<|im_start|>user\n\(user)<|im_end|>\n<|im_start|>assistant\n"
        case .qwen3NoThinking:
            return "<|im_start|>system\n\(system)<|im_end|>\n<|im_start|>user\n\(user)<|im_end|>\n<|im_start|>assistant\n<think>\n\n</think>\n\n"
        case .graniteNoThinking:
            return "<|im_start|>system\n\(system)<|im_end|>\n<|im_start|>user\n\(user)<|im_end|>\n<|im_start|>assistant\n<think></think>"
        case .llama3:
            return "<|begin_of_text|><|start_header_id|>system<|end_header_id|>\n\n\(system.trimmingCharacters(in: .whitespacesAndNewlines))<|eot_id|>"
                + "<|start_header_id|>user<|end_header_id|>\n\n\(user.trimmingCharacters(in: .whitespacesAndNewlines))<|eot_id|>"
                + "<|start_header_id|>assistant<|end_header_id|>\n\n"
        case .gemma4:
            return "<bos><|turn>system\n\(system)<turn|>\n<|turn>user\n\(user)<turn|>\n<|turn>model\n"
        case .mistral3:
            return "<s>[SYSTEM_PROMPT]\(system)[/SYSTEM_PROMPT][INST]\(user)[/INST]"
        case .phi4:
            return "<|im_start|>system<|im_sep|>\(system)<|im_end|><|im_start|>user<|im_sep|>\(user)<|im_end|><|im_start|>assistant<|im_sep|>"
        case .harmonyLLMJP:
            return Self.harmony(identity: "You are LLM-jp-4, a large language model trained by LLM-jp.\nKnowledge cutoff: 2025-12",
                                system: system, user: user, date: date)
        case .harmonyGPTOSS:
            return Self.harmony(identity: "You are ChatGPT, a large language model trained by OpenAI.\nKnowledge cutoff: 2024-06",
                                system: system, user: user, date: date)
        case .plamoTranslate:
            // 翻訳専用。指示は使わず、依頼の文を訳す（言語は translateInput で指定する）
            return Self.plamo(text: user, source: nil, target: nil)
        }
    }

    /// 翻訳専用の形式の入力（PLaMo 3 翻訳）。言語コードは ja / en / zh-hans など。
    public static func plamo(text: String, source: String?, target: String?) -> String {
        var s = "<|plamo:bos|><|plamo:tag|>dataset<|plamo:msg|>translation<|plamo:tag|>input"
        if let source { s += "<|plamo:key|>lang<|plamo:val|>\(source)" }
        s += "<|plamo:msg|>\(text)<|plamo:tag|>output"
        if let target { s += "<|plamo:key|>lang<|plamo:val|>\(target)" }
        return s + "<|plamo:msg|>"
    }

    /// 生成を止める文字列（モデルの終わりのトークンとは別に、これが出たら止める）
    public var stopStrings: [String] {
        switch self {
        case .chatML, .qwen3NoThinking, .graniteNoThinking: ["<|im_end|>", "<|endoftext|>"]
        case .llama3: ["<|eot_id|>"]
        case .gemma4: ["<turn|>"]
        case .mistral3: ["</s>"]
        case .phi4: ["<|im_end|>"]
        case .harmonyLLMJP, .harmonyGPTOSS: ["<|return|>", "<|call|>"]
        case .plamoTranslate: ["<|plamo:tag|>", "<|plamo:bos|>", "<|plamo:eos|>"]
        }
    }

    /// 返答から回答の文だけを取り出す（思考・チャンネルの印・終わりの印を除く）
    public func extractAnswer(_ raw: String) -> String {
        var text = raw
        for stop in stopStrings {
            if let r = text.range(of: stop) { text = String(text[..<r.lowerBound]) }
        }
        switch self {
        case .harmonyLLMJP, .harmonyGPTOSS:
            // final チャンネルの本文だけを使う（analysis＝思考の過程は使わない）。
            // 本家の llama.cpp では LLM-jp-4.1 の特別なトークンの後に空白が入る（「<|channel|> final<|message|> …」）ので、
            // 空白があっても読み取る
            if let r = text.range(of: #"<\|channel\|>\s*final\s*<\|message\|>"#, options: [.regularExpression, .backwards]) {
                text = String(text[r.upperBound...])
            } else if text.contains("<|channel|>") {
                // 最終の回答まで届かなかった（思考の途中で長さの上限に達した）
                return ""
            }
            text = text.replacingOccurrences(of: "<|end|>", with: "")
        default:
            text = Self.removingThinking(text)
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `<think>…</think>` を除く（閉じていない思考は、回答がないものとして空にする）
    static func removingThinking(_ text: String) -> String {
        var s = text
        while let open = s.range(of: "<think>") {
            if let close = s.range(of: "</think>", range: open.upperBound ..< s.endIndex) {
                s.removeSubrange(open.lowerBound ..< close.upperBound)
            } else {
                s.removeSubrange(open.lowerBound ..< s.endIndex)
            }
        }
        return s
    }

    private static func harmony(identity: String, system: String, user: String, date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = "yyyy-MM-dd"
        return "<|start|>system<|message|>\(identity)\nCurrent date: \(f.string(from: date))\n\nReasoning: low\n\n"
            + "# Valid channels: analysis, commentary, final. Channel must be included for every message.<|end|>"
            + "<|start|>developer<|message|># Instructions\n\n\(system)\n\n<|end|>"
            + "<|start|>user<|message|>\(user)<|end|><|start|>assistant"
    }
}
