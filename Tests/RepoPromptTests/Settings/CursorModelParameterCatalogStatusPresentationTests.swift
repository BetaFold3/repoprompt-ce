import Foundation
@testable import RepoPromptApp
import XCTest

final class CursorModelParameterCatalogStatusPresentationTests: XCTestCase {
    private let savedAt = Date(timeIntervalSince1970: 1_775_860_200)
    private let formattedDate = "Apr 12, 2026 at 9:30 AM"

    func testLiveStatesDistinguishUsableAndEmptyCatalogs() {
        XCTAssertEqual(
            message(state: .live, hasUsableCatalog: true),
            "Cursor model parameters are up to date."
        )
        XCTAssertEqual(
            message(state: .live, hasUsableCatalog: false),
            "Cursor currently exposes no parameterized models."
        )
    }

    func testCachedStateReportsSavedCopyAndPendingRefresh() {
        XCTAssertEqual(
            message(state: .cached, hasUsableCatalog: true),
            "Using saved Cursor model parameters from \(formattedDate); background refresh is pending."
        )
    }

    func testEveryStaleFailureKindUsesSanitizedReason() {
        let cases: [(CursorModelParameterCatalog.FailureKind, String)] = [
            (.authentication, "Cursor authentication needs attention"),
            (.timeout, "the refresh timed out"),
            (.malformedResponse, "Cursor returned malformed model parameter data"),
            (.discovery, "model discovery failed"),
            (.extension, "the parameter request failed")
        ]

        for (kind, reason) in cases {
            XCTAssertEqual(
                message(state: .stale(kind), hasUsableCatalog: true),
                "Using saved Cursor model parameters from \(formattedDate) — last refresh failed: \(reason)."
            )
            XCTAssertEqual(
                message(state: .stale(kind), hasUsableCatalog: false),
                "Cursor model parameters are unavailable — last refresh failed: \(reason)."
            )
        }
    }

    func testUnsupportedDisabledRefreshingAndIdleStatesAreBoundedAndHonest() {
        XCTAssertEqual(
            message(state: .unsupported, hasUsableCatalog: false),
            "This Cursor version doesn't expose model parameters."
        )
        XCTAssertEqual(
            message(state: .disabled, hasUsableCatalog: false),
            "Cursor model parameter discovery is disabled."
        )
        XCTAssertEqual(
            message(state: .disabled, hasUsableCatalog: true),
            "Cursor model parameter refresh is disabled; using the saved copy from \(formattedDate)."
        )
        XCTAssertEqual(
            message(state: .refreshing, hasUsableCatalog: false),
            "Refreshing Cursor model parameters…"
        )
        XCTAssertEqual(
            message(state: .refreshing, hasUsableCatalog: true),
            "Refreshing Cursor model parameters; using the saved copy from \(formattedDate)."
        )
        XCTAssertEqual(
            message(state: .idle, hasUsableCatalog: false),
            "Cursor model parameter discovery has not started."
        )
        XCTAssertEqual(
            message(state: .idle, hasUsableCatalog: true),
            "Using saved Cursor model parameters from \(formattedDate); background refresh has not started."
        )
    }

    func testSettingsBindingUsesOnlyStatusNotification() {
        XCTAssertEqual(
            CLIProvidersSettingsView.cursorParameterCatalogStatusNotification,
            .cursorModelParameterCatalogStatusDidChange
        )
        XCTAssertNotEqual(
            CLIProvidersSettingsView.cursorParameterCatalogStatusNotification,
            .cursorModelParameterCatalogDidChange
        )
    }

    private func message(
        state: CursorModelParameterCatalog.State,
        hasUsableCatalog: Bool
    ) -> String {
        let status = CursorModelParameterCatalog.Status(
            state: state,
            hasUsableCatalog: hasUsableCatalog,
            lastSuccessfulRefresh: hasUsableCatalog ? savedAt : nil,
            lastAttempt: nil
        )
        return CursorModelParameterCatalogStatusPresentation.message(
            for: status,
            formatDate: { _ in self.formattedDate }
        )
    }
}
