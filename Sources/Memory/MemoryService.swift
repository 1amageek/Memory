// MemoryService.swift
// Core memory operations — recall and store

import Foundation
import SwiftMemory
import Database

/// Core memory service. Provides recall and store operations.
public actor MemoryService {

    public let memory: SwiftMemory.Memory

    public init(
        path: String?,
        entityTypes: [any Persistable.Type] = [],
        graphName: String = "memory:default"
    ) async throws {
        self.memory = try await SwiftMemory.Memory(
            path: path,
            entityTypes: entityTypes,
            graphName: graphName
        )
    }

    // MARK: - Recall

    public func recall(keywords: [String], maxHops: Int = 2, limit: Int = 20) async throws -> RecallResult {
        try await memory.recall(keywords: keywords, maxHops: maxHops, limit: limit)
    }

    // MARK: - Store

    public func store(_ batch: MemoryBatch) async throws {
        try await memory.store(batch)
    }

    /// Store Given + Knowledge from MCP tool call.
    public func store(given: String, knowledgeData: Data, decode: @Sendable (Data, String) throws -> MemoryBatch) async throws {
        try await memory.store(given: given, knowledgeData: knowledgeData, decode: decode)
    }

    // MARK: - Ontology

    public func ontologyHOOT() async -> String {
        memory.ontologyPolicy.buildOntology().toHoot(mode: .compact)
    }
}
