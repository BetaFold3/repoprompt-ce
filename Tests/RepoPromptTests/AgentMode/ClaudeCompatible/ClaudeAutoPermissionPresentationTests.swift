import Foundation
@testable import RepoPromptApp
import XCTest

@MainActor
final class ClaudeAutoPermissionPresentationTests: XCTestCase {
    func testSettingsBindingIsConfigurationOnlyAndPreservesUnknownRawPermission() throws {
        try withDefaults { defaults in
            ClaudeAgentToolPreferences.setPermissionMode(
                "futurePermissionMode",
                defaults: defaults
            )
            let store = AgentProviderPreferenceSnapshotStore(defaults: defaults)

            let binding = store.topLevelSettingsControlsBinding(providerID: .claude)

            XCTAssertEqual(binding.configuredMode?.rawValue, "futurePermissionMode")
            XCTAssertEqual(binding.configuredMode?.displayName, "futurePermissionMode")
            XCTAssertEqual(binding.displayName, "futurePermissionMode")
            XCTAssertNil(binding.sessionStatus)
            XCTAssertFalse(binding.permissionOptionsContainSelection)

            let summary = AgentPermissionCapabilitySummaryBuilder(defaults: defaults).summary(
                for: .claude,
                profile: .userConfigured,
                availability: .none
            )
            XCTAssertTrue(summary.fileMutation.contains("Configured permission mode: futurePermissionMode"))
            XCTAssertTrue(summary.fileMutation.contains("no live session state"))
            XCTAssertTrue(summary.approvalModeDescription.contains("no live session acknowledgement"))
            XCTAssertFalse(summary.externalMCP.contains("RepoPrompt only"))
        }
    }

    func testLiveBindingSeparatesConfiguredRequestedResolvedAndAcknowledgedModes() throws {
        try withDefaults { defaults in
            ClaudeAgentToolPreferences.setPermissionLevel(.fullAccess, defaults: defaults)
            let store = AgentProviderPreferenceSnapshotStore(defaults: defaults)
            let acknowledgement = makeAcknowledgement(
                requestedMode: "auto",
                launchMode: "auto"
            )

            let binding = store.controlsBinding(
                selectedAgent: .claudeCode,
                selectedModelRaw: "opus",
                permissionProfile: .providerOverride(.claude(.auto)),
                isSubagent: true,
                externallyManagedReason: "Managed by the session profile.",
                claudePermissionSessionState: .acknowledged(acknowledgement)
            )

            XCTAssertEqual(binding.configuredMode?.rawValue, "bypassPermissions")
            XCTAssertEqual(binding.configuredMode?.displayName, "Full Access")
            XCTAssertEqual(binding.sessionStatus?.requestedMode.rawValue, "auto")
            XCTAssertEqual(binding.sessionStatus?.resolvedLaunchMode?.rawValue, "auto")
            XCTAssertEqual(binding.sessionStatus?.acknowledgedMode?.rawValue, "auto")
            XCTAssertEqual(binding.sessionStatus?.phase, .acknowledged)
            XCTAssertEqual(
                binding.options.first(where: { $0.id == .claude(.fullAccess) })?.isSelected,
                true
            )
            XCTAssertEqual(
                binding.options.first(where: { $0.id == .claude(.auto) })?.isSelected,
                false
            )
            XCTAssertTrue(binding.sessionStatus?.detail.contains("does not confirm") == true)
        }
    }

