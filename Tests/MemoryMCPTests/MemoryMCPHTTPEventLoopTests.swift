// MemoryMCPHTTPEventLoopTests.swift
// Verify NIO Channel writes happen on the EventLoop (regression test)

import Testing
import Foundation
@testable import MemoryMCP
import MCP
import SwiftMemory

/// Integration tests for MemoryMCPHTTPServer.
///
/// If any NIO Channel write happens off-EventLoop, NIO raises
/// `preconditionInEventLoop` failure and the process terminates.
/// A passing test proves the threading is correct.
@Suite(.tags(.integration), .serialized)
struct MemoryMCPHTTPEventLoopTests {

    // MARK: - Helpers

    private func makeServer() async throws -> (server: MemoryMCPHTTPServer, port: Int) {
        let memory = try await Memory(path: nil)
        let server = MemoryMCPHTTPServer(
            memory: memory,
            entityTypes: [] as [any MemoryStorable.Type]
        )
        let port = try await server.start()
        return (server, port)
    }

    /// Initialize session, return session ID.
    private func initializeSession(port: Int) async throws -> String {
        let url = URL(string: "http://127.0.0.1:\(port)/mcp")!
        let body: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": [
                "protocolVersion": "2025-03-26",
                "capabilities": [:] as [String: Any],
                "clientInfo": ["name": "test", "version": "0.1"]
            ]
        ]
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (_, response) = try await URLSession.shared.data(for: request)
        let http = response as! HTTPURLResponse
        guard http.statusCode == 200 else {
            throw MCPTestError.unexpectedStatus(http.statusCode)
        }
        guard let sessionID = http.value(forHTTPHeaderField: "Mcp-Session-Id") else {
            throw MCPTestError.missingSessionID
        }

        // Send initialized notification
        let notifBody: [String: Any] = ["jsonrpc": "2.0", "method": "notifications/initialized"]
        var notif = URLRequest(url: url)
        notif.httpMethod = "POST"
        notif.setValue("application/json", forHTTPHeaderField: "Content-Type")
        notif.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        notif.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id")
        notif.httpBody = try JSONSerialization.data(withJSONObject: notifBody)
        let (_, notifResp) = try await URLSession.shared.data(for: notif)
        guard (notifResp as! HTTPURLResponse).statusCode == 202 else {
            throw MCPTestError.unexpectedStatus((notifResp as! HTTPURLResponse).statusCode)
        }

        return sessionID
    }

    private func postMCP(
        port: Int,
        sessionID: String,
        body: [String: Any]
    ) async throws -> (data: Data, status: Int, headers: [AnyHashable: Any]) {
        let url = URL(string: "http://127.0.0.1:\(port)/mcp")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        let http = response as! HTTPURLResponse
        return (data, http.statusCode, http.allHeaderFields)
    }

    // MARK: - Initialize (POST → SSE stream)

    @Test(.timeLimit(.minutes(1)))
    func initialize_returnsSessionID() async throws {
        let (server, port) = try await makeServer()
        defer { Task { await server.stop() } }

        let sessionID = try await initializeSession(port: port)
        #expect(!sessionID.isEmpty)
    }

    // MARK: - 404 for non-MCP path

    @Test(.timeLimit(.minutes(1)))
    func nonMCPPath_returns404() async throws {
        let (server, port) = try await makeServer()
        defer { Task { await server.stop() } }

        let url = URL(string: "http://127.0.0.1:\(port)/not-mcp")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("{}".utf8)

        let (_, response) = try await URLSession.shared.data(for: request)
        #expect((response as! HTTPURLResponse).statusCode == 404)
    }

    // MARK: - Concurrent non-MCP requests (concurrent EventLoop writes)

    @Test(.timeLimit(.minutes(1)))
    func concurrent404_allWriteOnEventLoop() async throws {
        let (server, port) = try await makeServer()
        defer { Task { await server.stop() } }

        try await withThrowingTaskGroup(of: Int.self) { group in
            for i in 0..<10 {
                group.addTask {
                    let url = URL(string: "http://127.0.0.1:\(port)/path-\(i)")!
                    var request = URLRequest(url: url)
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.httpBody = Data("{}".utf8)
                    let (_, response) = try await URLSession.shared.data(for: request)
                    return (response as! HTTPURLResponse).statusCode
                }
            }
            for try await statusCode in group {
                #expect(statusCode == 404)
            }
        }
    }

    // MARK: - tools/list (async MCP processing → SSE stream → EventLoop)

    @Test(.timeLimit(.minutes(1)))
    func toolsList_returnsTools() async throws {
        let (server, port) = try await makeServer()
        defer { Task { await server.stop() } }

        let sessionID = try await initializeSession(port: port)

        let (data, status, _) = try await postMCP(
            port: port, sessionID: sessionID,
            body: ["jsonrpc": "2.0", "id": 2, "method": "tools/list"]
        )
        #expect(status == 200)
        // SSE body should contain "recall", "store", "ontology" tool names
        let bodyString = String(decoding: data, as: UTF8.self)
        #expect(bodyString.contains("recall"))
        #expect(bodyString.contains("store"))
        #expect(bodyString.contains("ontology"))
    }

    // MARK: - tools/call recall (async MemoryService processing)

    @Test(.timeLimit(.minutes(1)))
    func toolsCallRecall_exercisesAsyncServicePath() async throws {
        let (server, port) = try await makeServer()
        defer { Task { await server.stop() } }

        let sessionID = try await initializeSession(port: port)

        let (data, status, _) = try await postMCP(
            port: port, sessionID: sessionID,
            body: [
                "jsonrpc": "2.0", "id": 3, "method": "tools/call",
                "params": [
                    "name": "recall",
                    "arguments": ["keywords": ["nonexistent"]]
                ] as [String: Any]
            ]
        )
        #expect(status == 200)
        let bodyString = String(decoding: data, as: UTF8.self)
        #expect(bodyString.contains("result"))
    }

    // MARK: - Concurrent MCP tool calls after initialize

    @Test(.timeLimit(.minutes(1)))
    func concurrentToolCalls_allWriteOnEventLoop() async throws {
        let (server, port) = try await makeServer()
        defer { Task { await server.stop() } }

        let sessionID = try await initializeSession(port: port)

        // Send concurrent tools/call requests.
        // Each goes through: transport.handleRequest (async actor call) →
        // Server dispatches to MemoryService (async) → SSE stream response → EventLoop write.
        try await withThrowingTaskGroup(of: Int.self) { group in
            for i in 0..<10 {
                group.addTask {
                    let (_, status, _) = try await self.postMCP(
                        port: port, sessionID: sessionID,
                        body: [
                            "jsonrpc": "2.0", "id": 100 + i, "method": "tools/call",
                            "params": [
                                "name": "recall",
                                "arguments": ["keywords": ["keyword-\(i)"]]
                            ] as [String: Any]
                        ]
                    )
                    return status
                }
            }
            for try await statusCode in group {
                #expect(statusCode == 200)
            }
        }
    }

    // MARK: - Request without session ID after initialize → transport error

    @Test(.timeLimit(.minutes(1)))
    func missingSessionID_returnsError() async throws {
        let (server, port) = try await makeServer()
        defer { Task { await server.stop() } }

        _ = try await initializeSession(port: port)

        // Send a request without Mcp-Session-Id header
        let url = URL(string: "http://127.0.0.1:\(port)/mcp")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "id": 99, "method": "tools/list"
        ] as [String: Any])

        let (_, response) = try await URLSession.shared.data(for: request)
        let status = (response as! HTTPURLResponse).statusCode
        // Transport rejects — missing session ID on non-initialize request
        #expect(status >= 400)
    }

    // MARK: - DELETE session → ok response

    @Test(.timeLimit(.minutes(1)))
    func deleteSession_returns200() async throws {
        let (server, port) = try await makeServer()
        defer { Task { await server.stop() } }

        let sessionID = try await initializeSession(port: port)

        let url = URL(string: "http://127.0.0.1:\(port)/mcp")!
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id")

        let (_, response) = try await URLSession.shared.data(for: request)
        #expect((response as! HTTPURLResponse).statusCode == 200)
    }

    // MARK: - Request after DELETE → terminated

    @Test(.timeLimit(.minutes(1)))
    func requestAfterDelete_returns404() async throws {
        let (server, port) = try await makeServer()
        defer { Task { await server.stop() } }

        let sessionID = try await initializeSession(port: port)

        // DELETE
        let url = URL(string: "http://127.0.0.1:\(port)/mcp")!
        var deleteReq = URLRequest(url: url)
        deleteReq.httpMethod = "DELETE"
        deleteReq.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id")
        let (_, delResp) = try await URLSession.shared.data(for: deleteReq)
        #expect((delResp as! HTTPURLResponse).statusCode == 200)

        // Subsequent request should fail — session terminated
        let (_, status, _) = try await postMCP(
            port: port, sessionID: sessionID,
            body: ["jsonrpc": "2.0", "id": 50, "method": "tools/list"]
        )
        #expect(status == 404)
    }

    // MARK: - Server stop during active session

    @Test(.timeLimit(.minutes(1)))
    func stopDuringActiveSession_cleansUpWithoutCrash() async throws {
        let (server, port) = try await makeServer()

        let sessionID = try await initializeSession(port: port)

        // Issue a tool call so there's active processing
        async let toolCall: (Data, Int, [AnyHashable: Any]) = postMCP(
            port: port, sessionID: sessionID,
            body: [
                "jsonrpc": "2.0", "id": 10, "method": "tools/call",
                "params": [
                    "name": "recall",
                    "arguments": ["keywords": ["test"]]
                ] as [String: Any]
            ]
        )

        // Stop while request may still be in flight
        await server.stop()

        // The tool call may succeed or fail — we only care that no crash occurs
        do {
            _ = try await toolCall
        } catch {
            // Request may fail because the server was stopped during processing.
        }
    }
}

// MARK: - Test Errors

private enum MCPTestError: Error {
    case unexpectedStatus(Int)
    case missingSessionID
}

extension Tag {
    @Tag static var integration: Self
}
