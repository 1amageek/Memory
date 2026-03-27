// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "Memory",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "Memory", targets: ["Memory"]),
        .library(name: "MemoryMCP", targets: ["MemoryMCP"]),
        .library(name: "MemoryMCPHTTP", targets: ["MemoryMCPHTTP"]),
        .executable(name: "MemoryMCPServer", targets: ["MemoryMCPServer"]),
    ],
    dependencies: [
        .package(url: "https://github.com/1amageek/swift-memory.git", branch: "main"),
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", branch: "main"),
        .package(url: "https://github.com/1amageek/database-framework.git", branch: "main", traits: ["SQLite"]),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.97.0"),
    ],
    targets: [
        .target(
            name: "Memory",
            dependencies: [
                .product(name: "SwiftMemory", package: "swift-memory"),
                .product(name: "Database", package: "database-framework"),
            ]
        ),
        .target(
            name: "MemoryMCP",
            dependencies: [
                "Memory",
                .product(name: "MCP", package: "swift-sdk"),
            ]
        ),
        .target(
            name: "MemoryMCPHTTP",
            dependencies: [
                "MemoryMCP",
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
            ]
        ),
        .executableTarget(
            name: "MemoryMCPServer",
            dependencies: ["MemoryMCP"]
        ),
        .testTarget(
            name: "MemoryTests",
            dependencies: ["Memory"]
        ),
        .testTarget(
            name: "MemoryMCPHTTPTests",
            dependencies: [
                "MemoryMCPHTTP",
                "Memory",
                "MemoryMCP",
                .product(name: "SwiftMemory", package: "swift-memory"),
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
            ]
        ),
    ]
)
