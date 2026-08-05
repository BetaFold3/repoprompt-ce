import MCP
@testable import RepoPromptApp
import XCTest

final class OracleOperationToolCardRoutingTests: XCTestCase {
    func testContextBuilderSelectsExactPlanOrReviewChatID() throws {
        let planDTO = try contextBuilderDTO(responseType: "plan")
        let questionDTO = try contextBuilderDTO(responseType: "question")
        let reviewDTO = try contextBuilderDTO(responseType: "review")
        let normalizedPlanDTO = try contextBuilderDTO(responseType: "  PlAn\n")
        let normalizedQuestionDTO = try contextBuilderDTO(responseType: "\tQuEsTiOn ")
        let normalizedReviewDTO = try contextBuilderDTO(responseType: " ReViEw ")

        XCTAssertEqual(contextBuilderFollowUpChatID(for: planDTO), "plan-chat")
        XCTAssertEqual(contextBuilderFollowUpChatID(for: questionDTO), "plan-chat")
        XCTAssertEqual(contextBuilderFollowUpChatID(for: reviewDTO), "review-chat")
        XCTAssertEqual(contextBuilderFollowUpChatID(for: normalizedPlanDTO), "plan-chat")
        XCTAssertEqual(contextBuilderFollowUpChatID(for: normalizedQuestionDTO), "plan-chat")
        XCTAssertEqual(contextBuilderFollowUpChatID(for: normalizedReviewDTO), "review-chat")

        let tabID = UUID()
        let workspaceID = UUID()
        let openContext = AgentOracleOpenContext(
            windowID: 42,
            workspaceID: workspaceID,
            tabID: tabID,
            chatID: "ambient-chat"
        )
        let userInfo = try XCTUnwrap(contextBuilderOraclePopoverUserInfo(
            openContext: openContext,
            chatID: contextBuilderFollowUpChatID(for: reviewDTO)
        ))

        XCTAssertEqual(userInfo["windowID"] as? Int, 42)
        XCTAssertEqual(userInfo["workspaceID"] as? UUID, workspaceID)
        XCTAssertEqual(userInfo["tabID"] as? UUID, tabID)
        XCTAssertEqual(userInfo["chatID"] as? String, "review-chat")
    }

    func testContextBuilderOperationRoutingRejectsMissingOrBlankChatIDWithoutAmbientFallback() {
        let openContext = AgentOracleOpenContext(
            windowID: 42,
            workspaceID: UUID(),
            tabID: UUID(),
            chatID: "ambient-chat"
        )

        XCTAssertNil(contextBuilderOraclePopoverUserInfo(openContext: openContext, chatID: nil))
        XCTAssertNil(contextBuilderOraclePopoverUserInfo(openContext: openContext, chatID: "   \n"))
        XCTAssertNil(contextBuilderOraclePopoverUserInfo(
            openContext: AgentOracleOpenContext(windowID: 42, workspaceID: nil, tabID: UUID()),
            chatID: "exact-chat"
        ))
        XCTAssertNil(contextBuilderOraclePopoverUserInfo(
            openContext: AgentOracleOpenContext(windowID: 42, workspaceID: UUID(), tabID: nil),
            chatID: "exact-chat"
        ))
    }

