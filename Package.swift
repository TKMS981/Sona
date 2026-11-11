// swift-tools-version: 6.2
import PackageDescription

// whisper.cpp 公式リリースの XCFramework（v1.9.5 と同じビルド b5454）。
// チェックサムで内容を固定しているので、別のファイルに差し替わるとビルドが失敗します。
let whisperFramework = Target.binaryTarget(
    name: "whisper",
    url: "https://github.com/ggml-org/whisper.cpp/releases/download/b5454/whisper-b5454-xcframework.zip",
    checksum: "e57f8c48933000acabc13bb913fbe82805d483a2deff692cc6738836bd92393b"
)

// sherpa-onnx 公式リリースの macOS 用 XCFramework（v1.13.8、onnxruntime を静的に含む動的ライブラリ）。
// ReazonSpeech モデルの実行（Air と Vantage の両方）と、話者識別（Vantage だけ）に使う。
// チェックサムは GitHub のリリース情報（digest）と同じ値。
let sherpaOnnxFramework = Target.binaryTarget(
    name: "SherpaOnnxC",
    url: "https://github.com/k2-fsa/sherpa-onnx/releases/download/xcframework/sherpa-onnx-v1.13.8-macos-shared-onnxruntime-static.xcframework.zip",
    checksum: "82d5cb3af38c3cb4871c3532a6c7dc86d6b7db1077bcc9d6a1047100976f199b"
)

// llama.cpp 公式リリースの XCFramework（b11976、2026-10-29）。ローカルの言語モデル（GGUF）の実行に使う（Vantage だけ）。
// チェックサムは GitHub のリリース情報（digest）と同じ値。whisper.framework とは別に ggml を内蔵しているため、
// whisper と同じ Swift のモジュールからは読み込まない（SonaLLM だけが読み込む）。
let llamaFramework = Target.binaryTarget(
    name: "llama",
    url: "https://github.com/ggml-org/llama.cpp/releases/download/b11976/llama-b11976-xcframework.zip",
    checksum: "3e69f01ad8ca7d36b213395e516c1cf51d1c10153a0c2a734babca5d4af8fdfa"
)

let package = Package(
    name: "Sona",
    defaultLocalization: "ja",
    platforms: [.macOS("27.0")],
    products: [
        // Sona Vantage（AI 搭載）。これまでと同じ実行ファイル名 Sona で作る。
        .executable(name: "Sona", targets: ["SonaVantage"]),
        // Sona Air（AI なし）。AI のモデル・推論エンジン（llama.cpp・FoundationModels・話者識別）にリンクしない。
        .executable(name: "SonaAir", targets: ["SonaAir"]),
    ],
    dependencies: [
        // MP3 エンコーダー（LGPL）。ソースは scripts/fetch-lame.sh で取得する。
        .package(path: "ThirdParty/LAME"),
    ],
    targets: [
        // UI に依存しないロジック（キュー、状態遷移、重複判定、出力フォーマット、チャンク分割、編集、
        // AI 処理の手順・検査・モデルの選び方。AI のランタイムには依存しない）
        .target(name: "WhisperBatchCore"),
        // whisper.cpp / sherpa-onnx（ReazonSpeech）/ Speech（Apple の音声認識）/ AVFoundation / 動画の MP3 変換 / モデル取得
        // （両エディション共通。AI のランタイムは含まない）
        .target(
            name: "WhisperBatchEngine",
            dependencies: ["WhisperBatchCore", "whisper", "SherpaOnnxC", .product(name: "LAME", package: "LAME")]
        ),
        // ローカルの言語モデル（llama.cpp、GGUF）の実行（Vantage だけ）
        .target(
            name: "SonaLLM",
            dependencies: ["WhisperBatchCore", "llama"]
        ),
        // Vantage の AI 機能の実装（ローカルの言語モデル・Apple Intelligence の端末内のモデル・話者識別）
        .target(
            name: "SonaVantageAI",
            dependencies: ["WhisperBatchCore", "WhisperBatchEngine", "SonaLLM", "SherpaOnnxC"]
        ),
        // SwiftUI の画面（両エディション共通。AI の機能はエディションの設定と AIRuntime を通してだけ使う）
        .target(
            name: "WhisperBatch",
            dependencies: ["WhisperBatchCore", "WhisperBatchEngine"]
        ),
        // エディションごとの起動（実行ファイル）
        .executableTarget(name: "SonaVantage", dependencies: ["WhisperBatch", "SonaVantageAI"]),
        .executableTarget(name: "SonaAir", dependencies: ["WhisperBatch"]),
        whisperFramework,
        sherpaOnnxFramework,
        llamaFramework,
        .testTarget(name: "WhisperBatchCoreTests", dependencies: ["WhisperBatchCore"]),
        .testTarget(name: "WhisperBatchEngineTests", dependencies: ["WhisperBatchEngine"]),
        .testTarget(name: "SonaVantageAITests", dependencies: ["SonaVantageAI", "SonaLLM", "WhisperBatchEngine"]),
    ]
)
