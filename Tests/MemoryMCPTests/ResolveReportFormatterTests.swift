import Testing
@testable import MemoryMCP
import SwiftMemory

@Suite("Resolve Report Formatter Tests")
struct ResolveReportFormatterTests {
    @Test("Resolve limit policy preserves search limit and caps report display separately")
    func resolveLimitPolicyPreservesSearchLimitAndCapsReportDisplaySeparately() {
        #expect(ResolveLimitPolicy.searchLimit(for: 30) == 30)
        #expect(ResolveLimitPolicy.searchLimit(for: 5) == 5)
        #expect(ResolveLimitPolicy.searchLimit(for: -1) == 0)
        #expect(ResolveLimitPolicy.reportLimit == 3)
    }

    @Test("Context endpoints are rendered with labels and types")
    func contextEndpointsAreRenderedWithLabelsAndTypes() {
        let resolved = [
            ResolvedEntity(
                inputAssertion: ":Cerebras_Systems a :Organization .",
                candidates: [
                    ResolvedMatch(
                        id: "09D862C8-1637-4E73-8F8C-01B7ED5438A2",
                        assertion: ":Wacoal a :Organization .",
                        similarity: 0.9407227,
                        label: "Wacoal",
                        type: ":Organization",
                        context: [
                            ResolvedContextStatement(
                                direction: .outgoing,
                                subject: "09D862C8-1637-4E73-8F8C-01B7ED5438A2",
                                predicate: "locatedIn",
                                object: "296B9536-3FFA-4BF0-AE5B-E3C5937D5C42",
                                subjectLabel: "Wacoal",
                                subjectType: ":Organization",
                                objectLabel: "Japan",
                                objectType: ":Place"
                            )
                        ]
                    )
                ]
            )
        ]

        let report = ResolveReportFormatter.format(resolved, requestedLimit: 30)

        #expect(report.contains("# Memory Resolve Report"))
        #expect(report.contains("## Input 1: Cerebras Systems"))
        #expect(report.contains("- recommended action: create new unless external evidence proves identity"))
        #expect(report.contains("Wacoal (Organization, id: `09D862C8-1637-4E73-8F8C-01B7ED5438A2`) --locatedIn--> Japan (Place, id: `296B9536-3FFA-4BF0-AE5B-E3C5937D5C42`)"))
        #expect(!report.contains("`09D862C8-1637-4E73-8F8C-01B7ED5438A2` `locatedIn` `296B9536-3FFA-4BF0-AE5B-E3C5937D5C42`"))
    }

    @Test("Report caps displayed candidates")
    func reportCapsDisplayedCandidates() {
        let candidates = (1...5).map { index in
            ResolvedMatch(
                id: "candidate-\(index)",
                assertion: ":Candidate_\(index) a :Organization .",
                similarity: Float(1.0 - (Double(index) * 0.01)),
                label: "Candidate \(index)",
                type: ":Organization"
            )
        }
        let resolved = [
            ResolvedEntity(
                inputAssertion: ":Input_Organization a :Organization .",
                candidates: candidates
            )
        ]

        let report = ResolveReportFormatter.format(resolved, requestedLimit: 30)

        #expect(report.contains("- candidates shown: 3 of 5"))
        #expect(report.contains("- omitted candidates: 2 lower-ranked candidates"))
        #expect(report.contains("### Candidate 3: Candidate 3"))
        #expect(!report.contains("### Candidate 4: Candidate 4"))
    }
}
