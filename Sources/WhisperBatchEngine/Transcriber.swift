import Foundation
import WhisperBatchCore

/// 読み込んだモデル（またはOSの音声認識）で 1 ファイルずつ文字起こしする
public protocol Transcriber: AnyObject, Sendable {
    /// - Parameter progress: 0...1。任意のスレッドから呼ばれる。
    func transcribe(fileURL: URL, options: TranscriptionOptions,
                    progress: @escaping @Sendable (Double) -> Void) async throws -> Transcript
}

extension WhisperContext: Transcriber {
    public func transcribe(fileURL: URL, options: TranscriptionOptions,
                           progress: @escaping @Sendable (Double) -> Void) async throws -> Transcript {
        try await TranscriptionEngine.transcribe(fileURL: fileURL, context: self, options: options, progress: progress)
    }
}

public enum TranscriberLoader {
    /// モデルを読み込む。Apple の音声認識は言語ごとに用意されているかを確かめる。
    /// - Parameter ai: Vantage の AI の実装（llama.cpp で動かす Qwen3-ASR・Granite Speech に必要。Air では nil）
    public static func load(_ model: SpeechModel, storage: ModelStorage?, language: LanguageOption,
                            ai: (any AIRuntime)? = nil) async throws -> any Transcriber {
        switch model.engine {
        case .whisper:
            guard let storage, let file = model.files.first, storage.isInstalled(model) else {
                throw WhisperBatchError.modelNotInstalled(modelName: model.displayName)
            }
            try await storage.verifyContents(of: model)
            return try await WhisperContext.load(model: model, fileURL: storage.fileURL(for: file, of: model))
        case .reazonSpeech:
            guard let storage, storage.isInstalled(model) else {
                throw WhisperBatchError.modelNotInstalled(modelName: model.displayName)
            }
            try await storage.verifyContents(of: model)
            return try await ReazonSpeechContext.load(model: model, directory: storage.directory(for: model))
        case .apple:
            return try await AppleSpeechTranscriber.make(model: model, language: language)
        case .qwen3ASR, .graniteSpeech:
            guard let storage, storage.isInstalled(model) else {
                throw WhisperBatchError.modelNotInstalled(modelName: model.displayName)
            }
            guard let ai else {
                throw WhisperBatchError.onDeviceAIUnavailable(reason: L("engine.requiresVantage", model.engine.displayName))
            }
            try await storage.verifyContents(of: model)
            return try await ai.speechTranscriber(for: model, storage: storage)
        }
    }
}