    func testOracleLatestPopoverRouteOmitsChatIDAndPreservesScope() throws {
        let workspaceID = UUID()
        let contextTabID = UUID()
        let overrideTabID = UUID()
        let openContext = AgentOracleOpenContext(
            windowID: 42,
            workspaceID: workspaceID,
            tabID: contextTabID,
            chatID: "ambient-chat"
        )
        let route = try XCTUnwrap(AgentOracleLatestPopoverRoute(
            openContext: openContext,
            tabID: overrideTabID
        ))

        XCTAssertEqual(route.windowID, 42)
        XCTAssertEqual(route.workspaceID, workspaceID)
        XCTAssertEqual(route.tabID, overrideTabID)

        let userInfo = route.notificationUserInfo
        XCTAssertEqual(userInfo["windowID"] as? Int, 42)
        XCTAssertEqual(userInfo["workspaceID"] as? UUID, workspaceID)
        XCTAssertEqual(userInfo["tabID"] as? UUID, overrideTabID)
        XCTAssertEqual(userInfo["route"] as? String, "latest")
        XCTAssertNil(userInfo["chatID"])
        XCTAssertEqual(AgentOracleLatestPopoverRoute(notificationUserInfo: userInfo), route)
        XCTAssertNil(AgentOraclePopoverRoute(notificationUserInfo: userInfo))

        XCTAssertNil(AgentOracleLatestPopoverRoute(openContext: nil))
        XCTAssertNil(AgentOracleLatestPopoverRoute(
            openContext: AgentOracleOpenContext(windowID: 42, workspaceID: nil, tabID: contextTabID)
        ))
        XCTAssertNil(AgentOracleLatestPopoverRoute(
            openContext: AgentOracleOpenContext(windowID: 42, workspaceID: workspaceID, tabID: nil)
        ))
        XCTAssertNil(AgentOracleLatestPopoverRoute(notificationUserInfo: [
            "windowID": 42,
            "workspaceID": workspaceID,
            "tabID": contextTabID
        ]))
        XCTAssertNil(AgentOracleLatestPopoverRoute(notificationUserInfo: [
            "windowID": 42,
            "workspaceID": workspaceID,
            "tabID": contextTabID,
            "route": "other"
        ]))
        XCTAssertNil(AgentOracleLatestPopoverRoute(notificationUserInfo: [
            "windowID": 42,
            "workspaceID": workspaceID,
            "tabID": contextTabID,
            "route": "latest",
            "chatID": "exact-chat"
        ]))
    }

    func testOraclePopoverRoutePreservesNotificationTypesAndCompatibilityDecoding() throws {
        let workspaceID = UUID()
        let contextTabID = UUID()
        let overrideTabID = UUID()
        let openContext = AgentOracleOpenContext(
            windowID: 42,
            workspaceID: workspaceID,
            tabID: contextTabID,
            chatID: "ambient-chat"
        )
        let route = try XCTUnwrap(AgentOraclePopoverRoute(
            openContext: openContext,
            chatID: "  exact-short-id  ",
            tabID: overrideTabID
        ))

        XCTAssertEqual(route.windowID, 42)
        XCTAssertEqual(route.workspaceID, workspaceID)
        XCTAssertEqual(route.tabID, overrideTabID)
        XCTAssertEqual(route.chatID, "exact-short-id")

        let userInfo = route.notificationUserInfo
        XCTAssertEqual(userInfo["windowID"] as? Int, 42)
        XCTAssertEqual(userInfo["workspaceID"] as? UUID, workspaceID)
        XCTAssertEqual(userInfo["tabID"] as? UUID, overrideTabID)
        XCTAssertEqual(userInfo["chatID"] as? String, "exact-short-id")
        XCTAssertEqual(AgentOraclePopoverRoute(notificationUserInfo: userInfo), route)

        let stringCompatibleRoute = try XCTUnwrap(AgentOraclePopoverRoute(notificationUserInfo: [
            "windowID": 7,
            "workspaceID": workspaceID.uuidString,
            "tabID": contextTabID.uuidString,
            "chatID": "  short-chat  ",
            "extra": true
        ]))
        XCTAssertEqual(stringCompatibleRoute.workspaceID, workspaceID)
        XCTAssertEqual(stringCompatibleRoute.tabID, contextTabID)
        XCTAssertEqual(stringCompatibleRoute.chatID, "short-chat")

        let chatUUID = UUID()
        let uuidChatRoute = try XCTUnwrap(AgentOraclePopoverRoute(notificationUserInfo: [
            "windowID": 7,
            "workspaceID": workspaceID,
            "tabID": contextTabID,
            "chatID": chatUUID
        ]))
        XCTAssertEqual(uuidChatRoute.chatID, chatUUID.uuidString)
    }

