// MemoryService.swift
// Core memory operations — recall and store

import Foundation
import SwiftMemory
import Database

/// Core memory service. Provides recall and store operations.
/// MCP-agnostic — can be used directly or via MemoryMCP.
public actor MemoryService {

    public let memory: SwiftMemory.Memory

    /// Initialize with a file path for SQLite persistence.
    /// Pass `nil` for in-memory (testing).
    public init(
        path: String?,
        encoding: any MemoryEncoding,
        entityTypes: [any Persistable.Type] = [],
        graphName: String = "memory:default"
    ) async throws {
        self.memory = try await SwiftMemory.Memory(
            path: path,
            encoding: encoding,
            entityTypes: entityTypes,
            graphName: graphName
        )
    }

    /// Recall entities by keywords — spreading activation.
    public func recall(keywords: [String], maxHops: Int = 2, limit: Int = 20) async throws -> RecallResult {
        try await memory.recall(keywords: keywords, maxHops: maxHops, limit: limit)
    }

    /// Store input through the Concept Protocol.
    public func store(_ input: any GivenRepresentable) async throws {
        try await memory.store(input)
    }

    /// Store a pre-built batch.
    public func store(_ batch: MemoryBatch) async throws {
        try await memory.store(batch)
    }
}
