// MemoryMCPServer
// Standalone MCP server for Memory — stdio transport

import Foundation
import MCP
import Memory
import MemoryMCP

let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
let memoryDir = appSupport.appendingPathComponent("Memory", isDirectory: true)
try FileManager.default.createDirectory(at: memoryDir, withIntermediateDirectories: true)
let dbPath = memoryDir.appendingPathComponent("memory.sqlite").path

let service = try await MemoryService(path: dbPath)

let server = Server(
    name: "memory",
    version: "0.1.0",
    capabilities: .init(tools: .init())
)

await MemoryMCP.registerTools(on: server, service: service)

let transport = StdioTransport()
try await server.start(transport: transport)
await server.waitUntilCompleted()
