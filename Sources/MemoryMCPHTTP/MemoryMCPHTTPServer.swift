// MemoryMCPHTTPServer.swift
// In-process HTTP server for Memory MCP

import Foundation
import MCP
import Memory
import MemoryMCP
import Logging
@preconcurrency import NIOCore
@preconcurrency import NIOPosix
@preconcurrency import NIOHTTP1

/// In-process HTTP MCP server for Memory.
///
/// Creates a single MCP session backed by `StatefulHTTPServerTransport`.
/// The NIO handler is a thin bridge — all MCP protocol logic
/// (session lifecycle, SSE streaming, event replay) is handled by the transport.
///
/// ```swift
/// let server = MemoryMCPHTTPServer(service: memoryService, storeConfig: config)
/// let port = try await server.start()
/// // url = "http://127.0.0.1:\(port)/mcp"
/// ```
public actor MemoryMCPHTTPServer {

    private let service: MemoryService
    private let storeConfig: StoreToolConfig
    private let host: String
    private let requestedPort: Int

    private var group: EventLoopGroup?
    private var channel: Channel?
    private var mcpServer: Server?
    private var transport: StatefulHTTPServerTransport?

    private let logger = Logger(label: "memory.mcp.http")

    public private(set) var port: Int = 0
    public var url: String { "http://\(host):\(port)/mcp" }

    public init(service: MemoryService, storeConfig: StoreToolConfig, host: String = "127.0.0.1", port: Int = 0) {
        self.service = service
        self.storeConfig = storeConfig
        self.host = host
        self.requestedPort = port
    }

    // MARK: - Lifecycle

    @discardableResult
    public func start() async throws -> Int {
        // Create a single transport + MCP server for the lifetime of this HTTP server.
        let transport = StatefulHTTPServerTransport(logger: logger)
        let mcpServer = Server(
            name: "memory",
            version: "0.1.0",
            capabilities: .init(tools: .init())
        )
        await MemoryMCP.registerTools(on: mcpServer, service: service, storeConfig: storeConfig)
        try await mcpServer.start(transport: transport)
        self.mcpServer = mcpServer
        self.transport = transport

        // Start NIO. All handlers share the same transport reference.
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

    // MARK: - Inbound

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

    // MARK: - Request Processing

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

    // MARK: - NIO ↔ HTTPRequest Conversion

    private func makeHTTPRequest(from state: RequestState) -> MCP.HTTPRequest {
        // Combine multiple header values per RFC 7230
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

    // MARK: - HTTPResponse → NIO

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
