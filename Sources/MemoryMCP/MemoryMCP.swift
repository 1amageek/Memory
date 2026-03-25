// MemoryMCP.swift
// MCP tool definitions and handlers for Memory

import Foundation
import MCP
import Memory
import SwiftMemory

/// Registers Memory tools on an MCP Server.
public enum MemoryMCP {

    public static func registerTools(on server: Server, service: MemoryService) async {

        await server.withMethodHandler(ListTools.self) { _ in
            .init(tools: [
                Tool(
                    name: "recall",
                    description: "Recall associated knowledge from memory via spreading activation.",
                    inputSchema: .object([
                        "type": "object",
                        "properties": .object([
                            "keywords": .object([
                                "type": "array",
                                "items": .object(["type": "string"]),
                                "description": "Keywords to search for. Entities reached from multiple keywords score higher."
                            ]),
                            "maxHops": .object([
                                "type": "integer",
                                "description": "Graph traversal depth. Default: 2",
                                "default": .int(2)
                            ]),
                            "limit": .object([
                                "type": "integer",
                                "description": "Max results. Default: 20",
                                "default": .int(20)
                            ])
                        ]),
                        "required": .array([.string("keywords")])
                    ])
                ),
                Tool(
                    name: "store",
                    description: "Store structured knowledge in memory. Entities are saved as typed records with automatic triple generation. Relationships are saved as explicit RDF triples.",
                    inputSchema: .object([
                        "type": "object",
                        "properties": .object([
                            "entities": .object([
                                "type": "array",
                                "description": "Entities to store. Each must have 'type' and fields matching the type schema.",
                                "items": .object([
                                    "type": "object",
                                    "properties": .object([
                                        "type": .object([
                                            "type": "string",
                                            "description": "Entity type: Person, Organization, Place, Event, Activity, Product, Service"
                                        ]),
                                        "data": .object([
                                            "type": "object",
                                            "description": "Entity fields as key-value pairs matching the type schema"
                                        ])
                                    ]),
                                    "required": .array([.string("type"), .string("data")])
                                ])
                            ]),
                            "relationships": .object([
                                "type": "array",
                                "description": "Relationships between entities as RDF triples.",
                                "items": .object([
                                    "type": "object",
                                    "properties": .object([
                                        "subject": .object(["type": "string", "description": "Subject entity name or IRI"]),
                                        "predicate": .object(["type": "string", "description": "Predicate IRI (e.g. ex:worksAt)"]),
                                        "object": .object(["type": "string", "description": "Object entity name or IRI"])
                                    ]),
                                    "required": .array([.string("subject"), .string("predicate"), .string("object")])
                                ])
                            ])
                        ])
                    ])
                ),
                Tool(
                    name: "ontology",
                    description: "Get the ontology definition in HOOT compact format. Returns available classes, properties, and axioms. Call this before using the store tool to understand what entity types and predicates are available.",
                    inputSchema: .object([
                        "type": "object",
                        "properties": .object([:])
                    ])
                )
            ])
        }

        await server.withMethodHandler(CallTool.self) { params in
            switch params.name {
            case "recall":
                return await handleRecall(params: params, service: service)
            case "store":
                return await handleStore(params: params, service: service)
            case "ontology":
                let hoot = await service.ontologyHOOT()
                return .init(content: [.text(hoot)], isError: false)
            default:
                return .init(content: [.text("Unknown tool: \(params.name)")], isError: true)
            }
        }
    }

    // MARK: - Recall

    private static func handleRecall(params: CallTool.Parameters, service: MemoryService) async -> CallTool.Result {
        guard let keywordsValue = params.arguments?["keywords"] else {
            return .init(content: [.text("Missing required argument: keywords")], isError: true)
        }

        let keywords: [String]
        if let arr = keywordsValue.arrayValue {
            keywords = arr.compactMap(\.stringValue)
        } else if let str = keywordsValue.stringValue {
            keywords = [str]
        } else {
            return .init(content: [.text("keywords must be an array of strings")], isError: true)
        }

        let maxHops = params.arguments?["maxHops"]?.intValue ?? 2
        let limit = params.arguments?["limit"]?.intValue ?? 20

        do {
            let result = try await service.recall(keywords: keywords, maxHops: maxHops, limit: limit)
            if result.entities.isEmpty {
                return .init(content: [.text("No entities found for: \(keywords.joined(separator: ", "))")], isError: false)
            }
            var output = "Found \(result.entities.count) entities:\n\n"
            for entity in result.entities {
                output += "- **\(entity.label)** (\(entity.type), score: \(entity.score))\n"
                for path in entity.paths.prefix(3) {
                    output += "  via: \(path)\n"
                }
            }
            return .init(content: [.text(output)], isError: false)
        } catch {
            return .init(content: [.text("Recall failed: \(error.localizedDescription)")], isError: true)
        }
    }

    // MARK: - Store

    private static func handleStore(params: CallTool.Parameters, service: MemoryService) async -> CallTool.Result {
        var batch = MemoryBatch()
        var entityCount = 0
        var relationshipCount = 0

        // Parse entities
        if let entitiesValue = params.arguments?["entities"], let entities = entitiesValue.arrayValue {
            for entityValue in entities {
                guard let obj = entityValue.objectValue,
                      let type = obj["type"]?.stringValue,
                      let data = obj["data"] else { continue }

                do {
                    let jsonData = try JSONEncoder().encode(data)
                    if let entity = try await service.decodeEntity(type: type, from: jsonData) {
                        batch.entity(entity)
                        entityCount += 1
                    }
                } catch {
                    continue
                }
            }
        }

        // Parse relationships
        if let relsValue = params.arguments?["relationships"], let rels = relsValue.arrayValue {
            for rel in rels {
                guard let obj = rel.objectValue,
                      let subject = obj["subject"]?.stringValue,
                      let predicate = obj["predicate"]?.stringValue,
                      let object = obj["object"]?.stringValue else { continue }
                batch.triple(subject, predicate, object)
                relationshipCount += 1
            }
        }

        guard !batch.entities.isEmpty || !batch.statements.isEmpty else {
            return .init(content: [.text("Nothing to store")], isError: false)
        }

        do {
            try await service.store(batch)
            return .init(content: [.text("Stored \(entityCount) entities, \(relationshipCount) relationships")], isError: false)
        } catch {
            return .init(content: [.text("Store failed: \(error.localizedDescription)")], isError: true)
        }
    }
}