    func testEligibleAutoNotStartedInitializingAndBlockedPresentation() throws {
        try withDefaults { defaults in
            ClaudeAgentToolPreferences.setPermissionLevel(.auto, defaults: defaults)
            let store = AgentProviderPreferenceSnapshotStore(defaults: defaults)
            let ownership = makeOwnership()
            let settings = makeLaunchSettings(permissionMode: "auto")

            let selected = store.controlsBinding(
                selectedAgent: .claudeCode,
                selectedModelRaw: "opus",
                permissionProfile: .userConfigured,
                isSubagent: false,
                externallyManagedReason: nil,
                claudePermissionSessionState: .notStarted
            )
            XCTAssertEqual(selected.sessionStatus?.phase, .selectedNotStarted)
            XCTAssertEqual(selected.sessionStatus?.resolvedLaunchMode?.rawValue, "auto")
            XCTAssertTrue(selected.sessionStatus?.detail.contains("has not acknowledged") == true)

            let initializing = store.controlsBinding(
                selectedAgent: .claudeCode,
                selectedModelRaw: "opus",
                permissionProfile: .userConfigured,
                isSubagent: false,
                externallyManagedReason: nil,
                claudePermissionSessionState: .initializing(
                    ownership: ownership,
                    launchSettings: settings,
                    requestedMode: "auto"
                )
            )
            XCTAssertEqual(initializing.sessionStatus?.phase, .initializing)
            XCTAssertEqual(initializing.sessionStatus?.resolvedLaunchMode?.rawValue, "auto")
            XCTAssertNil(initializing.sessionStatus?.acknowledgedMode)

            let blocked = store.controlsBinding(
                selectedAgent: .claudeCode,
                selectedModelRaw: "haiku",
                permissionProfile: .userConfigured,
                isSubagent: false,
                externallyManagedReason: nil,
                claudePermissionSessionState: .blocked(
                    requestedMode: "auto",
                    reason: .unsupportedModel("haiku"),
                    runID: UUID(),
                    runAttemptID: UUID()
                )
            )
            XCTAssertEqual(blocked.sessionStatus?.phase, .blocked)
            XCTAssertNil(blocked.sessionStatus?.resolvedLaunchMode)
            XCTAssertTrue(blocked.sessionStatus?.detail.contains("haiku") == true)
            XCTAssertEqual(blocked.sessionStatus?.isWarning, true)

            let staleBlock = ClaudePermissionSessionState.blocked(
                requestedMode: "auto",
                reason: .unsupportedModel("haiku"),
                runID: UUID(),
                runAttemptID: UUID()
            )
            let correctedModel = store.controlsBinding(
                selectedAgent: .claudeCode,
                selectedModelRaw: "opus",
                permissionProfile: .userConfigured,
                isSubagent: false,
                externallyManagedReason: nil,
                claudePermissionSessionState: staleBlock
            )
            XCTAssertEqual(correctedModel.sessionStatus?.phase, .selectedNotStarted)
            XCTAssertEqual(correctedModel.sessionStatus?.resolvedLaunchMode?.rawValue, "auto")
            XCTAssertFalse(correctedModel.sessionStatus?.detail.contains("haiku") == true)

            let explicitNonAuto = store.controlsBinding(
                selectedAgent: .claudeCode,
                selectedModelRaw: "haiku",
                permissionProfile: .providerOverride(.claude(.fullAccess)),
                isSubagent: false,
                externallyManagedReason: nil,
                claudePermissionSessionState: staleBlock
            )
            XCTAssertEqual(explicitNonAuto.sessionStatus?.phase, .selectedNotStarted)
            XCTAssertEqual(explicitNonAuto.sessionStatus?.requestedMode.rawValue, "bypassPermissions")
            XCTAssertEqual(explicitNonAuto.sessionStatus?.resolvedLaunchMode?.rawValue, "bypassPermissions")

            let differentBlock = store.controlsBinding(
                selectedAgent: .claudeCode,
                selectedModelRaw: "claude-sonnet-4-5",
                permissionProfile: .userConfigured,
                isSubagent: false,
                externallyManagedReason: nil,
                claudePermissionSessionState: staleBlock
            )
            XCTAssertEqual(differentBlock.sessionStatus?.phase, .blocked)
            XCTAssertTrue(differentBlock.sessionStatus?.detail.contains("claude-sonnet-4-5") == true)
            XCTAssertFalse(differentBlock.sessionStatus?.detail.contains("'haiku'") == true)
        }
    }

