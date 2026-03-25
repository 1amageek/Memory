// MemoryMCP.swift
// MCP tool definitions and handlers for Memory

import Foundation
import MCP
import Memory
import SwiftMemory

/// Configuration for the store tool.
/// Client provides the input schema and decoder for their @Generable store input type.
public struct StoreToolConfig: Sendable {
    /// JSON Schema for the store tool input (from @Generable GenerationSchema).
    public let inputSchema: Value

    /// Decode JSON data into a MemoryBatchConvertible, then convert to MemoryBatch.
    public let decode: @Sendable (Data) throws -> MemoryBatch

    public init(inputSchema: Value, decode: @escaping @Sendable (Data) throws -> MemoryBatch) {
        self.inputSchema = inputSchema
        self.decode = decode
    }

    /// Convenience init from a MemoryBatchConvertible & Codable type.
    public init<T: MemoryBatchConvertible & Codable>(type: T.Type, inputSchema: Value) {
        self.inputSchema = inputSchema
        self.decode = { data in
            let input = try JSONDecoder().decode(T.self, from: data)
            return input.toBatch()
        }
    }
}

/// Registers Memory tools on an MCP Server.
public enum MemoryMCP {

    public static func registerTools(on server: Server, service: MemoryService, storeConfig: StoreToolConfig) async {

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
                    description: "Store structured knowledge in memory. Input must match the JSON Schema. Entities are saved as typed records. Relationships are saved as RDF triples.",
                    inputSchema: storeConfig.inputSchema
                ),
                Tool(
                    name: "ontology",
                    description: "Get the ontology definition in HOOT compact format. Returns available classes, properties, and axioms.",
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
                return await handleStore(params: params, service: service, config: storeConfig)
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

    private static func handleStore(params: CallTool.Parameters, service: MemoryService, config: StoreToolConfig) async -> CallTool.Result {
        guard let arguments = params.arguments else {
            return .init(content: [.text("Missing arguments")], isError: true)
        }

        do {
            let data = try JSONEncoder().encode(arguments)
            let batch = try config.decode(data)

            guard !batch.entities.isEmpty || !batch.statements.isEmpty else {
                return .init(content: [.text("Nothing to store")], isError: false)
            }

            try await service.store(batch)
            return .init(content: [.text("Stored \(batch.entities.count) entities, \(batch.statements.count) relationships")], isError: false)
        } catch {
            return .init(content: [.text("Store failed: \(error.localizedDescription)")], isError: true)
        }
    }
}
