// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "Memory",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "Memory", targets: ["Memory"]),
        .library(name: "MemoryMCP", targets: ["MemoryMCP"]),
        .executable(name: "MemoryMCPServer", targets: ["MemoryMCPServer"]),
    ],
    dependencies: [
        .package(url: "https://github.com/1amageek/swift-memory.git", branch: "main"),
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", branch: "main"),
        .package(url: "https://github.com/1amageek/database-framework.git", branch: "main", traits: ["SQLite"]),
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
        .executableTarget(
            name: "MemoryMCPServer",
            dependencies: ["MemoryMCP"]
        ),
        .testTarget(
            name: "MemoryTests",
            dependencies: ["Memory"]
        ),
    ]
)