    func testFailedPresentationSanitizesReasonAndRemainsActionable() throws {
        try withDefaults { defaults in
            ClaudeAgentToolPreferences.setPermissionLevel(.auto, defaults: defaults)
            let store = AgentProviderPreferenceSnapshotStore(defaults: defaults)
            let fixtures: [(message: String, secrets: [String], redactions: [String])] = [
                (
                    "\(NSHomeDirectory())/private/config\n token=presentation-secret-value",
                    ["presentation-secret-value"],
                    ["token=[redacted]"]
                ),
                (
                    "Authorization: Bearer bearer-example-secret-value",
                    ["bearer-example-secret-value"],
                    ["Authorization=[redacted]"]
                ),
                (
                    "ANTHROPIC_API_KEY=anthropic-prefixed-secret-value",
                    ["anthropic-prefixed-secret-value"],
                    ["ANTHROPIC_API_KEY=[redacted]"]
                ),
                (
                    "access_token=access-token-secret-value",
                    ["access-token-secret-value"],
                    ["access_token=[redacted]"]
                ),
                (
                    "client_secret=client-secret-value",
                    ["client-secret-value"],
                    ["client_secret=[redacted]"]
                ),
                (
                    "clientSecret=camel-case-client-secret-value",
                    ["camel-case-client-secret-value"],
                    ["clientSecret=[redacted]"]
                ),
                (
                    "accessToken=camel-case-access-token-value",
                    ["camel-case-access-token-value"],
                    ["accessToken=[redacted]"]
                ),
                (
                    "anthropicApiKey=camel-case-anthropic-api-key-value",
                    ["camel-case-anthropic-api-key-value"],
                    ["anthropicApiKey=[redacted]"]
                ),
                (
                    #"{"apiKey":"quoted-json-api-key-value"}"#,
                    ["quoted-json-api-key-value"],
                    ["apiKey=[redacted]"]
                ),
                (
                    "X-Api-Key: hyphenated-api-key-value",
                    ["hyphenated-api-key-value"],
                    ["X-Api-Key=[redacted]"]
                ),
                (
                    "proxyAuthorization: Basic cHJveHktdXNlcjpwcm94eS1zZWNyZXQ=",
                    ["cHJveHktdXNlcjpwcm94eS1zZWNyZXQ="],
                    ["proxyAuthorization=[redacted]"]
                ),
                (
                    #"{'accessToken':'single-quoted-access-token-value'}"#,
                    ["single-quoted-access-token-value"],
                    ["accessToken=[redacted]"]
                ),
                (
                    "database_password=database-password-secret-value",
                    ["database-password-secret-value"],
                    ["database_password=[redacted]"]
                ),
                (
                    "password=correct,horse",
                    ["correct", "horse"],
                    ["password=[redacted]"]
                ),
                (
                    #"{"clientSecret":"escaped-prefix\"escaped-secret-suffix"}"#,
                    ["escaped-prefix", "escaped-secret-suffix"],
                    ["clientSecret=[redacted]"]
                ),
                (
                    #"{"api_key":"json-api-key-value","token":"json-token-value","secret":"json-secret-value","password":"json-password-value"}"#,
                    ["json-api-key-value", "json-token-value", "json-secret-value", "json-password-value"],
                    [
                        "api_key=[redacted]",
                        "token=[redacted]",
                        "secret=[redacted]",
                        "password=[redacted]"
                    ]
                ),
                (
                    #"{"ANTHROPIC_API_KEY":"anthropic-json-secret-value","access_token":"access-json-secret-value","client_secret":"client-json-secret-value","database_password":"database-json-secret-value"}"#,
                    [
                        "anthropic-json-secret-value",
                        "access-json-secret-value",
                        "client-json-secret-value",
                        "database-json-secret-value"
                    ],
                    [
                        "ANTHROPIC_API_KEY=[redacted]",
                        "access_token=[redacted]",
                        "client_secret=[redacted]",
                        "database_password=[redacted]"
                    ]
                )
            ]

            for fixture in fixtures {
                let binding = store.controlsBinding(
                    selectedAgent: .claudeCode,
                    selectedModelRaw: "opus",
                    permissionProfile: .userConfigured,
                    isSubagent: false,
                    externallyManagedReason: nil,
                    claudePermissionSessionState: .failed(
                        ownership: makeOwnership(),
                        requestedMode: "auto",
                        message: fixture.message
                    )
                )

                let status = try XCTUnwrap(binding.sessionStatus)
                XCTAssertEqual(status.phase, .failed)
                XCTAssertFalse(status.detail.contains(NSHomeDirectory()))
                for secret in fixture.secrets {
                    XCTAssertFalse(status.detail.contains(secret))
                }
                for redaction in fixture.redactions {
                    XCTAssertTrue(status.detail.contains(redaction))
                }
                XCTAssertTrue(status.detail.contains("retry"))
            }
        }
    }

