import Foundation
import Testing
import NaturalLanguage
import MemoryEmbedding

@Suite(.serialized)
struct AppleEmbeddingProviderTests {

    @Test(.timeLimit(.minutes(2)))
    func englishEmbeddingIsNormalizedTo256() async throws {
        let provider = AppleEmbeddingProvider(language: .english)
        let embedding = try await provider.embed("Bob remembers what matters.")

        #expect(embedding.count == 256)
        #expect(embedding.contains { $0 != 0 })

        let norm = sqrt(embedding.reduce(Float(0)) { $0 + $1 * $1 })
        #expect(abs(norm - 1.0) < 0.05)
    }

    @Test(.timeLimit(.minutes(2)))
    func similarSentencesAreCloserThanUnrelated() async throws {
        let provider = AppleEmbeddingProvider(language: .english)

        let a = try await provider.embed("The cat sat on the mat.")
        let b = try await provider.embed("A cat was sitting on the rug.")
        let c = try await provider.embed("Quantum entanglement disturbs locality.")

        let simAB = dot(a, b)
        let simAC = dot(a, c)
        #expect(simAB > simAC)
    }

    private func dot(_ x: [Float], _ y: [Float]) -> Float {
        zip(x, y).reduce(Float(0)) { $0 + $1.0 * $1.1 }
    }
}
