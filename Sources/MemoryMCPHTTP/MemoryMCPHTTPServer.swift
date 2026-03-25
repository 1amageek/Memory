// MemoryMCPHTTPServer.swift
// Lightweight HTTP server for Memory MCP

import Foundation
import Synchronization
import MCP
import Memory
import MemoryMCP
import Logging
@preconcurrency import NIOCore
@preconcurrency import NIOPosix
@preconcurrency import NIOHTTP1

/// In-process HTTP MCP server for Memory.
///
/// ```swift
/// let server = MemoryMCPHTTPServer(service: memoryService)
/// let port = try await server.start()
/// // url = "http://127.0.0.1:\(port)/mcp"
/// ```
public actor MemoryMCPHTTPServer {

    private let service: MemoryService
    private let storeConfig: StoreToolConfig
    private let host: String
    private let requestedPort: Int
    private var channel: Channel?
    private let logger = Logger(label: "memory.mcp.http")

    public private(set) var port: Int = 0
    public var url: String { "http://\(host):\(port)/mcp" }

    public init(service: MemoryService, storeConfig: StoreToolConfig, host: String = "127.0.0.1", port: Int = 0) {
        self.service = service
        self.storeConfig = storeConfig
        self.host = host
        self.requestedPort = port
    }

    @discardableResult
    public func start() async throws -> Int {
        let serviceRef = service
        let storeConfigRef = storeConfig
        let loggerRef = logger

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(.backlog, value: 32)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline().flatMap {
                    channel.pipeline.addHandler(
                        MCPHTTPHandler(service: serviceRef, storeConfig: storeConfigRef, endpoint: "/mcp", logger: loggerRef)
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
        try? await channel?.close()
        channel = nil
    }
}

// MARK: - HTTP Handler

private final class MCPHTTPHandler: ChannelInboundHandler, Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let service: MemoryService
    private let storeConfig: StoreToolConfig
    private let endpoint: String
    private let logger: Logger

    private struct RequestState: Sendable {
        var head: HTTPRequestHead?
        var body: Data = Data()
        var sessions: [String: (server: Server, transport: StatefulHTTPServerTransport)] = [:]
    }
    private let state = Mutex(RequestState())

    init(service: MemoryService, storeConfig: StoreToolConfig, endpoint: String, logger: Logger) {
        self.service = service
        self.storeConfig = storeConfig
        self.endpoint = endpoint
        self.logger = logger
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let part = unwrapInboundIn(data)
        switch part {
        case .head(let head):
            state.withLock { $0.head = head; $0.body = Data() }
        case .body(var body):
            if let bytes = body.readBytes(length: body.readableBytes) {
                state.withLock { $0.body.append(contentsOf: bytes) }
            }
        case .end:
            let (head, body) = state.withLock { ($0.head, $0.body) }
            guard let head else { return }
            let ctx = context
            Task { await self.handleRequest(head: head, body: body, context: ctx) }
        }
    }

    private func handleRequest(head: HTTPRequestHead, body: Data, context: ChannelHandlerContext) async {
        guard head.uri.hasPrefix(endpoint) else {
            respond(context: context, version: head.version, status: .notFound, body: nil)
            return
        }

        let sessionID = head.headers["Mcp-Session-Id"].first ?? UUID().uuidString

        // Get or create session
        let existingSession = state.withLock { $0.sessions[sessionID] }

        let session: (server: Server, transport: StatefulHTTPServerTransport)
        if let existing = existingSession {
            session = existing
        } else {
            let transport = StatefulHTTPServerTransport()
            let server = Server(
                name: "memory",
                version: "0.1.0",
                capabilities: .init(tools: .init())
            )
            await MemoryMCP.registerTools(on: server, service: self.service, storeConfig: self.storeConfig)
            do {
                try await server.start(transport: transport)
            } catch {
                logger.error("Failed to start MCP session: \(error)")
                respond(context: context, version: head.version, status: .internalServerError, body: nil)
                return
            }
            session = (server, transport)
            state.withLock { $0.sessions[sessionID] = session }
        }

        // Build HTTPRequest
        var headers: [String: String] = [:]
        for (name, value) in head.headers {
            headers[name] = value
        }
        let method: String
        switch head.method {
        case .GET: method = "GET"
        case .POST: method = "POST"
        case .DELETE: method = "DELETE"
        default: method = head.method.rawValue
        }

        let httpRequest = MCP.HTTPRequest(
            method: method,
            headers: headers,
            body: body.isEmpty ? nil : body
        )

        let httpResponse = await session.transport.handleRequest(httpRequest)

        // Send response
        var responseHead = HTTPResponseHead(version: head.version, status: .init(statusCode: httpResponse.statusCode))
        for (key, value) in httpResponse.headers {
            responseHead.headers.add(name: key, value: value)
        }

        switch httpResponse {
        case .accepted, .ok:
            context.write(wrapOutboundOut(.head(responseHead)), promise: nil)
            context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)

        case .data(let data, _):
            var buffer = context.channel.allocator.buffer(capacity: data.count)
            buffer.writeBytes(data)
            context.write(wrapOutboundOut(.head(responseHead)), promise: nil)
            context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
            context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)

        case .stream(let stream, _):
            responseHead.headers.replaceOrAdd(name: "Content-Type", value: "text/event-stream")
            responseHead.headers.replaceOrAdd(name: "Cache-Control", value: "no-cache")
            context.write(wrapOutboundOut(.head(responseHead)), promise: nil)
            context.flush()
            Task {
                do {
                    for try await chunk in stream {
                        var buffer = context.channel.allocator.buffer(capacity: chunk.count)
                        buffer.writeBytes(chunk)
                        context.write(self.wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
                        context.flush()
                    }
                } catch {}
                context.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: nil)
            }

        case .error(let statusCode, let error, _, _):
            responseHead.status = .init(statusCode: statusCode)
            if let errorData = try? JSONEncoder().encode(error) {
                var buffer = context.channel.allocator.buffer(capacity: errorData.count)
                buffer.writeBytes(errorData)
                context.write(wrapOutboundOut(.head(responseHead)), promise: nil)
                context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
            } else {
                context.write(wrapOutboundOut(.head(responseHead)), promise: nil)
            }
            context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
        }
    }

    private func respond(context: ChannelHandlerContext, version: HTTPVersion, status: HTTPResponseStatus, body: Data?) {
        var head = HTTPResponseHead(version: version, status: status)
        var buffer = context.channel.allocator.buffer(capacity: body?.count ?? 0)
        if let body { buffer.writeBytes(body) }
        head.headers.add(name: "Content-Length", value: "\(buffer.readableBytes)")
        context.write(wrapOutboundOut(.head(head)), promise: nil)
        context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
        context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
    }
}
