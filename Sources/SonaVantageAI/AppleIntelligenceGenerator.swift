import Foundation
import FoundationModels
import WhisperBatchCore

/// Apple Intelligence の端末内のモデル（FoundationModels の `SystemLanguageModel.default`）で文章を生成する。
///
/// - 使うのは端末内のモデルだけ。FoundationModels には Private Cloud Compute のサーバーのモデル
///   （`PrivateCloudComputeLanguageModel`）もあるが、このアプリは使わない（参照もしない。テストで確かめている）。
///   `LanguageModelSession` には端末内のモデルを明示的に渡す。
/// - モデルは macOS が管理する。Apple Intelligence に対応していない Mac・オフのときは使えない。
struct AppleIntelligenceGenerator: TextGenerator {
    /// 端末内のモデル（明示的に指定する）
    private static var onDeviceModel: SystemLanguageModel { SystemLanguageModel.default }

    var displayName: String { AITextEngine.appleIntelligence.displayName }

    /// 端末内のモデルの文脈は 4096 トークン程度（2026-11 時点の SDK で 8192）。指示と返答の分を残して小さめに区切る。
    var maxInputCharacters: Int { 1_800 }

    static func availability(languageCode: String?) -> AIAvailability {
        let model = onDeviceModel
        switch model.availability {
        case .available:
            if let code = languageCode, !model.supportsLocale(Locale(identifier: code)) { return .unsupportedLanguage }
            return .available
        case .unavailable(.deviceNotEligible): return .deviceNotEligible
        case .unavailable(.appleIntelligenceNotEnabled): return .notEnabled
        case .unavailable(.modelNotReady): return .modelNotReady
        default: return .unavailable
        }
    }

    func generate(_ request: GenerationRequest) async throws -> String {
        let session = LanguageModelSession(model: Self.onDeviceModel, instructions: request.instructions)
        let options = request.greedy
            ? GenerationOptions(samplingMode: .greedy, maximumResponseTokens: request.maxTokens)
            : GenerationOptions(temperature: 0.3, maximumResponseTokens: request.maxTokens)
        do {
            return try await session.respond(to: request.prompt, options: options).content
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as LanguageModelError {
            throw WhisperBatchError.onDeviceAIFailed(detail: Self.describe(error))
        } catch {
            throw WhisperBatchError.onDeviceAIFailed(detail: (error as NSError).localizedDescription)
        }
    }

    private static func describe(_ error: LanguageModelError) -> String {
        switch error {
        case .contextSizeExceeded: L("ai.error.tooLong")
        case .guardrailViolation, .refusal: L("ai.error.refused")
        case .unsupportedLanguageOrLocale: L("ai.availability.unsupportedLanguage")
        case .rateLimited: L("ai.error.busy")
        default: error.localizedDescription
        }
    }
}
