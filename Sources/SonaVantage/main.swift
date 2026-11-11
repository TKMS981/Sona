import SonaVantageAI
import WhisperBatch
import WhisperBatchCore

// Sona Vantage（AI 搭載）: ローカルの言語モデル・Apple Intelligence（端末内のモデル）・話者識別を使えるようにして起動する
MainActor.assumeIsolated {
    SonaRuntime.configure(edition: .vantage, ai: VantageAIRuntime())
    SonaApp.main()
}
