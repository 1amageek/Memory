// MemoryKnowledgeDecoder.swift
// Shared decoder for MCP store payloads.

import Foundation
import SwiftMemory
@_spi(Internal) import SwiftGeneration

struct MemoryKnowledgeDecoder {
    static func decode(
        _ data: Data,
        entityTypes: [any MemoryStorable.Type]
    ) throws -> MemoryBatch {
        let jsonString = String(data: data, encoding: .utf8) ?? "{}"
        let root = try GeneratedContent(json: jsonString)
        let props = try root.properties()
        var batch = MemoryBatch()
        var aliasCollector = RelationshipAliasCollector()

        for type in entityTypes {
            guard let arrayContent = props[type.storeKey] else { continue }
            let elements = try arrayContent.elements()
            for element in elements {
                let entity = try type.init(element)
                batch.entity(entity)
                for alias in entity.referenceAliases {
                    aliasCollector.add(alias: alias, target: entity.assertion)
                }
            }
        }

        for alias in aliasCollector.unambiguousAliases {
            batch.alias(alias.name, for: alias.target)
        }

        if let relsContent = props["relationships"] {
            for element in try relsContent.elements() {
                let rel = try ExtractedRelationship(element)
                batch.triple(rel.subject, rel.predicate, rel.object)
            }
        }

        return batch
    }
}
