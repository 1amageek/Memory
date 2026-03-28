// MemoryMCPHTTPServer.swift
// In-process HTTP MCP server for Memory

import Foundation
import MCP
import SwiftMemory
@_spi(Internal) import Generation
import Database
import Logging
@preconcurrency import NIOCore
@preconcurrency import NIOPosix
@preconcurrency import NIOHTTP1

// MARK: - MemoryStorable Protocol

/// Entity type that can be stored via MCP store tool.
///
/// Requires @Generable for JSON decode and schema generation.
/// Generation is used internally — callers just conform their types.
///
/// ```swift
/// @Persistable @Generable
/// struct Person { ... }
///
/// extension Person: MemoryStorable {
///     public static let storeKey = "persons"
/// }
/// ```
public protocol MemoryStorable: Persistable, Generable, Sendable {
    /// JSON key in the knowledge object (e.g. "persons", "organizations").
    static var storeKey: String { get }

    /// Link to the source Given record.
    var givenID: String { get set }
}

// MARK: - Generable -> Value

extension Generable {
    /// Convert this type's GenerationSchema to MCP Value.
    static func schemaValue() throws -> Value {
        let dict = generationSchema.toSchemaDictionary()
        let data = try JSONSerialization.data(withJSONObject: dict)
        return try JSONDecoder().decode(Value.self, from: data)
    }
}

// MARK: - MemoryMCPHTTPServer

