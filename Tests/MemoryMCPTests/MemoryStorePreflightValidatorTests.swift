import Testing
import Foundation
@testable import MemoryMCP
import SwiftMemory
import MemoryOntology
import Database
@_spi(Internal) import SwiftGeneration

@Persistable @Generable @OWLClass("ex:Organization")
private struct PreflightOrganization: Entity {
    #Directory<PreflightOrganization>("test", "preflight", "organizations")

    var id: String = ULID().ulidString
    var name: String = ""
    var label: String = ""
    var assertion: String = ""
    var embedding: [Float] = []
}

extension PreflightOrganization: MemoryStorable {
    static let storeKey = "organizations"
    static var embeddingDimensions: Int { Given.embeddingDimensions }
}

@Suite("Memory Store Preflight Validator Tests")
struct MemoryStorePreflightValidatorTests {
    @Test("Duplicate exact assertions are rejected")
    func duplicateExactAssertionsAreRejected() throws {
        let assertion = ":Acme a ex:Organization ."
        var batch = MemoryBatch()
        batch.entity(organization(name: "Acme", assertion: assertion))
        batch.entity(organization(name: "Acme duplicate", assertion: assertion))

        let issues = preflightIssues(for: batch)

        #expect(issues.contains(.duplicateEntityAssertion(assertion)))
    }

    @Test("Ambiguous aliases are reported instead of silently dropped")
    func ambiguousAliasesAreReported() throws {
        let firstAssertion = ":Acme a ex:Organization ."
        let secondAssertion = ":Acme_Capital a ex:Organization ."
        let json = """
        {
          "organizations": [
            {
              "id": "org-acme",
              "name": "Acme",
              "label": "Acme",
              "assertion": "\(firstAssertion)",
              "embedding": []
            },
            {
              "id": "org-acme-capital",
              "name": "Acme",
              "label": "Acme",
              "assertion": "\(secondAssertion)",
              "embedding": []
            }
          ],
          "relationships": []
        }
        """

        let decoded = try MemoryKnowledgeDecoder.decodeWithDiagnostics(
            Data(json.utf8),
            entityTypes: [PreflightOrganization.self]
        )
        let expectedConflict = RelationshipAliasConflict(
            names: ["Acme"],
            targets: [firstAssertion, secondAssertion]
        )

        #expect(decoded.aliasConflicts == [expectedConflict])
        #expect(decoded.batch.aliases["Acme"] == nil)

        let issues = preflightIssues(for: decoded.batch, aliasConflicts: decoded.aliasConflicts)
        #expect(issues.contains(.ambiguousAlias(name: "Acme", targets: [firstAssertion, secondAssertion])))
    }

    @Test("Empty relationship endpoints are rejected")
    func emptyRelationshipEndpointsAreRejected() throws {
        var batch = MemoryBatch()
        batch.triple("", "ex:relatedTo", "Target")
        batch.triple("Source", "", "Target")
        batch.triple("Source", "ex:relatedTo", "")

        let issues = preflightIssues(for: batch)

        #expect(issues.contains(.emptyRelationshipEndpoint(index: 0, field: "subject")))
        #expect(issues.contains(.emptyRelationshipEndpoint(index: 1, field: "predicate")))
        #expect(issues.contains(.emptyRelationshipEndpoint(index: 2, field: "object")))
    }

    @Test("Schema predicates are rejected as relationships")
    func schemaPredicatesAreRejectedAsRelationships() throws {
        for predicate in ["rdf:type", "a", "rdfs:subClassOf", "owl:Class"] {
            var batch = MemoryBatch()
            batch.triple("Source", predicate, "Target")

            let issues = preflightIssues(for: batch)

            #expect(issues.contains(.schemaPredicateRelationship(index: 0, predicate: predicate)))
        }
    }

    @Test("Valid payload passes preflight")
    func validPayloadPassesPreflight() throws {
        let assertion = ":Acme a ex:Organization ."
        var batch = MemoryBatch()
        batch.entity(organization(name: "Acme", assertion: assertion))
        batch.alias("Acme", for: assertion)
        batch.triple("Acme", "ex:produces", "N2")

        try MemoryStorePreflightValidator.validate(batch: batch)
    }

    private func organization(name: String, assertion: String) -> PreflightOrganization {
        PreflightOrganization(
            name: name,
            label: name,
            assertion: assertion
        )
    }

    private func preflightIssues(
        for batch: MemoryBatch,
        aliasConflicts: [RelationshipAliasConflict] = []
    ) -> [MemoryStorePreflightIssue] {
        do {
            try MemoryStorePreflightValidator.validate(
                batch: batch,
                aliasConflicts: aliasConflicts
            )
            Issue.record("Expected preflight validation to fail")
            return []
        } catch let error as MemoryStorePreflightError {
            return error.issues
        } catch {
            Issue.record("Expected MemoryStorePreflightError, got \(error)")
            return []
        }
    }
}