    func testFailedPresentationSanitizesCompactJSONAndCredentialChains() throws {
        try withDefaults { defaults in
            ClaudeAgentToolPreferences.setPermissionLevel(.auto, defaults: defaults)
            let store = AgentProviderPreferenceSnapshotStore(defaults: defaults)
            let fixtures: [(
                name: String,
                message: String,
                secretParts: [String],
                expectedFragments: [String]
            )] = [
                (
                    "A",
                    #"{"token":null,"Authorization":"Bearer example-secret-value"}"#,
                    ["Bearer", "example-secret-value"],
                    ["token=[redacted]", "Authorization=[redacted]"]
                ),
                (
                    "B",
                    #"{"api_key":null,"password":"correct horse"}"#,
                    ["correct", "horse"],
                    ["api_key=[redacted]", "password=[redacted]"]
                ),
                (
                    "C",
                    #"{"password":"correct horse","model":"opus"}"#,
                    ["correct", "horse"],
                    ["password=[redacted]", #""model":"opus""#]
                ),
                (
                    "D",
                    "token=first-free-text-secret,Authorization: Bearer later-scheme-secret",
                    ["Bearer", "first-free-text-secret", "later-scheme-secret"],
                    ["token=[redacted]", "Authorization=[redacted]"]
                ),
                (
                    "E",
                    "Authorization: Bearer first-chain-secret,Proxy-Authorization: Basic second-chain-secret",
                    ["Bearer", "Basic", "first-chain-secret", "second-chain-secret"],
                    ["Authorization=[redacted]", "Proxy-Authorization=[redacted]"]
                ),
                (
                    "F",
                    #"{"clientSecret":"truncated-prefix dangling-suffix"#,
                    ["truncated-prefix", "dangling-suffix"],
                    ["clientSecret=[redacted]"]
                ),
                (
                    "G",
                    #"Authorization: Bearer "quoted scheme-secret-value""#,
                    ["Bearer", "quoted", "scheme-secret-value"],
                    ["Authorization=[redacted]"]
                ),
                (
                    "H",
                    #"{ "token": null, "Authorization": "Bearer spaced-json-secret" }"#,
                    ["Bearer", "spaced-json-secret"],
                    ["token=[redacted]", "Authorization=[redacted]"]
                )
            ]

            for fixture in fixtures {
                let binding = store.controlsBinding(
                    selectedAgent: .claudeCode,
                    selectedModelRaw: "opus",
                    permissionProfile: .userConfigured,
                    isSubagent: false,
                    externallyManagedReason: nil,
                    claudePermissionSessionState: .failed(
                        ownership: makeOwnership(),
                        requestedMode: "auto",
                        message: fixture.message
                    )
                )

                let status = try XCTUnwrap(binding.sessionStatus)
                XCTAssertEqual(status.phase, .failed)
                for secretPart in fixture.secretParts {
                    XCTAssertFalse(
                        status.detail.contains(secretPart),
                        "Fixture \(fixture.name) leaked \(secretPart): \(status.detail)"
                    )
                }
                for expectedFragment in fixture.expectedFragments {
                    XCTAssertTrue(
                        status.detail.contains(expectedFragment),
                        "Fixture \(fixture.name) omitted \(expectedFragment): \(status.detail)"
                    )
                }
            }
        }
    }

    func testFailedPresentationRedactsLiteralMarkerCollisionsAndDanglingEscapes() throws {
        try withDefaults { defaults in
            ClaudeAgentToolPreferences.setPermissionLevel(.auto, defaults: defaults)
            let store = AgentProviderPreferenceSnapshotStore(defaults: defaults)

            for fixture in Self.markerCollisionAndDanglingEscapeFixtures {
                let binding = store.controlsBinding(
                    selectedAgent: .claudeCode,
                    selectedModelRaw: "opus",
                    permissionProfile: .userConfigured,
                    isSubagent: false,
                    externallyManagedReason: nil,
                    claudePermissionSessionState: .failed(
                        ownership: makeOwnership(),
                        requestedMode: "auto",
                        message: fixture.message
                    )
                )

                let status = try XCTUnwrap(binding.sessionStatus)
                XCTAssertEqual(status.phase, .failed)
                for forbiddenFragment in fixture.forbiddenFragments {
                    XCTAssertFalse(
                        status.detail.contains(forbiddenFragment),
                        "Fixture \(fixture.name) leaked \(forbiddenFragment): \(status.detail)"
                    )
                }
                XCTAssertTrue(
                    status.detail.contains(fixture.expectedRedaction),
                    "Fixture \(fixture.name) omitted \(fixture.expectedRedaction): \(status.detail)"
                )
                XCTAssertTrue(status.detail.contains("retry"))
            }
        }
    }

    func testFailedPresentationPreservesNoncredentialTokenAndPermissionProse() throws {
        try withDefaults { defaults in
            ClaudeAgentToolPreferences.setPermissionLevel(.auto, defaults: defaults)
            let store = AgentProviderPreferenceSnapshotStore(defaults: defaults)
            let messages = [
                "Usage report: input_tokens=2048 and output_tokens=512.",
                "The token budget remains available for this retry.",
                "Claude Auto is unavailable for the selected model; choose a supported model and retry."
            ]

            for message in messages {
                let binding = store.controlsBinding(
                    selectedAgent: .claudeCode,
                    selectedModelRaw: "opus",
                    permissionProfile: .userConfigured,
                    isSubagent: false,
                    externallyManagedReason: nil,
                    claudePermissionSessionState: .failed(
                        ownership: makeOwnership(),
                        requestedMode: "auto",
                        message: message
                    )
                )

                let status = try XCTUnwrap(binding.sessionStatus)
                XCTAssertTrue(status.detail.contains(message))
                XCTAssertFalse(status.detail.contains("[redacted]"))
            }
        }
    }

    func testPendingEffortPresentationRetainsAcknowledgementAndNextTurnIntent() throws {
        try withDefaults { defaults in
            ClaudeAgentToolPreferences.setPermissionLevel(.auto, defaults: defaults)
            let store = AgentProviderPreferenceSnapshotStore(defaults: defaults)
            let acknowledgement = makeAcknowledgement(
                requestedMode: "auto",
                launchMode: "auto"
            )

            let binding = store.controlsBinding(
                selectedAgent: .claudeCode,
                selectedModelRaw: "opus",
                permissionProfile: .userConfigured,
                isSubagent: false,
                externallyManagedReason: nil,
                claudePermissionSessionState: .pendingNextTurn(
                    active: acknowledgement,
                    requestedMode: "auto",
                    reason: "Effort change pending — apply failed"
                )
            )

            let status = try XCTUnwrap(binding.sessionStatus)
            XCTAssertEqual(status.phase, .pendingNextTurn)
            XCTAssertEqual(status.acknowledgedMode?.rawValue, "auto")
            XCTAssertEqual(status.resolvedLaunchMode?.rawValue, "auto")
            XCTAssertTrue(status.detail.contains("applies before the next turn"))
            XCTAssertTrue(status.detail.contains("active controller acknowledgement"))
        }
    }

    func testPendingEffortPresentationSanitizesCompleteCredentialValues() throws {
        try withDefaults { defaults in
            ClaudeAgentToolPreferences.setPermissionLevel(.auto, defaults: defaults)
            let store = AgentProviderPreferenceSnapshotStore(defaults: defaults)
            let acknowledgement = makeAcknowledgement(
                requestedMode: "auto",
                launchMode: "auto"
            )
            let fixtures: [(reason: String, secretParts: [String], redaction: String)] = [
                (
                    "Effort change pending — password=correct,horse",
                    ["correct", "horse"],
                    "password=[redacted]"
                ),
                (
                    #"Effort change pending — {"clientSecret":"escaped-prefix\"escaped-secret-suffix"}"#,
                    ["escaped-prefix", "escaped-secret-suffix"],
                    "clientSecret=[redacted]"
                )
            ]

            for fixture in fixtures {
                let binding = store.controlsBinding(
                    selectedAgent: .claudeCode,
                    selectedModelRaw: "opus",
                    permissionProfile: .userConfigured,
                    isSubagent: false,
                    externallyManagedReason: nil,
                    claudePermissionSessionState: .pendingNextTurn(
                        active: acknowledgement,
                        requestedMode: "auto",
                        reason: fixture.reason
                    )
                )

                let status = try XCTUnwrap(binding.sessionStatus)
                XCTAssertEqual(status.phase, .pendingNextTurn)
                for secretPart in fixture.secretParts {
                    XCTAssertFalse(status.detail.contains(secretPart))
                }
                XCTAssertTrue(status.detail.contains(fixture.redaction))
            }
        }
    }

    func testPendingEffortPresentationSanitizesCompactJSONCredentialAssignments() throws {
        try withDefaults { defaults in
            ClaudeAgentToolPreferences.setPermissionLevel(.auto, defaults: defaults)
            let store = AgentProviderPreferenceSnapshotStore(defaults: defaults)
            let acknowledgement = makeAcknowledgement(
                requestedMode: "auto",
                launchMode: "auto"
            )
            let fixtures: [(
                name: String,
                reason: String,
                secretParts: [String],
                expectedRedactions: [String]
            )] = [
                (
                    "A",
                    #"Effort change pending — {"token":null,"Authorization":"Bearer example-secret-value"}"#,
                    ["Bearer", "example-secret-value"],
                    ["token=[redacted]", "Authorization=[redacted]"]
                ),
                (
                    "B",
                    #"Effort change pending — {"api_key":null,"password":"correct horse"}"#,
                    ["correct", "horse"],
                    ["api_key=[redacted]", "password=[redacted]"]
                )
            ]

            for fixture in fixtures {
                let binding = store.controlsBinding(
                    selectedAgent: .claudeCode,
                    selectedModelRaw: "opus",
                    permissionProfile: .userConfigured,
                    isSubagent: false,
                    externallyManagedReason: nil,
                    claudePermissionSessionState: .pendingNextTurn(
                        active: acknowledgement,
                        requestedMode: "auto",
                        reason: fixture.reason
                    )
                )

                let status = try XCTUnwrap(binding.sessionStatus)
                XCTAssertEqual(status.phase, .pendingNextTurn)
                for secretPart in fixture.secretParts {
                    XCTAssertFalse(
                        status.detail.contains(secretPart),
                        "Fixture \(fixture.name) leaked \(secretPart): \(status.detail)"
                    )
                }
                for expectedRedaction in fixture.expectedRedactions {
                    XCTAssertTrue(
                        status.detail.contains(expectedRedaction),
                        "Fixture \(fixture.name) omitted \(expectedRedaction): \(status.detail)"
                    )
                }
            }
        }
    }

    func testPendingEffortPresentationRedactsLiteralMarkerCollisionsAndDanglingEscapes() throws {
        try withDefaults { defaults in
            ClaudeAgentToolPreferences.setPermissionLevel(.auto, defaults: defaults)
            let store = AgentProviderPreferenceSnapshotStore(defaults: defaults)
            let acknowledgement = makeAcknowledgement(
                requestedMode: "auto",
                launchMode: "auto"
            )

            for fixture in Self.markerCollisionAndDanglingEscapeFixtures {
                let binding = store.controlsBinding(
                    selectedAgent: .claudeCode,
                    selectedModelRaw: "opus",
                    permissionProfile: .userConfigured,
                    isSubagent: false,
                    externallyManagedReason: nil,
                    claudePermissionSessionState: .pendingNextTurn(
                        active: acknowledgement,
                        requestedMode: "auto",
                        reason: "Effort change pending — \(fixture.message)"
                    )
                )

                let status = try XCTUnwrap(binding.sessionStatus)
                XCTAssertEqual(status.phase, .pendingNextTurn)
                XCTAssertTrue(status.detail.contains("applies before the next turn"))
                for forbiddenFragment in fixture.forbiddenFragments {
                    XCTAssertFalse(
                        status.detail.contains(forbiddenFragment),
                        "Fixture \(fixture.name) leaked \(forbiddenFragment): \(status.detail)"
                    )
                }
                XCTAssertTrue(
                    status.detail.contains(fixture.expectedRedaction),
                    "Fixture \(fixture.name) omitted \(fixture.expectedRedaction): \(status.detail)"
                )
            }
        }
    }

    func testSessionStatusParticipatesInControlsBindingEquality() throws {
        try withDefaults { defaults in
            ClaudeAgentToolPreferences.setPermissionLevel(.auto, defaults: defaults)
            let store = AgentProviderPreferenceSnapshotStore(defaults: defaults)
            let base = store.controlsBinding(
                selectedAgent: .claudeCode,
                selectedModelRaw: "opus",
                permissionProfile: .userConfigured,
                isSubagent: false,
                externallyManagedReason: nil,
                claudePermissionSessionState: .notStarted
            )
            let initializing = store.controlsBinding(
                selectedAgent: .claudeCode,
                selectedModelRaw: "opus",
                permissionProfile: .userConfigured,
                isSubagent: false,
                externallyManagedReason: nil,
                claudePermissionSessionState: .initializing(
                    ownership: makeOwnership(),
                    launchSettings: makeLaunchSettings(permissionMode: "auto"),
                    requestedMode: "auto"
                )
            )

            XCTAssertNotEqual(base, initializing)
            XCTAssertEqual(base.sessionStatus?.phase, .selectedNotStarted)
            XCTAssertEqual(initializing.sessionStatus?.phase, .initializing)

            let codex = store.controlsBinding(
                selectedAgent: .codexExec,
                permissionProfile: .userConfigured,
                isSubagent: false,
                externallyManagedReason: nil,
                claudePermissionSessionState: .failed(
                    ownership: nil,
                    requestedMode: "auto",
                    message: "must not project"
                )
            )
            XCTAssertNil(codex.permission.sessionStatus)
            XCTAssertNil(codex.permission.configuredMode)
        }
    }

    /// Raw inputs whose literal `[redacted]` text or trailing backslash previously let a
    /// credential suffix survive sanitization. Every fixture must redact through the end of
    /// the credential value and keep only the generated `key=[redacted]` marker.
    private static let markerCollisionAndDanglingEscapeFixtures: [(
        name: String,
        message: String,
        forbiddenFragments: [String],
        expectedRedaction: String
    )] = [
        (
            "literal-marker-comma",
            "password=[redacted],horse",
            ["horse", "[redacted],"],
            "password=[redacted]"
        ),
        (
            "literal-marker-dot",
            "password=[redacted].sensitive-suffix",
            ["sensitive-suffix", "[redacted]."],
            "password=[redacted]"
        ),
        (
            "case-variant-internal-marker",
            "password=\u{E000}RPCE-REDACTED\u{E001},horse",
            ["horse", "\u{E000}", "\u{E001}"],
            "password=[redacted]"
        ),
        (
            "case-variant-suffixed-internal-marker",
            "token=\u{E000}rpce-redacted\u{E001};password=\u{E000}RPCE-REDACTED-1\u{E001},horse",
            ["horse", "\u{E000}", "\u{E001}"],
            "password=[redacted]"
        ),
        (
            "double-quoted-dangling-backslash",
            "{\"clientSecret\":\"truncated-prefix dangling-suffix\\",
            ["truncated-prefix", "dangling-suffix", "\\"],
            "clientSecret=[redacted]"
        ),
        (
            "single-quoted-dangling-backslash",
            "{'clientSecret':'truncated-prefix dangling-suffix\\",
            ["truncated-prefix", "dangling-suffix", "\\"],
            "clientSecret=[redacted]"
        ),
        (
            "bearer-quoted-dangling-backslash",
            "Authorization: Bearer \"quoted scheme-secret-value\\",
            ["Bearer", "quoted", "scheme-secret-value", "\\"],
            "Authorization=[redacted]"
        )
    ]

    private func withDefaults(
        _ body: (UserDefaults) throws -> Void
    ) throws {
        let suiteName = "ClaudeAutoPermissionPresentationTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        try body(defaults)
    }

    private func makeOwnership() -> ClaudePermissionControllerOwnership {
        ClaudePermissionControllerOwnership(
            controllerIdentifier: ObjectIdentifier(NSObject()),
            runID: UUID(),
            runAttemptID: UUID()
        )
    }

    private func makeAcknowledgement(
        requestedMode: String,
        launchMode: String
    ) -> ClaudePermissionAcknowledgement {
        ClaudePermissionAcknowledgement(
            ownership: makeOwnership(),
            launchSettings: makeLaunchSettings(permissionMode: launchMode),
            requestedMode: requestedMode,
            acknowledgedEffort: .high
        )
    }

    private func makeLaunchSettings(
        permissionMode: String
    ) -> ClaudeAgentModeCoordinator.ControllerLaunchSettings {
        ClaudeAgentModeCoordinator.ControllerLaunchSettings(
            runtimeVariant: .standard,
            workspacePath: "/workspace",
            permissionMode: permissionMode,
            allowNativeBashTool: false,
            mcpStrictMode: true,
            sessionProfile: .standard,
            toolSearchEnabled: nil,
            autoPermissionValidationKey: permissionMode.caseInsensitiveCompare("auto") == .orderedSame
                ? .init(
                    agentKind: .claudeCode,
                    runtimeVariant: .standard,
                    baseModel: "opus"
                )
                : nil
        )
    }
}

private extension AgentProviderControlsBinding {
    var permissionOptionsContainSelection: Bool {
        permission.options.contains(where: \.isSelected)
    }

    var configuredMode: AgentPermissionModePresentationBinding? {
        permission.configuredMode
    }

    var displayName: String {
        permission.displayName
    }

    var options: [AgentPermissionOptionBinding] {
        permission.options
    }

    var sessionStatus: AgentPermissionSessionStatusBinding? {
        permission.sessionStatus
    }
}
