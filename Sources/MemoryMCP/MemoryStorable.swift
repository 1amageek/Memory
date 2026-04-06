// MemoryStorable.swift
// Protocol for entity types that can be stored via MCP store tool

import Foundation
import MCP
import Database
@_spi(Internal) import Generation

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

    /// The primary label used for deduplication.
    /// Entities with the same type and label are treated as the same entity.
    var label: String { get }

    /// Apply a deterministic ID derived from type + label.
    /// Inserting an entity with an existing stable ID overwrites the previous record (upsert).
    mutating func applyStableID()
}

extension MemoryStorable {
    /// Compute the stable ID string from label. Returns nil if label is empty.
    public func computeStableID() -> String? {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return "\(Self.storeKey)/\(trimmed.lowercased())"
    }
}

