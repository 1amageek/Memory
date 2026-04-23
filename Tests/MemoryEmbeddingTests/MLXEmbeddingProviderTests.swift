import Foundation
import Testing
import MemoryEmbedding

/// End-to-end semantic checks on `MLXEmbeddingProvider` using Bob-domain inputs.
///
/// Upstream `mlx-swift-lm` already verifies that the EmbeddingGemma forward pass
/// matches the Python reference bit-exactly (see `EmbeddingGemmaReferenceParityTests`
/// and `EmbeddingGemmaSemanticParityTests`). This suite's purpose is different:
/// it checks the Bob-side integration — actor lifecycle, tokenizer wiring,
/// `inputPrefix` handling — on strings that Memory actually stores (BobTask
/// titles, Person assertions, Project descriptions).
///
/// The two invariants being defended:
///
/// 1. **Output shape**: 768 dims, finite, L2-normalized on every call. A regression
///    here would break the VectorIndex (dimensions must match the schema).
/// 2. **Semantic separability**: synonymous Bob-domain assertions cosine closer
///    than unrelated ones, and a keyword query retrieves the topically-matching
///    BobTask first. A regression here would silently degrade `recall` quality
///    without tripping any schema-level check.
@Suite("MLXEmbeddingProvider (Bob domain)", .serialized)
struct MLXEmbeddingProviderTests {

    private static let expectedDim = 768

    @Test(.timeLimit(.minutes(5)))
    func outputIsNormalized768Dims() async throws {
        let provider = try await MLXEmbeddingProvider()

        let vec = try await provider.embed("Firebase のセキュリティルールを修正した")
        #expect(vec.count == Self.expectedDim)
        #expect(provider.dimensions == Self.expectedDim)
        #expect(vec.allSatisfy { $0.isFinite })

        let norm = sqrt(vec.reduce(Float(0)) { $0 + $1 * $1 })
        #expect(abs(norm - 1.0) < 1e-2, "norm \(norm) not L2-normalized")
    }

    @Test(.timeLimit(.minutes(5)))
    func identicalInputProducesIdenticalOutput() async throws {
        let provider = try await MLXEmbeddingProvider()
        let text = "Stamp Inc で働くエンジニア"

        let a = try await provider.embed(text)
        let b = try await provider.embed(text)

        #expect(a.count == b.count)
        let c = cosine(a, b)
        #expect(c > 0.9999, "Identical-input cosine \(c) indicates non-deterministic embedding")
    }

    @Test(.timeLimit(.minutes(5)))
    func bobTaskParaphrasesAreCloserThanUnrelated() async throws {
        let provider = try await MLXEmbeddingProvider()

        // Two BobTask titles describing the same underlying work
        let t1 = try await provider.embed("Firebase のセキュリティルールにバグがあったので直した")
        let t2 = try await provider.embed("Firebase のルールを修正してセキュリティ問題を解消した")
        // Topically unrelated everyday activity
        let u = try await provider.embed("夕食にトマトとバジルのパスタを作った")

        let simParaphrase = cosine(t1, t2)
        let simUnrelated = cosine(t1, u)

        print("[MLXEmbedding.Paraphrase] paraphrase=\(simParaphrase) unrelated=\(simUnrelated)")
        #expect(
            simParaphrase > simUnrelated + 0.1,
            "Expected paraphrase gap > 0.1, got paraphrase=\(simParaphrase) unrelated=\(simUnrelated)"
        )
    }

    @Test(.timeLimit(.minutes(5)))
    func topicalQueryRetrievesMatchingBobTask() async throws {
        let provider = try await MLXEmbeddingProvider()

        // Candidate corpus: one BobTask per topic
        let corpus: [(id: String, text: String)] = [
            ("firebase",  "Firebase Realtime Database のセキュリティルールを修正した"),
            ("swift",     "Swift のジェネリクスで型消去パターンを実装した"),
            ("cooking",   "新玉ねぎを使ってオニオンスープを作った"),
            ("bike",      "週末に自転車で湘南までサイクリングに行った"),
            ("asc",       "App Store Connect のバージョンリリースを準備した"),
        ]
        var corpusVecs: [(id: String, vec: [Float])] = []
        for (id, text) in corpus {
            let v = try await provider.embed(text)
            corpusVecs.append((id, v))
        }

        // Topical queries; each lists which corpus IDs are acceptable top-1 hits
        let queries: [(query: String, expectedTopOneIn: Set<String>)] = [
            ("Firebase 関連のタスク",           ["firebase"]),
            ("プログラミング言語の実装",          ["swift"]),
            ("料理",                          ["cooking"]),
            ("サイクリング",                   ["bike"]),
            ("App Store のリリース作業",        ["asc"]),
        ]

        var misses: [String] = []
        for (q, expected) in queries {
            let qv = try await provider.embed(q)
            let ranked = corpusVecs
                .map { ($0.id, cosine(qv, $0.vec)) }
                .sorted { $0.1 > $1.1 }
            guard let top = ranked.first else {
                Issue.record("Empty ranking for query \(q)")
                continue
            }
            if !expected.contains(top.0) {
                misses.append(
                    "q='\(q)' expected∈\(expected) got=\(top.0)(\(top.1)) "
                        + "full=\(ranked.map { "\($0.0)=\(String(format: "%.3f", $0.1))" }.joined(separator: ","))"
                )
            }
        }

        #expect(misses.isEmpty, "Retrieval misses: \(misses.joined(separator: " | "))")
    }

    // MARK: - Helpers

    private func cosine(_ a: [Float], _ b: [Float]) -> Float {
        precondition(a.count == b.count)
        var dot: Float = 0
        var normA: Float = 0
        var normB: Float = 0
        for i in 0..<a.count {
            dot += a[i] * b[i]
            normA += a[i] * a[i]
            normB += b[i] * b[i]
        }
        let denom = sqrt(normA) * sqrt(normB)
        return denom > 0 ? dot / denom : 0
    }
}
