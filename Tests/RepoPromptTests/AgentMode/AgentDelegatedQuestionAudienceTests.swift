import Foundation
@testable import RepoPromptApp
import XCTest

/// Delegated `ask_user` audience policy (plan §6.1): who a session's question is addressed to.
final class AgentDelegatedQuestionAudienceTests: XCTestCase {
    private typealias Audience = AgentDelegatedQuestionAudience

    func testUncontrolledSessionAlwaysAddressesTheUserWhateverItsLineage() {
        let parent = UUID()
        let lookups: [AgentDelegationPolicy.ParentLookup] = [.root, .parent(parent), .unknown, .inconsistent]
        for lookup in lookups {
            XCTAssertEqual(
                resolve(controlled: false, lookup: lookup, lineage: .resolved(depth: 1), parentIsLive: true, verified: true),
                .user,
                "\(lookup)"
            )
        }
    }

    func testControlledChildWithResolvedLineageAndLiveParentAddressesTheParentAgent() {
        let parent = UUID()
        let audience = resolve(controlled: true, lookup: .parent(parent), lineage: .resolved(depth: 2), parentIsLive: true)
        XCTAssertEqual(audience, .parentAgent(parentSessionID: parent))
        XCTAssertTrue(audience.pausesTimeout)
        XCTAssertEqual(audience.parentSessionID, parent)
    }

    func testControlledChildFallsBackToTheUserWhenParentIsGoneOrLineageIsUnresolved() {
        let parent = UUID()
        XCTAssertEqual(resolve(controlled: true, lookup: .parent(parent), lineage: .resolved(depth: 1), parentIsLive: false), .userFallback)
        for lineage: AgentDelegationPolicy.LineageResolution in [.unresolved, .cyclic, .inconsistent] {
            XCTAssertEqual(
                resolve(controlled: true, lookup: .parent(parent), lineage: lineage, parentIsLive: true),
                .userFallback,
                "\(lineage)"
            )
        }
        XCTAssertEqual(resolve(controlled: true, lookup: .unknown, lineage: .unresolved, parentIsLive: false), .userFallback)
        XCTAssertEqual(resolve(controlled: true, lookup: .inconsistent, lineage: .inconsistent, parentIsLive: false), .userFallback)
        XCTAssertFalse(Audience.userFallback.pausesTimeout)
        XCTAssertNil(Audience.userFallback.parentSessionID)
    }

    func testControlledRootIsExternalOnlyWhenTheControllerIsVerifiedNonAgentMode() {
        XCTAssertEqual(
            resolve(controlled: true, lookup: .root, lineage: .resolved(depth: 0), parentIsLive: false, verified: true),
            .externalController
        )
        XCTAssertEqual(
            resolve(controlled: true, lookup: .root, lineage: .resolved(depth: 0), parentIsLive: false, verified: false),
            .userFallback,
            "An MCP-controlled reconciled root alone is not verifiably external"
        )
        XCTAssertFalse(Audience.externalController.pausesTimeout)
    }

    func testControllerProvenanceVerifiesOnlyTheExactCurrentConnection() {
        let connection = UUID()
        let provenance = AgentDelegatedQuestionControllerProvenance(verifiedNonAgentModeConnectionID: connection)
        XCTAssertTrue(provenance.verifies(currentControllerConnectionID: connection))
        XCTAssertFalse(provenance.verifies(currentControllerConnectionID: UUID()))
        XCTAssertFalse(provenance.verifies(currentControllerConnectionID: nil))
        XCTAssertFalse(AgentDelegatedQuestionControllerProvenance.unverified.verifies(currentControllerConnectionID: connection))
        XCTAssertFalse(AgentDelegatedQuestionControllerProvenance.unverified.verifies(currentControllerConnectionID: nil))
    }

    private func resolve(
        controlled: Bool,
        lookup: AgentDelegationPolicy.ParentLookup,
        lineage: AgentDelegationPolicy.LineageResolution,
        parentIsLive: Bool,
        verified: Bool = false
    ) -> Audience {
        Audience.resolve(.init(
            isMCPControlled: controlled,
            parentLookup: lookup,
            lineage: lineage,
            parentIsLive: parentIsLive,
            controllerVerifiedNonAgentMode: verified
        ))
    }
}
