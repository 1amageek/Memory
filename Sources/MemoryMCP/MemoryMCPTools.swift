// MemoryMCPTools.swift
// Shared MCP tool registration and handlers for Memory

import Foundation
import MCP
import SwiftMemory
@_spi(Internal) import Generation
import Database

// MARK: - Tool Registration

/// Register Memory MCP tools (recall, store, ontology) on an MCP Server.
///
/// Shared by both HTTP and stdio transports.
func registerMemoryTools(
    on server: Server,
    memory: SwiftMemory.Memory,
    entityTypes: [any MemoryStorable.Type]
) async throws {
    let knowledgeSchema = try buildStoreKnowledgeSchema(entityTypes: entityTypes)
    let recallSchema = try RecallInput.schemaValue()
    let storeSchema = buildStoreInputSchema(knowledgeSchema: knowledgeSchema)

    await server.withMethodHandler(ListTools.self) { _ in
        .init(tools: [
            Tool(
                name: "recall",
                description: "Recall associated knowledge from memory via spreading activation.",
                inputSchema: recallSchema
            ),
            Tool(
                name: "store",
                description: "Store structured knowledge in memory. The input schema describes all available entity types and their properties.",
                inputSchema: storeSchema
            ),
            Tool(
                name: "ontology",
                description: "Get the ontology definition in HOOT compact format. Returns available classes, properties, and axioms.",
                inputSchema: .object(["type": "object", "properties": .object([:])])
            )
        ])
    }

    await server.withMethodHandler(CallTool.self) { params in
        switch params.name {
        case "recall":
            return await handleRecall(params: params, memory: memory)
        case "store":
            return await handleStore(params: params, memory: memory, entityTypes: entityTypes)
        case "ontology":
            let hoot = memory.ontologyPolicy.buildOntology().toHoot(mode: .compact)
            return .init(content: [.text(text: hoot, annotations: nil, _meta: nil)], isError: false)
        default:
            return .init(content: [.text(text: "Unknown tool: \(params.name)", annotations: nil, _meta: nil)], isError: true)
        }
    }
}

// MARK: - Schema Builders

private func buildStoreInputSchema(knowledgeSchema: Value) -> Value {
    .object([
        "type": "object",
        "properties": .object([
            "given": .object([
                "type": "string",
                "description": "The raw text from which knowledge was extracted"
            ]),
            "knowledge": knowledgeSchema
        ]),
        "required": .array([.string("given"), .string("knowledge")])
    ])
}

private func buildStoreKnowledgeSchema(entityTypes: [any MemoryStorable.Type]) throws -> Value {
    var properties: [String: Value] = [:]
    for type in entityTypes {
        properties[type.storeKey] = .object([
            "type": "array",
            "items": try type.schemaValue()
        ])
    }
    properties["relationships"] = .object([
        "type": "array",
        "items": try ExtractedRelationship.schemaValue()
    ])
    return .object([
        "type": "object",
        "properties": .object(properties)
    ])
}

// MARK: - Recall Handler

private func handleRecall(params: CallTool.Parameters, memory: SwiftMemory.Memory) async -> CallTool.Result {
    do {
        let args: Value = .object(params.arguments ?? [:])
        let jsonData = try JSONEncoder().encode(args)
        let jsonString = String(data: jsonData, encoding: .utf8) ?? "{}"
        let input = try RecallInput(GeneratedContent(json: jsonString))

        let keywords = input.keywords
        guard !keywords.isEmpty else {
            return .init(content: [.text(text: "Missing required argument: keywords", annotations: nil, _meta: nil)], isError: true)
        }

        let result = try await memory.recall(keywords: keywords, maxHops: input.maxHops, limit: input.limit)
        if result.entities.isEmpty {
            return .init(content: [.text(text: "No entities found for: \(keywords.joined(separator: ", "))", annotations: nil, _meta: nil)], isError: false)
        }
        var output = "Found \(result.entities.count) entities:\n\n"
        for entity in result.entities {
            output += "- **\(entity.label)** (\(entity.type), score: \(entity.score))\n"
            for path in entity.paths.prefix(3) {
                output += "  via: \(path)\n"
            }
        }
        return .init(content: [.text(text: output, annotations: nil, _meta: nil)], isError: false)
    } catch {
        return .init(content: [.text(text: "Recall failed: \(error.localizedDescription)", annotations: nil, _meta: nil)], isError: true)
    }
}

// MARK: - Store Handler

private func handleStore(
    params: CallTool.Parameters,
    memory: SwiftMemory.Memory,
    entityTypes: [any MemoryStorable.Type]
) async -> CallTool.Result {
    guard let arguments = params.arguments,
          let givenText = arguments["given"]?.stringValue,
          let knowledgeValue = arguments["knowledge"] else {
        return .init(content: [.text(text: "Missing required arguments: given and knowledge", annotations: nil, _meta: nil)], isError: true)
    }

    do {
        let jsonData = try JSONEncoder().encode(knowledgeValue)
        let capturedTypes = entityTypes

        try await memory.store(given: givenText, knowledgeData: jsonData) { data in
            try decodeKnowledge(data, entityTypes: capturedTypes)
        }
        return .init(content: [.text(text: "Stored successfully", annotations: nil, _meta: nil)], isError: false)
    } catch {
        return .init(content: [.text(text: "Store failed: \(error.localizedDescription)", annotations: nil, _meta: nil)], isError: true)
    }
}

// MARK: - Knowledge Decode

private func decodeKnowledge(
    _ data: Data,
    entityTypes: [any MemoryStorable.Type]
) throws -> MemoryBatch {
    let jsonString = String(data: data, encoding: .utf8) ?? "{}"
    let root = try GeneratedContent(json: jsonString)
    let props = try root.properties()
    var batch = MemoryBatch()

    for type in entityTypes {
        guard let arrayContent = props[type.storeKey] else { continue }
        let elements = try arrayContent.elements()
        for element in elements {
            var entity = try type.init(element)
            entity.applyStableID()
            batch.entity(entity)
        }
    }

    if let relsContent = props["relationships"] {
        for element in try relsContent.elements() {
            let rel = try ExtractedRelationship(element)
            batch.triple(rel.subject, rel.predicate, rel.object)
        }
    }

    return batch
}

// MARK: - MCP Tool Input Types

@Generable(description: "Recall associated knowledge from memory via spreading activation")
struct RecallInput {
    @Guide(description: "Keywords to search for. Entities reached from multiple keywords score higher.")
    var keywords: [String] = []

    @Guide(description: "Graph traversal depth. Default: 2")
    var maxHops: Int = 2

    @Guide(description: "Max results. Default: 20")
    var limit: Int = 20
}

@Generable(description: "A relationship between two entities")
struct ExtractedRelationship {
    @Guide(description: "Subject entity name")
    var subject: String = ""
    @Guide(description: "Predicate IRI (e.g. ex:worksAt)")
    var predicate: String = ""
    @Guide(description: "Object entity name")
    var object: String = ""
}
