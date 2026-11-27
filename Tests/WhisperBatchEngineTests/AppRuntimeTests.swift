import Foundation
import Testing
import WhisperBatchCore
@testable import WhisperBatchEngine

/// エディションと AI の実装の組み合わせ（Air は DisabledAIRuntime で、AI の機能を使えない）
@Suite struct AppRuntimeTests {
    init() { TestLocalization.setUp() }

    @Test func airUsesDisabledRuntimeWithoutAIFeatures() {
        let runtime = AppRuntime(edition: .air, ai: nil)
        #expect(!runtime.providesAI)
        #expect(runtime.ai is DisabledAIRuntime)
        #expect(runtime.features.isEmpty)
        #expect(!runtime.availableEngines.contains { $0.requiresAIRuntime })
        #expect(runtime.availableEngines == SpeechEngine.available(hasAIRuntime: false))
    }

    @Test func vantageWithoutImplementationFallsBackToDisabled() {
        // Vantage でも AI の実装を渡さなければ、AI の機能は出さない
        let runtime = AppRuntime(edition: .vantage, ai: nil)
        #expect(!runtime.providesAI)
        #expect(runtime.features.isEmpty)
    }

    @Test func vantageWithImplementationHasAllFeatures() {
        let runtime = AppRuntime(edition: .vantage, ai: DisabledAIRuntime())
        #expect(runtime.providesAI)
        #expect(runtime.features == SonaEdition.vantage.features)
        #expect(runtime.availableEngines == SpeechEngine.available(hasAIRuntime: true))
        #expect(runtime.availableEngines.contains { $0.requiresAIRuntime })
    }

    @Test func disabledRuntimeReportsNotInEditionAndDoesNothing() async {
        let ai = DisabledAIRuntime()
        #expect(ai.appleIntelligenceAvailability(languageCode: "ja") == .notInEdition)
        #expect(await ai.loadedTextModelID() == nil)
        // 解放・消去は何もしない（落ちない）
        await ai.releaseTextModel()
        await ai.shutdownTextModel()
        await ai.invalidateCachedResults(scope: "live")
        await ai.invalidateCachedResults(modelID: "x")
    }

    @Test func disabledRuntimeRefusesTextGeneration() async throws {
        let storage = ModelStorage(directory: FileManager.default.temporaryDirectory)
        await #expect(throws: AIGuidanceError(guidance: .appleIntelligenceUnavailable(.notInEdition))) {
            _ = try await DisabledAIRuntime().textGenerator(for: .appleIntelligence, storage: storage)
        }
    }

    @Test func disabledRuntimeRefusesSpeechLLMWithVantageGuidance() async throws {
        let model = try #require(SpeechEngine.allCases.first { $0.requiresAIRuntime }.map { ModelCatalog.defaultModel(for: $0) })
        let storage = ModelStorage(directory: FileManager.default.temporaryDirectory)
        let error = await #expect(throws: WhisperBatchError.self) {
            _ = try await DisabledAIRuntime().speechTranscriber(for: model, storage: storage)
        }
        #expect(error == .onDeviceAIUnavailable(reason: L("engine.requiresVantage", model.engine.displayName)))
    }
}
