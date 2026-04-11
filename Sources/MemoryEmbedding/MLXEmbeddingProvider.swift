// MLXEmbeddingProvider.swift
// EmbeddingProvider implementation using MLX for on-device inference

import Foundation
import SwiftMemory
import MLXEmbedders
import MLXLMCommon
import MLX
import os.log

private let logger = Logger(subsystem: "com.memory", category: "MLXEmbedding")

/// EmbeddingProvider backed by MLX for on-device inference on Apple Silicon.
///
/// Lazily loads the model on first embed call. Downloads from HuggingFace
/// if not cached locally. Uses Matryoshka truncation to reduce output
/// to 256 dimensions with L2 re-normalization.
public actor MLXEmbeddingProvider: EmbeddingProvider {

    public nonisolated let dimensions: Int = 256

    private let configuration: MLXEmbedders.ModelConfiguration
    private var modelContainer: MLXEmbedders.ModelContainer?

    public init(configuration: MLXEmbedders.ModelConfiguration = .nomic_text_v1_5) {
        self.configuration = configuration
    }

    public func embed(_ text: String) async throws -> [Float] {
        let container = try await ensureModel()
        return await container.perform { model, tokenizer, pooling in
            let encoded = tokenizer.encode(text: text, addSpecialTokens: true)
            let input = stacked([MLXArray(encoded)])
            let tokenTypes = MLXArray.zeros(like: input)

            let output = model(
                input,
                positionIds: nil,
                tokenTypeIds: tokenTypes,
                attentionMask: nil
            )
            let pooled = pooling(output, normalize: true, applyLayerNorm: true)
            pooled.eval()

            let fullEmbedding = pooled[0].asArray(Float.self)
            return Self.truncateAndNormalize(fullEmbedding, to: 256)
        }
    }

    // MARK: - Model Loading

    private func ensureModel() async throws -> MLXEmbedders.ModelContainer {
        if let existing = modelContainer { return existing }
        logger.info("Loading embedding model: \(self.configuration.name)")
        let container = try await MLXEmbedders.loadModelContainer(
            from: HuggingFaceDownloader(),
            using: AutoTokenizerLoader(),
            configuration: configuration
        ) { progress in
            logger.debug("Model download: \(progress.fractionCompleted)")
        }
        self.modelContainer = container
        logger.info("Embedding model loaded")
        return container
    }

    // MARK: - Matryoshka Truncation

    /// Truncate embedding to target dimensions and L2 re-normalize.
    private static func truncateAndNormalize(_ embedding: [Float], to dims: Int) -> [Float] {
        let truncated = Array(embedding.prefix(dims))
        let norm = sqrt(truncated.reduce(0.0) { $0 + $1 * $1 })
        guard norm > 0 else { return truncated }
        return truncated.map { $0 / norm }
    }
}
