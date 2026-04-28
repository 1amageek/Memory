# Memory

MCP server and embedding providers for [`swift-memory`](https://github.com/1amageek/swift-memory).

This package wires `swift-memory`'s knowledge persistence and associative recall into the Model Context Protocol so any MCP-compatible agent (Claude Code, custom clients) can store and recall structured knowledge through tool calls.

```
┌─ Agent (LLM) ────────────────────────────┐
│   tools/list  →  recall, store, ontology │
└──────────────┬───────────────────────────┘
               │ MCP (HTTP or stdio)
               ▼
┌─ MemoryMCP ──────────────────────────────┐
│  • Dynamic JSON Schema from entity types │
│  • Ontology (HOOT) embedded in store     │
│  • NIO HTTP transport / Stdio transport  │
└──────────────┬───────────────────────────┘
               ▼
┌─ swift-memory ───────────────────────────┐
│  Memory actor                            │
│   ├─ store: assertion-embedding dedup    │
│   └─ recall: spreading activation        │
└──────────────┬───────────────────────────┘
               ▼
┌─ MemoryEmbedding ────────────────────────┐
│  MLXEmbeddingProvider   (768d, on-device)│
│  AppleEmbeddingProvider (512d, on-device)│
└──────────────────────────────────────────┘
```

## Modules

| Product | Purpose |
|---|---|
| `MemoryMCP` | MCP server (HTTP + stdio) exposing `recall` / `store` / `ontology` tools. Generates the `store` input schema dynamically from registered entity types. |
| `MemoryEmbedding` | On-device `EmbeddingProvider` implementations: MLX-backed EmbeddingGemma 300M and Apple's `NLContextualEmbedding`. |

The persistence engine, ontology, and recall algorithm live in `swift-memory`. This package adds the agent-facing transport layer and embedding implementations.

## Requirements

- macOS 26+
- Swift 6.2+
- Apple Silicon (for `MLXEmbeddingProvider`)

## Installation

```swift
.package(url: "https://github.com/1amageek/Memory.git", branch: "main")
```

```swift
.target(
    name: "YourApp",
    dependencies: [
        .product(name: "MemoryMCP", package: "Memory"),
        .product(name: "MemoryEmbedding", package: "Memory"),
    ]
)
```

## Quick Start

### 1. Define entity types

Each storable entity needs three macros plus a `storeKey` that names the JSON field the `store` tool will accept:

```swift
import Database
import SwiftGeneration
import SwiftMemory
import MemoryMCP

@Persistable
@OWLClass("ex:Person", graph: "memory:default")
@Generable(description: "A person")
public struct Person: Entity {
    #Directory<Person>("app", "persons")

    public var id: String = UUID().uuidString

    @OWLDataProperty("rdfs:label")
    @Guide(description: "Full name")
    public var name: String = ""

    @Guide(description: "Natural-language class assertion. Format: '<name> is a person. <distinguishing facts>'")
    public var assertion: String = ""

    public var embedding: [Float] = []
}

extension Person: MemoryStorable {
    public static let storeKey = "persons"
}
```

### 2. Start an HTTP MCP server

```swift
import SwiftMemory
import MemoryMCP
import MemoryEmbedding

let provider = try await MLXEmbeddingProvider()

let memory = try await Memory(
    path: "memory.sqlite",
    entityTypes: [Person.self],
    embeddingProvider: provider
)

let server = MemoryMCPHTTPServer(
    memory: memory,
    entityTypes: [Person.self]
)
let port = try await server.start()
print("MCP endpoint: http://127.0.0.1:\(port)/mcp")
```

### 3. Or run a stdio server (for plugin-bundled executables)

```swift
import MemoryMCP

let server = MemoryMCPStdioServer(
    memory: memory,
    entityTypes: [Person.self]
)
try await server.run()  // blocks until stdin closes
```

## MCP Tools

The server registers three tools at `tools/list`. The `store` input schema is built at registration time from the entity types you pass in.

### `recall`

Spreading activation over the knowledge graph.

| Parameter | Type | Default | Description |
|---|---|---|---|
| `keywords` | `[string]` | required | Cues matched against `rdfs:label` |
| `maxHops` | `int` | `2` | Graph traversal depth |
| `limit` | `int` | `20` | Max entities returned |

Entities reached from multiple keywords score higher (convergence). Each result carries the traversal paths used, for explainability.

### `store`

Persist `Given` (raw text) plus `Knowledge` (typed entities + relationship triples) atomically.

```json
{
  "given": "Alice joined Acme Corp. Email: alice@acme.com",
  "knowledge": {
    "persons": [{
      "name": "Alice",
      "assertion": "Alice is a person who works at Acme Corp."
    }],
    "organizations": [{
      "name": "Acme Corp",
      "assertion": "Acme Corp is a company providing cloud infrastructure."
    }],
    "relationships": [{
      "subject": "Alice",
      "predicate": "ex:worksAt",
      "object": "Acme Corp"
    }]
  }
}
```

The HTTP server **embeds the ontology in HOOT compact format inside the `store` tool's description**, so an agent gets both structure (`inputSchema`) and semantic constraints (class hierarchy, disjoint classes, predicate domain/range) in a single `tools/list` round trip.

Entities are deduplicated by `swift-memory` via cosine similarity on the `assertion` embedding (default threshold 0.95). When a duplicate is detected, relationship statements are remapped to the canonical entity ID.

### `ontology`

Returns the active ontology in HOOT compact format. Useful for an agent that wants to inspect the vocabulary explicitly rather than reading it out of the `store` description.

## Embedding Providers

Both providers are `actor`s and conform to `SwiftMemory.EmbeddingProvider`.

| | `MLXEmbeddingProvider` | `AppleEmbeddingProvider` |
|---|---|---|
| Backend | MLX Embedders + HuggingFace | `NLContextualEmbedding` |
| Default model | `mlx-community/embeddinggemma-300m-bf16` | OS-bundled, language-scoped |
| Dimensions | 768 (probed from the live model) | 512 (mean-pool + L2 normalize) |
| Pooling | Sentence-Transformer `Pooling` + L2 norm | Manual mean-pool |
| Languages | 100+ via EmbeddingGemma | One per script family |
| Use case | Entity resolution where vocabulary overlap is common | Lightweight fallback / OS-only |

### Why two providers

`AppleEmbeddingProvider` mean-pools raw token vectors from `NLContextualEmbedding` without the normalization head that Sentence-Transformer models ship with. For inputs that share surface vocabulary but denote different entities (different LLM product names, similarly-worded organization assertions), this inflates cosine similarity past safe dedup thresholds.

`MLXEmbeddingProvider` delegates pooling and L2 normalization to MLX's Sentence-Transformer compatible `Pooling`, restoring the separability the upstream model was trained for. Use it when the application stores semantically-overlapping content.

### Custom prefix

EmbeddingGemma uses task-specific input prefixes. The default is the symmetric similarity prompt, designed for pairwise comparison (entity resolution semantics):

```swift
MLXEmbeddingProvider(
    inputPrefix: "task: sentence similarity | query: "  // default
)
```

For asymmetric retrieval (query vs document):

```swift
// query side
MLXEmbeddingProvider(inputPrefix: "task: search result | query: ")
// document side
MLXEmbeddingProvider(inputPrefix: "title: none | text: ")
```

## `MemoryStorable` Protocol

A minimal composition over `Persistable + Entity + Generable`:

```swift
public protocol MemoryStorable: Persistable, Entity, Generable {
    static var storeKey: String { get }
}
```

| Inherited from | Provides |
|---|---|
| `Persistable` (database-kit) | SQLite/FDB persistence, polymorphic directory |
| `Entity` (swift-memory) | `assertion` + `embedding` for cross-type vector index |
| `Generable` (swift-generation) | JSON Schema generation for the MCP `store` input |

The only field this package adds is `storeKey` — the JSON key under which the type's array appears inside the `knowledge` payload (`"persons"`, `"organizations"`, etc).

## Transport Selection

| | `MemoryMCPHTTPServer` | `MemoryMCPStdioServer` |
|---|---|---|
| Transport | HTTP at `/mcp`, NIO-based | stdin/stdout |
| Use case | In-process server inside a host app | Plugin-bundled executable |
| Discovery | `url` / `port` exposed after `start()` | N/A |
| Lifecycle | `start()` / `stop()` | `run()` blocks until stdin closes |
| Ontology in `store` description | Yes (HOOT compact) | No (use the `ontology` tool) |

## Plugin `.mcp.json`

For Claude Code plugins, declare the HTTP server in your plugin root (note: plugin `.mcp.json` does **not** use the `mcpServers` wrapper):

```json
{
  "memory": {
    "type": "http",
    "url": "http://127.0.0.1:${YOUR_MCP_PORT}/mcp"
  }
}
```

Pass the port via `ClaudeCodeConfiguration.environment` so the CLI expands it at launch.

## Design Notes

- **Concept is external.** `swift-memory` persists `Given` (raw material) and `Knowledge` (RDF triples). Interpretation — turning `Given` into entities + relationships — is the responsibility of the calling agent, exercised through the `store` tool. This package does not embed an LLM.
- **Schema is derived from types.** Entity types passed to the server are introspected at registration time. Adding a new entity type means writing the struct and conforming to `MemoryStorable`; no schema configuration files.
- **Ontology travels with `store`.** Embedding HOOT in the tool description guarantees the agent sees both structure and semantic constraints in one round trip, without a second `ontology()` call.
- **Identity is assertion-driven.** Entities deduplicate by cosine similarity on the `assertion` field (`"<name> is a <class>. <discriminators>"`), not by name. Same assertion text → same embedding → strict store-time dedup.

## License

See `LICENSE`.