    func testOraclePopoverRouteRejectsMissingMalformedAndAmbientFallbackInputs() {
        let workspaceID = UUID()
        let tabID = UUID()
        let openContext = AgentOracleOpenContext(
            windowID: 42,
            workspaceID: workspaceID,
            tabID: tabID,
            chatID: "ambient-chat"
        )

        XCTAssertNil(AgentOraclePopoverRoute(openContext: nil, chatID: "exact-chat"))
        XCTAssertNil(AgentOraclePopoverRoute(
            openContext: AgentOracleOpenContext(windowID: 42, workspaceID: nil, tabID: tabID),
            chatID: "exact-chat"
        ))
        XCTAssertNil(AgentOraclePopoverRoute(
            openContext: AgentOracleOpenContext(windowID: 42, workspaceID: workspaceID, tabID: nil),
            chatID: "exact-chat"
        ))
        XCTAssertNil(AgentOraclePopoverRoute(openContext: openContext, chatID: nil))
        XCTAssertNil(AgentOraclePopoverRoute(openContext: openContext, chatID: "  \n"))

        let valid: [AnyHashable: Any] = [
            "windowID": 42,
            "workspaceID": workspaceID,
            "tabID": tabID,
            "chatID": "exact-chat"
        ]
        XCTAssertNil(AgentOraclePopoverRoute(notificationUserInfo: nil))
        for key in ["windowID", "workspaceID", "tabID", "chatID"] {
            var missing = valid
            missing.removeValue(forKey: key)
            XCTAssertNil(AgentOraclePopoverRoute(notificationUserInfo: missing), key)
        }

        var malformed = valid
        malformed["windowID"] = "42"
        XCTAssertNil(AgentOraclePopoverRoute(notificationUserInfo: malformed))
        malformed = valid
        malformed["workspaceID"] = "not-a-uuid"
        XCTAssertNil(AgentOraclePopoverRoute(notificationUserInfo: malformed))
        malformed = valid
        malformed["tabID"] = 42
        XCTAssertNil(AgentOraclePopoverRoute(notificationUserInfo: malformed))
        malformed = valid
        malformed["chatID"] = "  \n"
        XCTAssertNil(AgentOraclePopoverRoute(notificationUserInfo: malformed))
        malformed = valid
        malformed["chatID"] = 42
        XCTAssertNil(AgentOraclePopoverRoute(notificationUserInfo: malformed))
    }

