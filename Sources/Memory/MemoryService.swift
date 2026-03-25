// MemoryService.swift
// Core memory operations — recall, store, entity decode

import Foundation
import SwiftMemory
import Database

/// Core memory service. Provides recall, store, and entity decode.
public actor MemoryService {

    public let memory: SwiftMemory.Memory
    private var entityDecoders: [String: @Sendable (Data) throws -> any Persistable & Sendable] = [:]

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
        for type in entityTypes {
            Self.registerDecoder(type, into: &entityDecoders)
        }
    }

    private static func registerDecoder<T: Persistable>(
        _ type: T.Type,
        into map: inout [String: @Sendable (Data) throws -> any Persistable & Sendable]
    ) {
        let name = String(describing: type)
        map[name] = { data in
            try JSONDecoder().decode(T.self, from: data)
        }
    }

    // MARK: - Recall

    public func recall(keywords: [String], maxHops: Int = 2, limit: Int = 20) async throws -> RecallResult {
        try await memory.recall(keywords: keywords, maxHops: maxHops, limit: limit)
    }

    // MARK: - Store

    public func store(_ batch: MemoryBatch) async throws {
        try await memory.store(batch)
    }

    // MARK: - Entity Decode

    /// Decode a JSON entity by type name. Used by MCP store tool.
    public func decodeEntity(type: String, from data: Data) throws -> (any Persistable & Sendable)? {
        guard let decoder = entityDecoders[type] else { return nil }
        return try decoder(data)
    }
}
