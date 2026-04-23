// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "Memory",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "MemoryMCP", targets: ["MemoryMCP"]),
        .library(name: "MemoryEmbedding", targets: ["MemoryEmbedding"]),
    ],
    dependencies: [
        .package(url: "https://github.com/1amageek/swift-memory.git", from: "26.0423.1"),
        .package(url: "https://github.com/1amageek/swift-generation.git", from: "0.5.0"),
        .package(url: "https://github.com/1amageek/mcp-swift-sdk.git", branch: "fix/network-transport-data-race"),
        .package(url: "https://github.com/1amageek/database-framework.git", branch: "main", traits: ["SQLite"]),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.97.1"),
        .package(url: "https://github.com/1amageek/mlx-swift-lm.git", branch: "main"),
        .package(url: "https://github.com/huggingface/swift-transformers.git", from: "1.3.0"),
        .package(url: "https://github.com/huggingface/swift-huggingface.git", from: "0.9.0"),
    ],
    targets: [
        .target(
            name: "MemoryMCP",
            dependencies: [
                .product(name: "SwiftMemory", package: "swift-memory"),
                .product(name: "SwiftGeneration", package: "swift-generation"),
                .product(name: "MCP", package: "mcp-swift-sdk"),
                .product(name: "Database", package: "database-framework"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
            ]
        ),
        .target(
            name: "MemoryEmbedding",
            dependencies: [
                .product(name: "SwiftMemory", package: "swift-memory"),
                .product(name: "MLXEmbedders", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
                .product(name: "HuggingFace", package: "swift-huggingface"),
                .product(name: "Tokenizers", package: "swift-transformers"),
            ]
        ),
        .testTarget(
            name: "MemoryMCPTests",
            dependencies: [
                "MemoryMCP",
                .product(name: "SwiftMemory", package: "swift-memory"),
                .product(name: "MCP", package: "mcp-swift-sdk"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
            ]
        ),
        .testTarget(
            name: "MemoryEmbeddingTests",
            dependencies: [
                "MemoryEmbedding",
            ]
        ),
    ]
)