    func testDirectOracleResultRoutingRequiresExactResultChatID() throws {
        let tabID = UUID()
        let openContext = AgentOracleOpenContext(
            windowID: 7,
            workspaceID: UUID(),
            tabID: tabID,
            chatID: "ambient-chat"
        )
        let exactItem = toolResultItem(
            toolName: "ask_oracle",
            payload: ["chat_id": "  exact-result-chat  ", "mode": "review"]
        )
        let exactUserInfo = try XCTUnwrap(oracleToolResultPopoverUserInfo(
            item: exactItem,
            openContext: openContext
        ))

        XCTAssertEqual(exactUserInfo["windowID"] as? Int, 7)
        XCTAssertEqual(exactUserInfo["tabID"] as? UUID, tabID)
        XCTAssertEqual(exactUserInfo["chatID"] as? String, "exact-result-chat")

        let exactOracleSendUserInfo = oracleToolResultPopoverUserInfo(
            item: toolResultItem(
                toolName: "oracle_send",
                payload: ["chat_id": "exact-oracle-send-chat"]
            ),
            openContext: openContext
        )
        XCTAssertEqual(exactOracleSendUserInfo?["chatID"] as? String, "exact-oracle-send-chat")

        let malformedOptionalPayloadUserInfo = oracleToolResultPopoverUserInfo(
            item: toolResultItem(
                toolName: "ask_oracle",
                payload: ["chat_id": "exact-despite-malformed-diffs", "diffs": [["path": 42]]]
            ),
            openContext: openContext
        )
        XCTAssertEqual(
            malformedOptionalPayloadUserInfo?["chatID"] as? String,
            "exact-despite-malformed-diffs"
        )

        XCTAssertNil(oracleToolResultPopoverUserInfo(
            item: toolResultItem(toolName: "ask_oracle", payload: ["mode": "review"]),
            openContext: openContext
        ))
        XCTAssertNil(oracleToolResultPopoverUserInfo(
            item: toolResultItem(toolName: "ask_oracle", payload: ["chat_id": "\n  "]),
            openContext: openContext
        ))
        XCTAssertNil(oracleToolResultPopoverUserInfo(
            item: toolResultItem(toolName: "oracle_send", payload: ["chat_id": "   "]),
            openContext: openContext
        ))

        XCTAssertEqual(
            ToolCardRouter.callSubtitle(
                for: "ask_oracle",
                argsJSON: jsonString(["message": "review", "mode": "review", "model": "GPT_5_6_Sol_xhigh"])
            ),
            "review • GPT_5_6_Sol_xhigh"
        )
        let resolvedDTO = try XCTUnwrap(ToolJSON.decode(
            ToolResultDTOs.ChatSendDTO.self,
            from: jsonString([
                "chat_id": "resolved-chat",
                "mode": "review",
                "model_id": "legacy-provider-model-id",
                "model_name": "Legacy Provider Model",
                "ui_model_id": "codex_custom_gpt-5.6-sol-xhigh",
                "ui_model_name": "CLI·GPT-5.6 Sol XHigh",
                "model_selection": "explicit",
                "model_source": "preset",
                "model_preset_id": "DA2C9FCE-1D37-453F-8E15-DAD11E5EBD46",
                "model_preset_name": "GPT_5_6_Sol_xhigh",
                "response": "done"
            ])
        ))
        XCTAssertEqual(resolvedDTO.modelSelection, "explicit")
        XCTAssertEqual(resolvedDTO.modelSource, "preset")
        XCTAssertEqual(resolvedDTO.modelPresetID, "DA2C9FCE-1D37-453F-8E15-DAD11E5EBD46")
        XCTAssertEqual(resolvedDTO.modelPresetName, "GPT_5_6_Sol_xhigh")
        XCTAssertEqual(resolvedDTO.modelID, "legacy-provider-model-id")
        XCTAssertEqual(resolvedDTO.modelName, "Legacy Provider Model")
        XCTAssertEqual(
            resolvedDTO.uiModelID,
            "codex_custom_gpt-5.6-sol-xhigh"
        )
        XCTAssertEqual(resolvedDTO.uiModelName, "CLI·GPT-5.6 Sol XHigh")
        XCTAssertEqual(
            chatSendResultSummary(resolvedDTO),
            "review • GPT_5_6_Sol_xhigh • resolved-chat"
        )

        let roundTrippedData = try JSONEncoder().encode(resolvedDTO)
        let roundTrippedJSON = String(decoding: roundTrippedData, as: UTF8.self)
        XCTAssertFalse(
            roundTrippedJSON.contains("codex_custom_gpt-5.6-sol-xhigh"),
            roundTrippedJSON
        )
        XCTAssertFalse(
            roundTrippedJSON.contains("CLI·GPT-5.6 Sol XHigh"),
            roundTrippedJSON
        )
        XCTAssertFalse(roundTrippedJSON.contains("model_id"), roundTrippedJSON)
        XCTAssertFalse(roundTrippedJSON.contains("model_name"), roundTrippedJSON)
        XCTAssertFalse(roundTrippedJSON.contains("ui_model_id"), roundTrippedJSON)
        XCTAssertFalse(roundTrippedJSON.contains("ui_model_name"), roundTrippedJSON)

        let formatted = try onlyText(ToolOutputFormatter.formatAskOracle(
            args: [:],
            value: .object([
                "chat_id": .string("resolved-chat"),
                "mode": .string("review"),
                "model_id": .string("codex_custom_gpt-5.6-sol-xhigh"),
                "model_name": .string("CLI·GPT-5.6 Sol XHigh"),
                "model_selection": .string("explicit"),
                "model_source": .string("preset"),
                "model_preset_id": .string("DA2C9FCE-1D37-453F-8E15-DAD11E5EBD46"),
                "model_preset_name": .string("GPT_5_6_Sol_xhigh"),
                "usage": .object([
                    "input_tokens": .int(24000),
                    "context_window": .int(200_000),
                    "pct": .int(12),
                    "source": .string("app_estimate")
                ]),
                "response": .string("done")
            ]),
            emitResources: false
        ))
        XCTAssertTrue(formatted.contains("**Model selection**: explicit"), formatted)
        XCTAssertTrue(formatted.contains("`GPT_5_6_Sol_xhigh` (`DA2C9FCE-1D37-453F-8E15-DAD11E5EBD46`)"), formatted)
        XCTAssertFalse(formatted.contains("CLI·GPT-5.6 Sol XHigh"), formatted)
        XCTAssertFalse(formatted.contains("codex_custom_gpt-5.6-sol-xhigh"), formatted)
        XCTAssertFalse(formatted.contains("**Resolved model"), formatted)
        XCTAssertTrue(formatted.contains("**Model source**: `preset`"), formatted)
        XCTAssertTrue(
            formatted.contains("input_tokens: 24000, context_window: 200000, pct: 12, source: app_estimate"),
            formatted
        )

        let nonPresetFormatted = try onlyText(ToolOutputFormatter.formatAskOracle(
            args: [:],
            value: .object([
                "chat_id": .string("planning-chat"),
                "mode": .string("plan"),
                "model_id": .string("planning-model-id"),
                "model_name": .string("Planning Model"),
                "model_selection": .string("explicit"),
                "model_source": .string("planning_model"),
                "response": .string("done")
            ]),
            emitResources: false
        ))
        XCTAssertTrue(
            nonPresetFormatted.contains("Planning Model (`planning-model-id`)"),
            nonPresetFormatted
        )
    }

