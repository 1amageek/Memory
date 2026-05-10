import Testing
import Foundation
@testable import MemoryMCP
import SwiftMemory
import MemoryOntology
import Database
@_spi(Internal) import SwiftGeneration

@Persistable @Generable @OWLClass("ex:Organization")
private struct DecoderOrganization: Entity {
    #Directory<DecoderOrganization>("test", "decoder", "organizations")

    var id: String = ULID().ulidString
    var name: String = ""
    var label: String = ""
    var assertion: String = ""
    var embedding: [Float] = []
}

extension DecoderOrganization: MemoryStorable {
    static let storeKey = "organizations"
    static var embeddingDimensions: Int { Given.embeddingDimensions }
}

@Suite("Memory Knowledge Decoder Tests")
struct MemoryKnowledgeDecoderTests {
    @Test("Entity labels become unambiguous relationship aliases")
    func entityLabelsBecomeRelationshipAliases() throws {
        let assertion = "TSMC is a semiconductor foundry"
        let json = """
        {
          "organizations": [
            {
              "id": "org-tsmc",
              "name": "TSMC",
              "label": "TSMC",
              "assertion": "\(assertion)",
              "embedding": []
            }
          ],
          "relationships": [
            {
              "subject": "TSMC",
              "predicate": "ex:produces",
              "object": "TSMC N2"
            }
          ]
        }
        """
        let batch = try MemoryKnowledgeDecoder.decode(
            Data(json.utf8),
            entityTypes: [DecoderOrganization.self]
        )

        #expect(batch.entities.count == 1)
        #expect(batch.statements.count == 1)
        #expect(batch.aliases["TSMC"] == assertion)
    }
}
