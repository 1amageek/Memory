// MLXEmbeddingProvider.swift
// EmbeddingProvider implementation backed by MLX Embedders (Sentence-Transformer
// compatible models running on Apple Silicon via mlx-swift-lm).

import Foundation
import HuggingFace
import MLX
import MLXEmbedders
import MLXHuggingFace
import MLXLMCommon
import SwiftMemory
import Tokenizers
import os.log

private let logger = Logger(subsystem: "com.memory", category: "MLXEmbedding")

/// On-device `EmbeddingProvider` backed by MLX Embedders.
///
/// `AppleEmbeddingProvider` (via `NLContextualEmbedding`) mean-pools raw token
/// vectors without the normalization heads that Sentence-Transformer models
/// ship with, which inflates cosine similarity between semantically distinct
/// but vocabulary-overlapping assertions (e.g. different LLM product names).
/// This provider delegates pooling and L2 normalization to MLX's
/// Sentence-Transformer compatible `Pooling`, restoring the separability the
/// upstream model was trained for.
///
/// The default model, `mlx-community/embeddinggemma-300m-bf16`, is Google's
/// EmbeddingGemma 300M (Gemma 3 backbone with sentence-transformer projection
/// head). It outputs 768-dim vectors, supports 100+ languages including EN/JA,
/// and uses task-specific input prefixes. The default prefix
/// `"task: sentence similarity | query: "` is the symmetric similarity prompt
/// designed for pairwise comparison — what entity resolution requires.
public actor MLXEmbeddingProvider: EmbeddingProvider {

    /// Default HuggingFace model identifier — Google EmbeddingGemma 300M (bf16).
    public static let defaultModelID = "mlx-community/embeddinggemma-300m-bf16"

    /// Default input prefix — EmbeddingGemma's symmetric similarity prompt.
    /// Designed for pairwise comparison where both sides are queries (entity
    /// resolution semantics). For asymmetric retrieval, switch to
    /// `"task: search result | query: "` (queries) and `"title: none | text: "`
    /// (documents).
    public static let defaultInputPrefix = "task: sentence similarity | query: "

    public nonisolated let dimensions: Int

    private let container: MLXEmbedders.ModelContainer
    private let inputPrefix: String

    /// Load an MLX embedder model.
    ///
    /// - Parameters:
    ///   - modelID: HuggingFace repo ID. Any Sentence-Transformer compatible
    ///     BERT/NomicBERT/Qwen3/Gemma3 model supported by MLXEmbedders works.
    ///   - inputPrefix: Text prepended to each input before tokenization.
    ///     EmbeddingGemma uses task-specific prefixes (see
    ///     `defaultInputPrefix`); E5 family uses `"query: "` / `"passage: "`.
    ///     For symmetric pairwise similarity (entity resolution) use the same
    ///     prefix on both sides.
    ///   - progressHandler: Optional download progress callback. The model
    ///     is downloaded from HuggingFace on first use and cached on disk.
    public init(
        modelID: String = MLXEmbeddingProvider.defaultModelID,
        inputPrefix: String = MLXEmbeddingProvider.defaultInputPrefix,
        progressHandler: @Sendable @escaping (Progress) -> Void = { _ in }
    ) async throws {
        let configuration = ModelConfiguration(id: modelID)
        let container = try await loadModelContainer(
            from: #hubDownloader(),
            using: #huggingFaceTokenizerLoader(),
            configuration: configuration,
            progressHandler: progressHandler
        )
        self.container = container
        self.inputPrefix = inputPrefix

        // Probe output dimensionality with a trivial input so the exposed
        // `dimensions` always matches the live model, not a hardcoded assumption.
        let probe = await Self.runEmbed(
            in: container,
            text: inputPrefix + "a"
        )
        self.dimensions = probe.count

        logger.info(
            "MLXEmbeddingProvider loaded model=\(modelID, privacy: .public) dims=\(probe.count)"
        )
    }

    public func embed(_ text: String) async throws -> [Float] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw MLXEmbeddingProviderError.emptyInput
        }
        return await Self.runEmbed(in: container, text: inputPrefix + trimmed)
    }

    private static func runEmbed(
        in container: MLXEmbedders.ModelContainer,
        text: String
    ) async -> [Float] {
        await container.perform { model, tokenizer, pooler in
            let tokens = tokenizer.encode(text: text, addSpecialTokens: true)
            let input = MLXArray(tokens).expandedDimensions(axis: 0)
            let output = model(
                input,
                positionIds: nil,
                tokenTypeIds: nil,
                attentionMask: nil
            )
            let pooled = pooler(output)
            pooled.eval()
            return pooled[0].asArray(Float.self)
        }
    }
}

// MARK: - Errors

public enum MLXEmbeddingProviderError: LocalizedError {
    case emptyInput

    public var errorDescription: String? {
        switch self {
        case .emptyInput:
            return "MLXEmbeddingProvider received empty input after trimming"
        }
    }
}