    func testOracleToolCallRoutingRequiresExactArgumentChatID() throws {
        let openContext = AgentOracleOpenContext(
            windowID: 9,
            workspaceID: UUID(),
            tabID: UUID(),
            chatID: "ambient-chat"
        )
        let exactItem = AgentChatItem(
            kind: .toolCall,
            text: "",
            toolName: "oracle_send",
            toolArgsJSON: jsonString(["chat_id": "  exact-call-chat  "])
        )
        let exactUserInfo = try XCTUnwrap(oracleToolCallPopoverUserInfo(
            item: exactItem,
            openContext: openContext
        ))

        XCTAssertEqual(exactUserInfo["chatID"] as? String, "exact-call-chat")

        let completedExactUserInfo = try XCTUnwrap(oracleToolCallPopoverUserInfo(
            item: AgentChatItem(
                kind: .toolCall,
                text: "",
                toolName: "ask_oracle",
                toolArgsJSON: jsonString(["message": "start a new chat"]),
                toolResultJSON: jsonString(["chat_id": "  exact-result-chat  ", "mode": "review"]),
                toolIsError: false
            ),
            openContext: openContext
        ))
        XCTAssertEqual(completedExactUserInfo["chatID"] as? String, "exact-result-chat")
        XCTAssertNil(completedExactUserInfo["route"])

        XCTAssertNil(oracleToolCallPopoverUserInfo(
            item: AgentChatItem(
                kind: .toolCall,
                text: "",
                toolName: "ask_oracle",
                toolArgsJSON: jsonString(["message": "start a new chat"]),
                toolResultJSON: jsonString(["status": "failed"]),
                toolIsError: true
            ),
            openContext: openContext
        ))

        let latestUserInfo = try XCTUnwrap(oracleToolCallPopoverUserInfo(
            item: AgentChatItem(
                kind: .toolCall,
                text: "",
                toolName: "ask_oracle",
                toolArgsJSON: jsonString(["message": "start a new chat"])
            ),
            openContext: openContext
        ))
        XCTAssertEqual(latestUserInfo["windowID"] as? Int, openContext.windowID)
        XCTAssertEqual(latestUserInfo["workspaceID"] as? UUID, openContext.workspaceID)
        XCTAssertEqual(latestUserInfo["tabID"] as? UUID, openContext.tabID)
        XCTAssertEqual(latestUserInfo["route"] as? String, "latest")
        XCTAssertNil(latestUserInfo["chatID"])
        XCTAssertNotNil(AgentOracleLatestPopoverRoute(notificationUserInfo: latestUserInfo))
        XCTAssertNil(AgentOraclePopoverRoute(notificationUserInfo: latestUserInfo))
        XCTAssertNil(oracleToolCallPopoverUserInfo(
            item: AgentChatItem(
                kind: .toolCall,
                text: "",
                toolName: "oracle_send",
                toolArgsJSON: jsonString(["chat_id": "\t "])
            ),
            openContext: openContext
        ))
        XCTAssertNil(oracleToolCallPopoverUserInfo(
            item: AgentChatItem(
                kind: .toolCall,
                text: "",
                toolName: "ask_oracle",
                toolArgsJSON: jsonString(["chatID": "camel-alias"])
            ),
            openContext: openContext
        ))
        XCTAssertNil(oracleToolCallPopoverUserInfo(
            item: AgentChatItem(
                kind: .toolCall,
                text: "",
                toolName: "ask_oracle",
                toolArgsJSON: jsonString(["message": "continue", "payload": ["chat_id": "nested"]])
            ),
            openContext: openContext
        ))
        XCTAssertNil(oracleToolCallPopoverUserInfo(
            item: AgentChatItem(
                kind: .toolCall,
                text: "",
                toolName: "ask_oracle",
                toolArgsJSON: "{bad json"
            ),
            openContext: openContext
        ))
        XCTAssertNil(oracleToolCallPopoverUserInfo(
            item: AgentChatItem(
                kind: .toolCall,
                text: "",
                toolName: "ask_oracle",
                toolArgsJSON: "  \n"
            ),
            openContext: openContext
        ))
        XCTAssertNil(oracleToolCallPopoverUserInfo(
            item: AgentChatItem(
                kind: .toolCall,
                text: "",
                toolName: "ask_oracle",
                toolArgsJSON: "[]"
            ),
            openContext: openContext
        ))
    }

