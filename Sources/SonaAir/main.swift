import WhisperBatch
import WhisperBatchCore

// Sona Air（AI なし）: AI の機能・モデル・推論エンジンを使わずに起動する
MainActor.assumeIsolated {
    SonaRuntime.configure(edition: .air, ai: nil)
    SonaApp.main()
}
