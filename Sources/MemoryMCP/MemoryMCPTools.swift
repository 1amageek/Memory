// MemoryMCPTools.swift
// Shared MCP tool registration and handlers for Memory

import Foundation
import MCP
import SwiftMemory
@_spi(Internal) import SwiftGeneration
import Database

// MARK: - Tool Registration

/// Register Memory MCP tools (recall, resolve, store) on an MCP Server.
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
    let resolveSchema = buildResolveInputSchema(knowledgeSchema: knowledgeSchema)

    await server.withMethodHandler(ListTools.self) { _ in
        .init(tools: [
            Tool(
                name: "recall",
                description: "Recall associated knowledge from memory via spreading activation.",
                inputSchema: recallSchema
            ),
            Tool(
                name: "resolve",
                description: "Resolve candidate entities before storing. Returns top candidate entities with one-hop graph context for Agent identity judgment.",
                inputSchema: resolveSchema
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
        case "resolve":
            return await handleResolve(params: params, memory: memory, entityTypes: entityTypes)
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

private func buildResolveInputSchema(knowledgeSchema: Value) -> Value {
    .object([
        "type": "object",
        "properties": .object([
            "knowledge": knowledgeSchema,
            "threshold": .object([
                "type": "number",
                "description": "Cosine similarity threshold for candidate retrieval. Default: 0.9"
            ]),
            "limit": .object([
                "type": "integer",
                "description": "Maximum candidates returned per input entity. Default: 30"
            ])
        ]),
        "required": .array([.string("knowledge")])
    ])
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

private func handleResolve(
    params: CallTool.Parameters,
    memory: SwiftMemory.Memory,
    entityTypes: [any MemoryStorable.Type]
) async -> CallTool.Result {
    guard let arguments = params.arguments,
          let knowledgeValue = arguments["knowledge"] else {
        return .init(content: [.text(text: "Missing required argument: knowledge", annotations: nil, _meta: nil)], isError: true)
    }

    do {
        let jsonData = try JSONEncoder().encode(knowledgeValue)
        let batch = try MemoryKnowledgeDecoder.decode(jsonData, entityTypes: entityTypes)
        guard !batch.entities.isEmpty else {
            return .init(content: [.text(text: "No candidate entities to resolve", annotations: nil, _meta: nil)], isError: false)
        }

        let threshold = Float(arguments["threshold"]?.doubleValue ?? Double(SwiftMemory.Memory.defaultResolveThreshold))
        let limit = arguments["limit"]?.intValue ?? SwiftMemory.Memory.defaultResolveLimit
        let resolved = try await memory.resolve(batch.entities, threshold: threshold, limit: limit)
        let output = formatResolvedEntities(resolved)
        return .init(content: [.text(text: output, annotations: nil, _meta: nil)], isError: false)
    } catch {
        return .init(content: [.text(text: "Resolve failed: \(error.localizedDescription)", annotations: nil, _meta: nil)], isError: true)
    }
}

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
            try MemoryKnowledgeDecoder.decode(data, entityTypes: capturedTypes)
        }
        return .init(content: [.text(text: "Stored successfully", annotations: nil, _meta: nil)], isError: false)
    } catch {
        return .init(content: [.text(text: "Store failed: \(error.localizedDescription)", annotations: nil, _meta: nil)], isError: true)
    }
}

private func formatResolvedEntities(_ resolved: [ResolvedEntity]) -> String {
    var output = "Resolved candidate entities: \(resolved.count)\n\n"

    for (index, entity) in resolved.enumerated() {
        output += "## Input \(index + 1)\n"
        output += "- assertion: `\(entity.inputAssertion)`\n"
        if entity.candidates.isEmpty {
            output += "- candidates: none\n\n"
            continue
        }

        for (candidateIndex, candidate) in entity.candidates.enumerated() {
            output += "\n### Candidate \(candidateIndex + 1)\n"
            output += "- id: `\(candidate.id)`\n"
            if !candidate.label.isEmpty {
                output += "- label: \(candidate.label)\n"
            }
            if !candidate.type.isEmpty {
                output += "- type: `\(candidate.type)`\n"
            }
            output += "- assertion: `\(candidate.assertion)`\n"
            output += "- similarity: \(candidate.similarity)\n"
            if candidate.context.isEmpty {
                output += "- 1-hop context: none\n"
            } else {
                output += "- 1-hop context:\n"
                for statement in candidate.context {
                    output += "  - \(statement.direction.rawValue): `\(statement.subject)` `\(statement.predicate)` `\(statement.object)`\n"
                }
            }
        }
        output += "\n"
    }

    return output
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
    @Guide(description: "Subject endpoint. Use an entity label or id when it refers to an entity; otherwise use the source term.")
    var subject: String = ""
    @Guide(description: "Predicate IRI")
    var predicate: String = ""
    @Guide(description: "Object endpoint. Use an entity label or id when it refers to an entity; otherwise use the source term.")
    var object: String = ""
}