    func testDirectOracleRoutingRejectsNestedAliasedAndConflictingChatIDs() {
        let openContext = AgentOracleOpenContext(
            windowID: 11,
            workspaceID: UUID(),
            tabID: UUID()
        )

        let rejectedPayloads: [[String: Any]] = [
            ["result": ["chat_id": "nested-only"]],
            ["chatID": "camel-only"],
            ["chat_id": 42],
            ["chat_id": "authoritative", "result": ["chat_id": "conflict"]],
            ["chat_id": "authoritative", "items": [["chatID": "conflict"]]]
        ]

        for payload in rejectedPayloads {
            XCTAssertNil(oracleToolResultPopoverUserInfo(
                item: toolResultItem(toolName: "ask_oracle", payload: payload),
                openContext: openContext
            ))
            XCTAssertNil(oracleToolCallPopoverUserInfo(
                item: AgentChatItem(
                    kind: .toolCall,
                    text: "",
                    toolName: "oracle_send",
                    toolArgsJSON: jsonString(payload)
                ),
                openContext: openContext
            ))
        }
    }

    func testAuthoritativeChatIDPolicyPreservesFailClosedRootRulesAcrossEntryPoints() {
        let acceptedPayloads: [([String: Any], String)] = [
            (["chat_id": "  exact-chat  "], "exact-chat"),
            (["chat_id": "exact-with-unrelated-data", "diffs": [["path": 42]]], "exact-with-unrelated-data")
        ]
        for (payload, expected) in acceptedPayloads {
            XCTAssertEqual(
                AgentOracleAuthoritativeChatIDPolicy.extract(fromRootObject: payload),
                expected
            )
            XCTAssertEqual(
                AgentOracleAuthoritativeChatIDPolicy.extract(fromSerializedJSON: jsonString(payload)),
                expected
            )
        }

        let rejectedPayloads: [[String: Any]] = [
            [:],
            ["chatID": "camel-only"],
            ["chat_id": "exact", "chatID": "alias"],
            ["chat_id": 42],
            ["chat_id": "  \n"],
            ["chat_id": "exact", "result": ["chat_id": "nested"]],
            ["chat_id": "exact", "items": [["chatID": "nested"]]]
        ]
        for payload in rejectedPayloads {
            XCTAssertNil(AgentOracleAuthoritativeChatIDPolicy.extract(fromRootObject: payload))
            XCTAssertNil(
                AgentOracleAuthoritativeChatIDPolicy.extract(fromSerializedJSON: jsonString(payload))
            )
        }

        XCTAssertNil(AgentOracleAuthoritativeChatIDPolicy.extract(fromSerializedJSON: nil))
        XCTAssertNil(AgentOracleAuthoritativeChatIDPolicy.extract(fromSerializedJSON: "  \n"))
        XCTAssertNil(AgentOracleAuthoritativeChatIDPolicy.extract(fromSerializedJSON: "not-json"))
        XCTAssertNil(AgentOracleAuthoritativeChatIDPolicy.extract(fromSerializedJSON: "null"))
        XCTAssertNil(AgentOracleAuthoritativeChatIDPolicy.extract(fromSerializedJSON: "42"))
        XCTAssertNil(AgentOracleAuthoritativeChatIDPolicy.extract(fromSerializedJSON: "[]"))
    }

