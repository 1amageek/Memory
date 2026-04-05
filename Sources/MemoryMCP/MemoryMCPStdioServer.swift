// MemoryMCPStdioServer.swift
// Stdio transport for Memory MCP server

import Foundation
import MCP
import SwiftMemory

/// Stdio MCP server for Memory.
///
/// Designed for use as a plugin-bundled executable.
/// Communicates via stdin/stdout using the MCP stdio transport.
///
/// ```swift
/// let server = MemoryMCPStdioServer(memory: memory, entityTypes: entityTypes)
/// try await server.run()  // Blocks until stdin closes
/// ```
public actor MemoryMCPStdioServer {

    private let memory: SwiftMemory.Memory
    private let entityTypes: [any MemoryStorable.Type]

    public init(
        memory: SwiftMemory.Memory,
        entityTypes: [any MemoryStorable.Type]
    ) {
        self.memory = memory
        self.entityTypes = entityTypes
    }

    /// Start the server and block until the connection is closed.
    public func run() async throws {
        let server = Server(
            name: "memory",
            version: "0.1.0",
            capabilities: .init(tools: .init())
        )

        try await registerMemoryTools(on: server, memory: memory, entityTypes: entityTypes)

        let transport = StdioTransport()
        try await server.start(transport: transport)
        await server.waitUntilCompleted()
    }
}