/// In-process HTTP MCP server for Memory.
///
/// Provides two MCP tools:
/// - **recall** — spreading activation search on the knowledge graph
/// - **store** — persist structured knowledge (entities + relationships)
///
/// Ontology constraints are embedded in the `store` tool's description
/// so the agent receives both structure (inputSchema) and semantics (HOOT)
/// in a single `tools/list` round trip.
///
/// ```swift
/// let server = MemoryMCPHTTPServer(memory: memory, entityTypes: entityTypes)
/// let port = try await server.start()
/// // url = "http://127.0.0.1:\(port)/mcp"
/// ```
public actor MemoryMCPHTTPServer {

    private let memory: SwiftMemory.Memory
    private let entityTypes: [any MemoryStorable.Type]
    private let host: String
    private let requestedPort: Int

    private var group: EventLoopGroup?
    private var channel: Channel?
    private var mcpServer: Server?
    private var transport: StatefulHTTPServerTransport?

    private let logger = Logger(label: "memory.mcp.http")

    public private(set) var port: Int = 0
    public var url: String { "http://\(host):\(port)/mcp" }

    public init(
        memory: SwiftMemory.Memory,
        entityTypes: [any MemoryStorable.Type],
        host: String = "127.0.0.1",
        port: Int = 0
    ) {
        self.memory = memory
        self.entityTypes = entityTypes
        self.host = host
        self.requestedPort = port
    }

    // MARK: - Lifecycle

    @discardableResult
    public func start() async throws -> Int {
        let transport = StatefulHTTPServerTransport(logger: logger)
        let mcpServer = Server(
            name: "memory",
            version: "0.1.0",
            capabilities: .init(tools: .init())
        )

        try await registerTools(on: mcpServer)

        try await mcpServer.start(transport: transport)
        self.mcpServer = mcpServer
        self.transport = transport

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        self.group = group

        let endpoint = "/mcp"
        let loggerRef = logger
        let transportRef = transport

        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(.backlog, value: 32)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline().flatMap {
                    channel.pipeline.addHandler(
                        MCPHTTPHandler(transport: transportRef, endpoint: endpoint, logger: loggerRef)
                    )
                }
            }

        let ch = try await bootstrap.bind(host: host, port: requestedPort).get()
        self.channel = ch
        self.port = ch.localAddress?.port ?? requestedPort
        logger.info("Memory MCP HTTP started on \(self.host):\(self.port)")
        return self.port
    }

    public func stop() async {
        await transport?.disconnect()
        transport = nil
        mcpServer = nil
        try? await channel?.close()
        channel = nil
        try? await group?.shutdownGracefully()
        group = nil
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

    private func buildStoreKnowledgeSchema() throws -> Value {
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

    // MARK: - MCP Tool Registration

    private func registerTools(on server: Server) async throws {
        let memoryRef = memory
        let entityTypesRef = entityTypes
        let knowledgeSchema = try buildStoreKnowledgeSchema()
        let recallSchema = try RecallInput.schemaValue()
        let storeSchema = buildStoreInputSchema(knowledgeSchema: knowledgeSchema)

        // Build HOOT at registration time — embedded in store description
        let hoot = memoryRef.ontologyPolicy.buildOntology().toHoot(mode: .compact)
        let storeDescription = """
        Store structured knowledge in memory. \
        The inputSchema defines the structure (what fields to pass). \
        The ontology below defines the semantic constraints (class hierarchy, disjoint classes, valid predicates, transitivity, domain/range).

        ## Ontology Constraints (HOOT)
        \(hoot)
        """

        await server.withMethodHandler(ListTools.self) { _ in
            .init(tools: [
                Tool(
                    name: "recall",
                    description: "Recall associated knowledge from memory via spreading activation.",
                    inputSchema: recallSchema
                ),
                Tool(
                    name: "store",
                    description: storeDescription,
                    inputSchema: storeSchema
                )
            ])
        }

        await server.withMethodHandler(CallTool.self) { [weak self] params in
            guard let self else {
                return .init(content: [.text(text: "Server shutting down", annotations: nil, _meta: nil)], isError: true)
            }
            switch params.name {
            case "recall":
                return await self.handleRecall(params: params, memory: memoryRef)
            case "store":
                return await self.handleStore(params: params, memory: memoryRef, entityTypes: entityTypesRef)
            default:
                return .init(content: [.text(text: "Unknown tool: \(params.name)", annotations: nil, _meta: nil)], isError: true)
            }
        }
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

            try await memory.store(given: givenText, knowledgeData: jsonData) { data, givenID in
                try Self.decodeKnowledge(data, entityTypes: capturedTypes, givenID: givenID)
            }
            return .init(content: [.text(text: "Stored successfully", annotations: nil, _meta: nil)], isError: false)
        } catch {
            return .init(content: [.text(text: "Store failed: \(error.localizedDescription)", annotations: nil, _meta: nil)], isError: true)
        }
    }

    // MARK: - Knowledge Decode

    private static func decodeKnowledge(
        _ data: Data,
        entityTypes: [any MemoryStorable.Type],
        givenID: String
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
                entity.givenID = givenID
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

// MARK: - NIO HTTP Handler

/// Thin NIO adapter that converts between NIO HTTP types and the framework-agnostic
/// `HTTPRequest`/`HTTPResponse` types. All MCP logic is delegated to the transport.
private final class MCPHTTPHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let transport: StatefulHTTPServerTransport
    private let endpoint: String
    private let logger: Logger

    private struct RequestState {
        var head: HTTPRequestHead
        var bodyBuffer: ByteBuffer
    }
    private var requestState: RequestState?

    init(transport: StatefulHTTPServerTransport, endpoint: String, logger: Logger) {
        self.transport = transport
        self.endpoint = endpoint
        self.logger = logger
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let part = unwrapInboundIn(data)
        switch part {
        case .head(let head):
            requestState = RequestState(
                head: head,
                bodyBuffer: context.channel.allocator.buffer(capacity: 0)
            )
        case .body(var buffer):
            requestState?.bodyBuffer.writeBuffer(&buffer)
        case .end:
            guard let state = requestState else { return }
            requestState = nil

            nonisolated(unsafe) let ctx = context
            Task {
                await self.handleRequest(state: state, context: ctx)
            }
        }
    }

    private func handleRequest(state: RequestState, context: ChannelHandlerContext) async {
        let head = state.head
        let path = head.uri.split(separator: "?").first.map(String.init) ?? head.uri

        guard path == endpoint else {
            let response = HTTPResponse.error(statusCode: 404, .invalidRequest("Not Found"))
            await writeResponse(response, version: head.version, context: context)
            return
        }

        let httpRequest = makeHTTPRequest(from: state)
        let response = await transport.handleRequest(httpRequest)
        await writeResponse(response, version: head.version, context: context)
    }

    private func makeHTTPRequest(from state: RequestState) -> MCP.HTTPRequest {
        var headers: [String: String] = [:]
        for (name, value) in state.head.headers {
            if let existing = headers[name] {
                headers[name] = existing + ", " + value
            } else {
                headers[name] = value
            }
        }

        let body: Data?
        if state.bodyBuffer.readableBytes > 0,
           let bytes = state.bodyBuffer.getBytes(at: 0, length: state.bodyBuffer.readableBytes)
        {
            body = Data(bytes)
        } else {
            body = nil
        }

        let path = String(state.head.uri.split(separator: "?").first ?? Substring(state.head.uri))

        return MCP.HTTPRequest(
            method: state.head.method.rawValue,
            headers: headers,
            body: body,
            path: path
        )
    }

    private func writeResponse(
        _ response: HTTPResponse,
        version: HTTPVersion,
        context: ChannelHandlerContext
    ) async {
        nonisolated(unsafe) let ctx = context
        let eventLoop = ctx.eventLoop

        let statusCode = response.statusCode
        let headers = response.headers

        switch response {
        case .stream(let stream, _):
            eventLoop.execute {
                var head = HTTPResponseHead(version: version, status: .init(statusCode: statusCode))
                for (name, value) in headers {
                    head.headers.add(name: name, value: value)
                }
                ctx.write(self.wrapOutboundOut(.head(head)), promise: nil)
                ctx.flush()
            }

            do {
                for try await chunk in stream {
                    eventLoop.execute {
                        var buffer = ctx.channel.allocator.buffer(capacity: chunk.count)
                        buffer.writeBytes(chunk)
                        ctx.writeAndFlush(self.wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
                    }
                }
            } catch {
                self.logger.warning("SSE stream error: \(error)")
            }

            eventLoop.execute {
                ctx.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: nil)
            }

        default:
            let bodyData = response.bodyData
            eventLoop.execute {
                var head = HTTPResponseHead(version: version, status: .init(statusCode: statusCode))
                for (name, value) in headers {
                    head.headers.add(name: name, value: value)
                }
                ctx.write(self.wrapOutboundOut(.head(head)), promise: nil)
                if let body = bodyData {
                    var buffer = ctx.channel.allocator.buffer(capacity: body.count)
                    buffer.writeBytes(body)
                    ctx.write(self.wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
                }
                ctx.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: nil)
            }
        }
    }
}
