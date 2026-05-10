// RelationshipAliasCollector.swift
// Normalized alias collection for relationship endpoint resolution.

import Foundation

struct RelationshipAliasCollector {
    private struct Entry {
        var names: Set<String> = []
        var targets: Set<String> = []
    }

    private var entries: [String: Entry] = [:]

    mutating func add(alias: String, target: String) {
        let trimmedAlias = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedTarget = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedAlias.isEmpty, !trimmedTarget.isEmpty else { return }

        let key = normalized(trimmedAlias)
        var entry = entries[key] ?? Entry()
        entry.names.insert(trimmedAlias)
        entry.targets.insert(trimmedTarget)
        entries[key] = entry
    }

    var unambiguousAliases: [(name: String, target: String)] {
        entries.values.flatMap { entry -> [(name: String, target: String)] in
            guard entry.targets.count == 1, let target = entry.targets.first else {
                return []
            }
            return entry.names.map { (name: $0, target: target) }
        }
    }

    private func normalized(_ value: String) -> String {
        value.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: .current
        )
    }
}
