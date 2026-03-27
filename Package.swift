// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "Memory",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "MemoryMCP", targets: ["MemoryMCP"])
    ],
    dependencies: [
        .package(url: "https://github.com/1amageek/swift-memory.git", branch: "main"),
        .package(url: "https://github.com/1amageek/swift-generation.git", from: "0.2.0"),
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", branch: "main"),
        .package(url: "https://github.com/1amageek/database-framework.git", branch: "main", traits: ["SQLite"]),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.97.0"),
    ],
    targets: [
        .target(
            name: "MemoryMCP",
            dependencies: [
                .product(name: "SwiftMemory", package: "swift-memory"),
                .product(name: "Generation", package: "swift-generation"),
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "Database", package: "database-framework"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
            ]
        ),
        .testTarget(
            name: "MemoryMCPTests",
            dependencies: [
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
