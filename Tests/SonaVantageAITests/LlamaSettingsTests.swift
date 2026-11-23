import Foundation
import Testing
@testable import SonaLLM

// 推論の設定と、結果の再利用の条件（モデルは使わない）
@Suite("llama.cpp の推論の設定")
struct LlamaSettingsTests {
    @Test("アプリの設定の条件の文字列は以前の版と同じ（保存済みの結果をそのまま使える）")
    func standardSignatureIsUnchanged() {
        let standard = LlamaLoadConfig.standard
        #expect(standard.batch == 512 && standard.ubatch == 512 && standard.gpuLayers == -1)
        #expect(standard.cacheK == .f16 && standard.cacheV == .f16)
        let threads = max(2, min(8, ProcessInfo.processInfo.activeProcessorCount - 2))
        #expect(LlamaInferenceSettings.signature
            == "llama.cpp b11976;gpu_layers=-1;n_batch=512;n_ubatch=512;n_seq_max=1;threads=\(threads)"
            + ";top_k=40;top_p=0.9;temp=0.3;seed=1234")
    }

    @Test("読み込みの設定が 1 つでも変われば、条件の文字列も変わる")
    func everySettingChangesSignature() {
        let base = LlamaInferenceSettings.signature(for: .standard)
        var variants: [LlamaLoadConfig] = []
        var c = LlamaLoadConfig.standard
        c.batch = 2048; variants.append(c)
        c = .standard; c.ubatch = 256; variants.append(c)
        c = .standard; c.threads += 1; variants.append(c)
        c = .standard; c.gpuLayers = 0; variants.append(c)
        c = .standard; c.cacheK = .q8_0; variants.append(c)
        c = .standard; c.cacheV = .q8_0; variants.append(c)
        let signatures = variants.map { LlamaInferenceSettings.signature(for: $0) }
        #expect(!signatures.contains(base))
        #expect(Set(signatures).count == signatures.count)
    }
}
