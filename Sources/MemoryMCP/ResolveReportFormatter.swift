// ResolveReportFormatter.swift
// Human-readable report for pre-store entity resolution.

import Foundation
import SwiftMemory

enum ResolveLimitPolicy {
    static func searchLimit(for requestedLimit: Int) -> Int {
        max(requestedLimit, 0)
    }

    static var reportLimit: Int {
        ResolveReportFormatter.maxCandidatesPerInput
    }
}

enum ResolveReportFormatter {
    static let maxCandidatesPerInput = 3
    private static let maxContextStatementsPerCandidate = 5

    static func format(_ resolved: [ResolvedEntity], requestedLimit: Int) -> String {
        let inputsWithCandidates = resolved.filter { !$0.candidates.isEmpty }.count
        let reviewNeeded = resolved.filter { hasLabelMatch($0) }.count
        let likelyNew = resolved.count - reviewNeeded

        var output = """
        # Memory Resolve Report

        ## Summary
        - inputs: \(resolved.count)
        - inputs with candidates: \(inputsWithCandidates)
        - review needed: \(reviewNeeded)
        - likely new: \(likelyNew)
        - candidates shown: up to \(maxCandidatesPerInput) per input
        - requested candidate limit: \(requestedLimit)

        """

        for (index, entity) in resolved.enumerated() {
            output += formatInput(entity, index: index)
        }

        return output
    }

    private static func formatInput(_ entity: ResolvedEntity, index: Int) -> String {
        let inputName = inputLabel(from: entity.inputAssertion)
        let shownCandidates = Array(entity.candidates.prefix(maxCandidatesPerInput))
        let omitted = max(0, entity.candidates.count - shownCandidates.count)
        let action = recommendedAction(for: entity)

        var output = """
        ## Input \(index + 1): \(inputName)
        - proposed assertion: `\(entity.inputAssertion)`
        - recommended action: \(action.label)
        - reason: \(action.reason)

        """

        if entity.candidates.isEmpty {
            output += "- candidates: none\n\n"
            return output
        }

        output += "- candidates shown: \(shownCandidates.count) of \(entity.candidates.count)\n"
        if omitted > 0 {
            output += "- omitted candidates: \(omitted) lower-ranked candidates\n"
        }
        output += "\n"

        for (candidateIndex, candidate) in shownCandidates.enumerated() {
            output += formatCandidate(candidate, inputName: inputName, index: candidateIndex)
        }

        return output + "\n"
    }

    private static func formatCandidate(_ candidate: ResolvedMatch, inputName: String, index: Int) -> String {
        let candidateName = candidate.label.isEmpty ? candidate.id : candidate.label
        let signal = decisionSignal(inputName: inputName, candidateLabel: candidate.label)
        let context = meaningfulContext(for: candidate)

        var output = """
        ### Candidate \(index + 1): \(candidateName)
        - id: `\(candidate.id)`
        - type: \(displayType(candidate.type))
        - assertion: `\(candidate.assertion)`
        - similarity: \(String(format: "%.3f", candidate.similarity))
        - decision signal: \(signal.label)
        - why: \(signal.reason)

        """

        if context.isEmpty {
            output += "- context: none\n\n"
            return output
        }

        output += "- context:\n"
        for statement in context.prefix(maxContextStatementsPerCandidate) {
            output += "  - \(formatStatement(statement))\n"
        }
        let omitted = context.count - min(context.count, maxContextStatementsPerCandidate)
        if omitted > 0 {
            output += "  - ... \(omitted) more context statements omitted\n"
        }
        output += "\n"
        return output
    }

    private static func recommendedAction(for entity: ResolvedEntity) -> (label: String, reason: String) {
        guard !entity.candidates.isEmpty else {
            return ("create new", "No existing entity cleared the resolve threshold.")
        }
        if hasLabelMatch(entity) {
            return ("review matching candidate", "At least one candidate has a matching label; reuse its id only if the context also matches.")
        }
        return ("create new unless external evidence proves identity", "Candidates appear similar by class or weak context only; no candidate label matches the input.")
    }

    private static func decisionSignal(
        inputName: String,
        candidateLabel: String
    ) -> (label: String, reason: String) {
        guard !candidateLabel.isEmpty else {
            return ("weak", "The candidate has no resolved label, so identity cannot be inferred from the graph.")
        }
        if normalized(inputName) == normalized(candidateLabel) {
            return ("possible same entity", "The candidate label matches the input label.")
        }
        return ("likely different", "The candidate label differs from the input label.")
    }

    private static func hasLabelMatch(_ entity: ResolvedEntity) -> Bool {
        let inputName = inputLabel(from: entity.inputAssertion)
        return entity.candidates.contains {
            !$0.label.isEmpty && normalized($0.label) == normalized(inputName)
        }
    }

    private static func meaningfulContext(for candidate: ResolvedMatch) -> [ResolvedContextStatement] {
        let nonMetadata = candidate.context.filter { !isMetadataPredicate($0.predicate) }
        return nonMetadata.isEmpty ? candidate.context : nonMetadata
    }

    private static func formatStatement(_ statement: ResolvedContextStatement) -> String {
        let subject = formatEndpoint(
            id: statement.subject,
            label: statement.subjectLabel,
            type: statement.subjectType
        )
        let object = formatEndpoint(
            id: statement.object,
            label: statement.objectLabel,
            type: statement.objectType
        )
        let predicate = localName(statement.predicate)
        return "\(subject) --\(predicate)--> \(object)"
    }

    private static func formatEndpoint(id: String, label: String, type: String) -> String {
        if type == "Literal" {
            return "\"\(label.isEmpty ? id : label)\""
        }

        let displayLabel = label.isEmpty ? localName(id) : label
        let displayType = localName(type)
        if isOpaqueID(id), !displayType.isEmpty {
            return "\(displayLabel) (\(displayType), id: `\(id)`)"
        }
        if isOpaqueID(id) {
            return "\(displayLabel) (id: `\(id)`)"
        }
        if !displayType.isEmpty, displayLabel != id {
            return "\(displayLabel) (\(displayType))"
        }
        return displayLabel
    }

    private static func displayType(_ type: String) -> String {
        let local = localName(type)
        return local.isEmpty ? "unknown" : local
    }

    private static func inputLabel(from assertion: String) -> String {
        let subject = assertion
            .replacingOccurrences(of: ".", with: " ")
            .split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" })
            .first
            .map(String.init) ?? assertion
        let local = localName(subject)
        return local.replacingOccurrences(of: "_", with: " ")
    }

    private static func localName(_ value: String) -> String {
        guard !value.isEmpty else { return "" }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let hash = trimmed.lastIndex(of: "#") {
            return String(trimmed[trimmed.index(after: hash)...])
        }
        if let slash = trimmed.lastIndex(of: "/") {
            return String(trimmed[trimmed.index(after: slash)...])
        }
        if let colon = trimmed.lastIndex(of: ":") {
            return String(trimmed[trimmed.index(after: colon)...])
        }
        return trimmed
    }

    private static func normalized(_ value: String) -> String {
        value
            .replacingOccurrences(of: "_", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
    }

    private static func isMetadataPredicate(_ predicate: String) -> Bool {
        let local = localName(predicate).lowercased()
        return local == "type" || local == "label"
    }

    private static func isOpaqueID(_ value: String) -> Bool {
        UUID(uuidString: value) != nil
    }
}
