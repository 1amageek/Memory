// AppleEmbeddingProvider.swift
// EmbeddingProvider implementation backed by Apple NaturalLanguage's
// NLContextualEmbedding (on-device, transformer-based)

import Foundation
import NaturalLanguage
import SwiftMemory
import os.log

private let logger = Logger(subsystem: "com.memory", category: "AppleEmbedding")

/// On-device `EmbeddingProvider` backed by `NLContextualEmbedding`.
///
/// `NLContextualEmbedding` produces token-level contextual vectors. This
/// provider mean-pools tokens into a single sentence vector and then
/// truncates + L2-normalizes to `dimensions` to satisfy
/// `Entity.embeddingDimensions` (256).
///
/// The underlying model is language/script-scoped. Select the language that
/// matches the primary content you store. One `NLContextualEmbedding` instance
/// covers all languages sharing the same script (e.g. `.english` covers the
/// Latin-script family).
public actor AppleEmbeddingProvider: EmbeddingProvider {

    public nonisolated let dimensions: Int

    private let language: NLLanguage
    private var model: NLContextualEmbedding?

    public init(language: NLLanguage = .english, dimensions: Int = 256) {
        self.language = language
        self.dimensions = dimensions
    }

    public func embed(_ text: String) async throws -> [Float] {
        let model = try await ensureModel()
        let result = try model.embeddingResult(for: text, language: language)

        let nativeDim = model.dimension
        var sum = [Double](repeating: 0, count: nativeDim)
        var count = 0
        result.enumerateTokenVectors(in: text.startIndex..<text.endIndex) { vector, _ in
            let n = min(nativeDim, vector.count)
            for i in 0..<n { sum[i] += vector[i] }
            count += 1
            return true
        }

        guard count > 0 else {
            throw AppleEmbeddingProviderError.emptyResult
        }

        let mean = sum.map { Float($0 / Double(count)) }
        return Self.projectAndNormalize(mean, to: dimensions)
    }

    // MARK: - Model Loading

    private func ensureModel() async throws -> NLContextualEmbedding {
        if let existing = model { return existing }

        guard let candidate = NLContextualEmbedding(language: language) else {
            throw AppleEmbeddingProviderError.unsupportedLanguage(language)
        }

        if !candidate.hasAvailableAssets {
            logger.info("Requesting NLContextualEmbedding assets for \(self.language.rawValue, privacy: .public)")
            let result = try await candidate.requestAssets()
            guard result == .available else {
                throw AppleEmbeddingProviderError.assetsUnavailable(result)
            }
        }

        try candidate.load()
        self.model = candidate
        logger.info("NLContextualEmbedding loaded (nativeDim=\(candidate.dimension))")
        return candidate
    }

    // MARK: - Projection

    private static func projectAndNormalize(_ vec: [Float], to dims: Int) -> [Float] {
        var out = Array(vec.prefix(dims))
        if out.count < dims {
            out.append(contentsOf: [Float](repeating: 0, count: dims - out.count))
        }
        let norm = out.reduce(Float(0)) { $0 + $1 * $1 }.squareRoot()
        guard norm > 0 else { return out }
        return out.map { $0 / norm }
    }
}

// MARK: - Errors

public enum AppleEmbeddingProviderError: LocalizedError {
    case unsupportedLanguage(NLLanguage)
    case assetsUnavailable(NLContextualEmbedding.AssetsResult)
    case emptyResult

    public var errorDescription: String? {
        switch self {
        case .unsupportedLanguage(let lang):
            return "NLContextualEmbedding is not available for language '\(lang.rawValue)'"
        case .assetsUnavailable(let result):
            return "NLContextualEmbedding assets are not available (result=\(result))"
        case .emptyResult:
            return "NLContextualEmbedding produced no tokens for the input"
        }
    }
}
