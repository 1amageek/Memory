// TokenizerBridge.swift
// Bridges DePasqualeOrg/swift-tokenizers to MLXLMCommon.Tokenizer

import Foundation
import MLXLMCommon
import Tokenizers

/// Loads tokenizers from local directories using swift-tokenizers' AutoTokenizer,
/// bridging to the MLXLMCommon.Tokenizer protocol.
struct AutoTokenizerLoader: MLXLMCommon.TokenizerLoader {

    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        let upstream = try await AutoTokenizer.from(directory: directory)
        return TokenizerBridge(upstream)
    }
}

/// Bridges `Tokenizers.Tokenizer` to `MLXLMCommon.Tokenizer`.
///
/// The two protocols share the same method names for encode/decode/convert,
/// but differ in `applyChatTemplate` signature. Since embeddings don't use
/// chat templates, the bridge throws `missingChatTemplate` for that method.
private struct TokenizerBridge: MLXLMCommon.Tokenizer {

    private let upstream: any Tokenizers.Tokenizer

    init(_ upstream: any Tokenizers.Tokenizer) {
        self.upstream = upstream
    }

    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        upstream.encode(text: text, addSpecialTokens: addSpecialTokens)
    }

    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        upstream.decode(tokenIds: tokenIds, skipSpecialTokens: skipSpecialTokens)
    }

    func convertTokenToId(_ token: String) -> Int? {
        upstream.convertTokenToId(token)
    }

    func convertIdToToken(_ id: Int) -> String? {
        upstream.convertIdToToken(id)
    }

    var bosToken: String? { upstream.bosToken }
    var eosToken: String? { upstream.eosToken }
    var unknownToken: String? { upstream.unknownToken }

    func applyChatTemplate(
        messages: [[String: any Sendable]],
        tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int] {
        throw MLXLMCommon.TokenizerError.missingChatTemplate
    }
}
