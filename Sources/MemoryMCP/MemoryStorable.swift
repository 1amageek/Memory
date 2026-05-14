// MemoryStorable.swift
// Protocol for entity types that can be stored via MCP store tool

import Foundation
import MCP
import Database
import SwiftMemory
@_spi(Internal) import SwiftGeneration

// MARK: - MemoryStorable Protocol

/// Entity type that can be stored via MCP `store` tool.
///
/// Combines three requirements:
/// - `Persistable` — for FDB persistence
/// - `Entity` — for polymorphic storage + embedding-based candidate retrieval
///   (contributes `assertion` and `embedding`; identity judgment happens before
///   store, not inside `SwiftMemory.Memory.store()`)
/// - `Generable` — for JSON decode + MCP schema generation
///
/// The only additional responsibility of this protocol is mapping the type to
/// its JSON key inside the `knowledge` object received by the `store` tool.
///
/// ```swift
/// @Persistable @Generable @OWLClass("ex:Person")
/// struct Person: Entity {
///     #Directory<Person>("bob", "persons")
///     var id: String = ULID().ulidString
///     var name: String
///     var embedding: [Float] = []
///     var label: String { name }
/// }
///
/// extension Person: MemoryStorable {
///     public static let storeKey = "persons"
/// }
/// ```
public protocol MemoryStorable: Persistable, Entity, Generable {
    /// JSON key in the knowledge object (e.g. "persons", "organizations").
    ///
    /// Used by the MCP `store` tool to locate this entity type's array inside
    /// the incoming knowledge payload.
    static var storeKey: String { get }

    /// Human-facing name used by agents when they write relationships.
    var label: String { get }

    /// Additional names that should resolve to this entity in relationship
    /// endpoints during a single store operation.
    var referenceAliases: [String] { get }
}

public extension MemoryStorable {
    var referenceAliases: [String] {
        [label, assertion].filter { !$0.isEmpty }
    }
}
