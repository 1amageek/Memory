// MemoryStorePreflightValidator.swift
// Deterministic validation at the MCP store boundary.

import Foundation
import SwiftMemory

enum MemoryStorePreflightIssue: Equatable, Sendable, CustomStringConvertible {
    case duplicateEntityAssertion(String)
    case ambiguousAlias(name: String, targets: [String])
    case emptyRelationshipEndpoint(index: Int, field: String)
    case schemaPredicateRelationship(index: Int, predicate: String)

    var description: String {
        switch self {
        case .duplicateEntityAssertion(let assertion):
            return "Duplicate entity assertion in store payload: `\(assertion)`"
        case .ambiguousAlias(let name, let targets):
            let targetList = targets.map { "`\($0)`" }.joined(separator: ", ")
            return "Ambiguous relationship alias `\(name)` points to multiple entities: \(targetList)"
        case .emptyRelationshipEndpoint(let index, let field):
            return "Relationship \(index + 1) has an empty \(field)"
        case .schemaPredicateRelationship(let index, let predicate):
            return "Relationship \(index + 1) uses schema/class predicate `\(predicate)`; class membership belongs in entity assertions"
        }
    }
}

struct MemoryStorePreflightError: LocalizedError, Equatable {
    var issues: [MemoryStorePreflightIssue]

    var errorDescription: String? {
        let details = issues.map { "- \($0.description)" }.joined(separator: "\n")
        return "Memory store preflight failed:\n\(details)"
    }
}

enum MemoryStorePreflightValidator {
    private static let schemaClassPredicates: Set<String> = [
        "rdf:type",
        "a",
        "rdfs:subClassOf",
        "owl:Class",
    ]

    static func validate(_ decoded: DecodedMemoryKnowledge) throws {
        try validate(
            batch: decoded.batch,
            aliasConflicts: decoded.aliasConflicts
        )
    }

    static func validate(
        batch: MemoryBatch,
        aliasConflicts: [RelationshipAliasConflict] = []
    ) throws {
        var issues: [MemoryStorePreflightIssue] = []
        issues.append(contentsOf: duplicateAssertionIssues(in: batch))
        issues.append(contentsOf: aliasConflictIssues(aliasConflicts))
        issues.append(contentsOf: relationshipIssues(in: batch))

        guard issues.isEmpty else {
            throw MemoryStorePreflightError(issues: issues)
        }
    }

    private static func duplicateAssertionIssues(in batch: MemoryBatch) -> [MemoryStorePreflightIssue] {
        var counts: [String: Int] = [:]
        for entity in batch.entities {
            let assertion = entity.assertion.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !assertion.isEmpty else { continue }
            counts[assertion, default: 0] += 1
        }

        return counts
            .filter { $0.value > 1 }
            .map { .duplicateEntityAssertion($0.key) }
            .sorted { $0.description.localizedStandardCompare($1.description) == .orderedAscending }
    }

    private static func aliasConflictIssues(
        _ conflicts: [RelationshipAliasConflict]
    ) -> [MemoryStorePreflightIssue] {
        conflicts.map {
            .ambiguousAlias(name: $0.displayName, targets: $0.targets)
        }
    }

    private static func relationshipIssues(in batch: MemoryBatch) -> [MemoryStorePreflightIssue] {
        var issues: [MemoryStorePreflightIssue] = []

        for (index, statement) in batch.statements.enumerated() {
            let subject = statement.subject.trimmingCharacters(in: .whitespacesAndNewlines)
            let predicate = statement.predicate.trimmingCharacters(in: .whitespacesAndNewlines)
            let object = statement.object.trimmingCharacters(in: .whitespacesAndNewlines)

            if subject.isEmpty {
                issues.append(.emptyRelationshipEndpoint(index: index, field: "subject"))
            }
            if predicate.isEmpty {
                issues.append(.emptyRelationshipEndpoint(index: index, field: "predicate"))
            }
            if object.isEmpty {
                issues.append(.emptyRelationshipEndpoint(index: index, field: "object"))
            }
            if schemaClassPredicates.contains(predicate) {
                issues.append(.schemaPredicateRelationship(index: index, predicate: predicate))
            }
        }

        return issues
    }
}