    func testContextBuilderRoutingRejectsMismatchedOrUnknownResponseBranch() throws {
        let reviewWithPlanOnly = try XCTUnwrap(ToolJSON.decode(
            ToolResultDTOs.ContextBuilderDTO.self,
            from: jsonString([
                "status": "success",
                "response_type": "review",
                "plan": ["chat_id": "wrong-plan-chat", "mode": "plan"]
            ])
        ))
        let unknownWithPlan = try XCTUnwrap(ToolJSON.decode(
            ToolResultDTOs.ContextBuilderDTO.self,
            from: jsonString([
                "status": "success",
                "response_type": "clarify",
                "plan": ["chat_id": "wrong-plan-chat", "mode": "plan"]
            ])
        ))
        let planWithReviewOnly = try XCTUnwrap(ToolJSON.decode(
            ToolResultDTOs.ContextBuilderDTO.self,
            from: jsonString([
                "status": "success",
                "response_type": "plan",
                "review": ["chat_id": "wrong-review-chat", "mode": "review"]
            ])
        ))
        let missingResponseType = try XCTUnwrap(ToolJSON.decode(
            ToolResultDTOs.ContextBuilderDTO.self,
            from: jsonString([
                "status": "success",
                "plan": ["chat_id": "wrong-plan-chat", "mode": "plan"],
                "review": ["chat_id": "wrong-review-chat", "mode": "review"]
            ])
        ))

        XCTAssertNil(contextBuilderFollowUpChatID(for: reviewWithPlanOnly))
        XCTAssertNil(contextBuilderFollowUpChatID(for: unknownWithPlan))
        XCTAssertNil(contextBuilderFollowUpChatID(for: planWithReviewOnly))
        XCTAssertNil(contextBuilderFollowUpChatID(for: missingResponseType))
    }

    private func contextBuilderDTO(responseType: String) throws -> ToolResultDTOs.ContextBuilderDTO {
        let raw = jsonString([
            "status": "success",
            "response_type": responseType,
            "plan": ["chat_id": "plan-chat", "mode": "plan"],
            "review": ["chat_id": "review-chat", "mode": "review"]
        ])
        return try XCTUnwrap(ToolJSON.decode(ToolResultDTOs.ContextBuilderDTO.self, from: raw))
    }

    private func toolResultItem(toolName: String, payload: [String: Any]) -> AgentChatItem {
        let raw = jsonString(payload)
        return AgentChatItem(
            kind: .toolResult,
            text: raw,
            toolName: toolName,
            toolResultJSON: raw
        )
    }

    private func onlyText(_ blocks: [MCP.Tool.Content]) throws -> String {
        let first = try XCTUnwrap(blocks.first)
        guard case let .text(text, _, _) = first else {
            XCTFail("Expected text content")
            return ""
        }
        return text
    }

    private func jsonString(
        _ object: [String: Any],
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> String {
        XCTAssertTrue(JSONSerialization.isValidJSONObject(object), file: file, line: line)
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(data: data, encoding: .utf8)!
    }
}
