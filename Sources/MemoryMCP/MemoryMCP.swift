// MemoryMCP.swift
// MCP tool definitions and handlers for Memory

import Foundation
import MCP
import Memory

/// Registers Memory tools on an MCP Server.
///
/// Call `registerTools(on:service:)` to add recall and store tools.
/// Works with any transport — stdio, HTTP, or in-process.
public enum MemoryMCP {

    /// Register memory tools on the given MCP server.
    public static func registerTools(on server: Server, service: MemoryService) async {

        await server.withMethodHandler(ListTools.self) { _ in
            .init(tools: [
                Tool(
                    name: "recall",
                    description: "Recall associated knowledge from memory. Given keywords, finds related entities through spreading activation on the knowledge graph.",
                    inputSchema: .object([
                        "type": "object",
                        "properties": .object([
                            "keywords": .object([
                                "type": "array",
                                "items": .object(["type": "string"]),
                                "description": "Keywords to search for. Entities reached from multiple keywords score higher (convergence)."
                            ]),
                            "maxHops": .object([
                                "type": "integer",
                                "description": "Maximum graph traversal depth. Default: 2",
                                "default": .int(2)
                            ]),
                            "limit": .object([
                                "type": "integer",
                                "description": "Maximum results. Default: 20",
                                "default": .int(20)
                            ])
                        ]),
                        "required": .array([.string("keywords")])
                    ])
                ),
                Tool(
                    name: "store",
                    description: "Store text in memory. Saved as Given and interpreted to extract entities and relationships.",
                    inputSchema: .object([
                        "type": "object",
                        "properties": .object([
                            "text": .object([
                                "type": "string",
                                "description": "Text to store"
                            ])
                        ]),
                        "required": .array([.string("text")])
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
            default:
                return .init(content: [.text("Unknown tool: \(params.name)")], isError: true)
            }
        }
    }

    // MARK: - Handlers

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

    private static func handleStore(params: CallTool.Parameters, service: MemoryService) async -> CallTool.Result {
        guard let text = params.arguments?["text"]?.stringValue else {
            return .init(content: [.text("Missing required argument: text")], isError: true)
        }

        do {
            try await service.store(text)
            return .init(content: [.text("Stored in memory")], isError: false)
        } catch {
            return .init(content: [.text("Store failed: \(error.localizedDescription)")], isError: true)
        }
    }
}
