import Foundation

// Strict, extras-preserving codec for `AgentRecoveryRecord`.
//
// Decoding reads the semantic JSON value, takes the typed members it knows, and keeps every other
// member as extras at that object boundary. A supported record must re-encode to exactly the
// decoded JSON value; anything else (missing/ill-typed required member, explicit null, unknown
// closed-set variant, non-integral number, future schema) is reported as unreadable so the store
// preserves the original bytes and refuses to write.

package enum AgentRecoveryUnreadableReason: Error, Equatable {
    case futureSchema(Int)
    case malformed(String)
    case unknownVariant(String)
    case unreadableFile(String)
}

struct AgentRecoveryDecodingError: Error, Equatable {
    let reason: AgentRecoveryUnreadableReason
}

enum AgentRecoveryRecordCodec {
    // MARK: Record

    static func decode(_ data: Data, expectedSessionID: UUID) -> Result<AgentRecoveryRecord, AgentRecoveryUnreadableReason> {
        let json: AgentRecoveryJSONValue
        do {
            json = try JSONDecoder().decode(AgentRecoveryJSONValue.self, from: data)
        } catch {
            return .failure(.malformed("record is not JSON"))
        }
        do {
            var reader = try Reader(json, path: "record")
            let schemaVersion = try reader.int("schemaVersion")
            guard schemaVersion == AgentRecoveryRecord.currentSchemaVersion else {
                let isFuture = schemaVersion > AgentRecoveryRecord.currentSchemaVersion
                let reason: AgentRecoveryUnreadableReason = isFuture
                    ? .futureSchema(schemaVersion)
                    : .malformed("unsupported schemaVersion \(schemaVersion)")
                return .failure(reason)
            }
            let sessionID = try reader.uuid("sessionID")
            guard sessionID == expectedSessionID else {
                return .failure(.malformed("sessionID does not match file name"))
            }
            let record = try AgentRecoveryRecord(
                sessionID: sessionID,
                revision: AgentRecoveryRecordRevision(token: reader.string("revision")),
                incarnationID: reader.uuid("incarnationID"),
                transcriptResetGeneration: reader.uint64("transcriptResetGeneration"),
                updatedAt: reader.timestamp("updatedAt"),
                composer: reader.optional("composer").map { try composer($0, path: "record.composer") },
                intents: reader.array("intents").enumerated().map { try intent($1, path: "record.intents[\($0)]") },
                attempts: reader.array("attempts").enumerated().map { try attempt($1, path: "record.attempts[\($0)]") },
                runAttempts: reader.array("runAttempts").enumerated().map { try runAttempt($1, path: "record.runAttempts[\($0)]") },
                crashHoldAcknowledgement: reader.optional("crashHoldAcknowledgement").map {
                    try crashHoldAcknowledgement($0, path: "record.crashHoldAcknowledgement")
                },
                questions: questions(reader.optional("questions"), path: "record.questions"),
                extras: reader.extras
            )
            try validateInvariants(record)
            // Lossless guarantee: a supported record re-encodes to exactly what was read.
            guard encodeJSON(record) == json else {
                return .failure(.malformed("record does not round-trip exactly"))
            }
            return .success(record)
        } catch let error as AgentRecoveryDecodingError {
            return .failure(error.reason)
        } catch {
            return .failure(.malformed(String(describing: error)))
        }
    }

    static func encode(_ record: AgentRecoveryRecord) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return try encoder.encode(encodeJSON(record))
    }

    static func encodeJSON(_ record: AgentRecoveryRecord) -> AgentRecoveryJSONValue {
        var object = record.extras
        object["schemaVersion"] = .number(Decimal(AgentRecoveryRecord.currentSchemaVersion))
        object["sessionID"] = .string(record.sessionID.uuidString)
        object["revision"] = .string(record.revision.token)
        object["incarnationID"] = .string(record.incarnationID.uuidString)
        object["transcriptResetGeneration"] = .number(Decimal(record.transcriptResetGeneration))
        object["updatedAt"] = timestampJSON(record.updatedAt)
        if let composer = record.composer {
            object["composer"] = composerJSON(composer)
        }
        object["intents"] = .array(record.intents.map(intentJSON))
        object["attempts"] = .array(record.attempts.map(attemptJSON))
        object["runAttempts"] = .array(record.runAttempts.map(runAttemptJSON))
        if let acknowledgement = record.crashHoldAcknowledgement {
            object["crashHoldAcknowledgement"] = crashHoldAcknowledgementJSON(acknowledgement)
        }
        // Absent when empty, so records without questions keep their existing bytes.
        if !record.questions.isEmpty {
            object["questions"] = .array(record.questions.map(questionJSON))
        }
        return .object(object)
    }

    // MARK: Pending-question snapshots

    private static func questions(
        _ json: AgentRecoveryJSONValue?,
        path: String
    ) throws -> [AgentRecoveryQuestionSnapshot] {
        guard let json else { return [] }
        guard case let .array(values) = json else {
            throw AgentRecoveryDecodingError(reason: .malformed("\(path) is not an array"))
        }
        return try values.enumerated().map { try question($1, path: "\(path)[\($0)]") }
    }

    private static func question(_ json: AgentRecoveryJSONValue, path: String) throws -> AgentRecoveryQuestionSnapshot {
        var reader = try Reader(json, path: path)
        let kindRaw = try reader.string("kind")
        guard let kind = AgentRecoveryQuestionKind(rawValue: kindRaw) else {
            throw AgentRecoveryDecodingError(reason: .unknownVariant("\(path).kind \(kindRaw)"))
        }
        return try AgentRecoveryQuestionSnapshot(
            interactionID: reader.uuid("interactionID"),
            kind: kind,
            runAttemptID: reader.optionalUUID("runAttemptID"),
            transcriptResetGeneration: reader.uint64("transcriptResetGeneration"),
            appInstanceID: reader.uuid("appInstanceID"),
            askedAt: reader.timestamp("askedAt"),
            title: reader.optionalString("title"),
            message: reader.optionalString("message"),
            items: reader.array("items").enumerated().map { try questionItem($1, path: "\(path).items[\($0)]") },
            extras: reader.extras
        )
    }

    private static func questionItem(_ json: AgentRecoveryJSONValue, path: String) throws -> AgentRecoveryQuestionItem {
        var reader = try Reader(json, path: path)
        let isSecret = try reader.bool("isSecret")
        let answer = try reader.optionalString("answer")
        // A secret answer on disk is never adopted (and would not round-trip): unreadable.
        if isSecret, answer != nil {
            throw AgentRecoveryDecodingError(reason: .malformed("\(path) stores a secret answer"))
        }
        return try AgentRecoveryQuestionItem(
            questionID: reader.string("questionID"),
            header: reader.optionalString("header"),
            text: reader.string("text"),
            options: reader.array("options").enumerated().map { try Reader.string($1, path: "\(path).options[\($0)]") },
            isSecret: isSecret,
            answer: answer,
            extras: reader.extras
        )
    }

    private static func questionJSON(_ snapshot: AgentRecoveryQuestionSnapshot) -> AgentRecoveryJSONValue {
        var object = snapshot.extras
        object["interactionID"] = .string(snapshot.interactionID.uuidString)
        object["kind"] = .string(snapshot.kind.rawValue)
        setOptional(&object, "runAttemptID", snapshot.runAttemptID?.uuidString)
        object["transcriptResetGeneration"] = .number(Decimal(snapshot.transcriptResetGeneration))
        object["appInstanceID"] = .string(snapshot.appInstanceID.uuidString)
        object["askedAt"] = timestampJSON(snapshot.askedAt)
        setOptional(&object, "title", snapshot.title)
        setOptional(&object, "message", snapshot.message)
        object["items"] = .array(snapshot.items.map(questionItemJSON))
        return .object(object)
    }

    private static func questionItemJSON(_ item: AgentRecoveryQuestionItem) -> AgentRecoveryJSONValue {
        var object = item.extras
        object["questionID"] = .string(item.questionID)
        setOptional(&object, "header", item.header)
        object["text"] = .string(item.text)
        object["options"] = .array(item.options.map { .string($0) })
        object["isSecret"] = .bool(item.isSecret)
        // Defense in depth: the model already drops it, the encoder never writes one either.
        if !item.isSecret {
            setOptional(&object, "answer", item.answer)
        }
        return .object(object)
    }

    // MARK: Crash-hold acknowledgement

    private static func crashHoldAcknowledgement(
        _ json: AgentRecoveryJSONValue,
        path: String
    ) throws -> AgentRecoveryCrashHoldAcknowledgement {
        var reader = try Reader(json, path: path)
        func ids(_ key: String) throws -> Set<UUID> {
            let values = try reader.array(key).enumerated().map { try Reader.uuid($1, path: "\(path).\(key)[\($0)]") }
            let set = Set(values)
            // Sorted and unique only: anything else would not re-encode exactly.
            guard set.count == values.count else {
                throw AgentRecoveryDecodingError(reason: .malformed("\(path).\(key) has duplicates"))
            }
            return set
        }
        return try AgentRecoveryCrashHoldAcknowledgement(
            decisionID: reader.uuid("decisionID"),
            incarnationID: reader.uuid("incarnationID"),
            transcriptResetGeneration: reader.uint64("transcriptResetGeneration"),
            runAttemptIDs: ids("runAttemptIDs"),
            intentIDs: ids("intentIDs"),
            transcriptTurnIDs: ids("transcriptTurnIDs"),
            recordedAt: reader.timestamp("recordedAt"),
            extras: reader.extras
        )
    }

    private static func crashHoldAcknowledgementJSON(
        _ acknowledgement: AgentRecoveryCrashHoldAcknowledgement
    ) -> AgentRecoveryJSONValue {
        func ids(_ set: Set<UUID>) -> AgentRecoveryJSONValue {
            .array(set.map(\.uuidString).sorted().map { .string($0) })
        }
        var object = acknowledgement.extras
        object["decisionID"] = .string(acknowledgement.decisionID.uuidString)
        object["incarnationID"] = .string(acknowledgement.incarnationID.uuidString)
        object["transcriptResetGeneration"] = .number(Decimal(acknowledgement.transcriptResetGeneration))
        object["runAttemptIDs"] = ids(acknowledgement.runAttemptIDs)
        object["intentIDs"] = ids(acknowledgement.intentIDs)
        object["transcriptTurnIDs"] = ids(acknowledgement.transcriptTurnIDs)
        object["recordedAt"] = timestampJSON(acknowledgement.recordedAt)
        return .object(object)
    }

    /// Structural invariants that typed fields alone cannot express.
    private static func validateInvariants(_ record: AgentRecoveryRecord) throws {
        var intentIDs: Set<UUID> = []
        for intent in record.intents {
            guard intentIDs.insert(intent.intentID).inserted else {
                throw AgentRecoveryDecodingError(reason: .malformed("duplicate intent \(intent.intentID)"))
            }
        }
        var attemptIDs: Set<UUID> = []
        for attempt in record.attempts {
            guard attemptIDs.insert(attempt.attemptID).inserted else {
                throw AgentRecoveryDecodingError(reason: .malformed("duplicate attempt \(attempt.attemptID)"))
            }
            guard let intent = record.intent(id: attempt.intentID), intent.userItemID == attempt.userItemID else {
                throw AgentRecoveryDecodingError(reason: .malformed("attempt \(attempt.attemptID) has no matching intent"))
            }
        }
        for attempt in record.attempts {
            if let superseded = attempt.supersededOutcome {
                guard attempt.outcome?.outcome == .providerAccepted, superseded.outcome != .providerAccepted else {
                    throw AgentRecoveryDecodingError(reason: .malformed("attempt \(attempt.attemptID) superseded outcome"))
                }
            }
        }
        for intent in record.intents {
            let intentAttempts = record.attempts(forIntent: intent.intentID)
            let openCount = intentAttempts.count { $0.outcome == nil }
            // Exactly one open attempt while dispatching; an intent accepted through an earlier
            // attempt may still carry one open later attempt; otherwise none.
            let openCountValid = switch intent.deliveryState {
            case .dispatching: openCount == 1
            case .providerAccepted: openCount <= 1
            default: openCount == 0
            }
            guard openCountValid else {
                throw AgentRecoveryDecodingError(reason: .malformed("intent \(intent.intentID) open-attempt count"))
            }
            let hasAcceptedAttempt = intentAttempts.contains { $0.outcome?.outcome == .providerAccepted }
            guard (intent.deliveryState == .providerAccepted) == hasAcceptedAttempt else {
                throw AgentRecoveryDecodingError(reason: .malformed("intent \(intent.intentID) acceptance evidence"))
            }
            let withdrawalValid = intent.deliveryState == .withdrawn
                ? intent.withdrawnAt != nil
                : intent.withdrawnAt == nil || intent.deliveryState == .providerAccepted
            guard withdrawalValid else {
                throw AgentRecoveryDecodingError(reason: .malformed("intent \(intent.intentID) withdrawal marker"))
            }
        }
        var runAttemptIDs: Set<UUID> = []
        for run in record.runAttempts {
            guard runAttemptIDs.insert(run.runAttemptID).inserted else {
                throw AgentRecoveryDecodingError(reason: .malformed("duplicate run attempt \(run.runAttemptID)"))
            }
        }
        if let composer = record.composer, composer.transcriptResetGeneration > record.transcriptResetGeneration {
            throw AgentRecoveryDecodingError(reason: .malformed("composer generation exceeds record generation"))
        }
        for name in record.referencedManagedImageFileNames where !isSafeManagedFileName(name) {
            throw AgentRecoveryDecodingError(reason: .malformed("unsafe managed image file name"))
        }
    }

    static func isSafeManagedFileName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.hasPrefix(".")
    }

    // MARK: Composer and content

    private static func composer(_ json: AgentRecoveryJSONValue, path: String) throws -> AgentRecoveryComposerSnapshot {
        var reader = try Reader(json, path: path)
        return try AgentRecoveryComposerSnapshot(
            revision: AgentRecoveryComposerRevision(token: reader.string("revision")),
            capturedAt: reader.timestamp("capturedAt"),
            transcriptResetGeneration: reader.uint64("transcriptResetGeneration"),
            content: content(reader.required("content"), path: "\(path).content"),
            extras: reader.extras
        )
    }

    private static func composerJSON(_ composer: AgentRecoveryComposerSnapshot) -> AgentRecoveryJSONValue {
        var object = composer.extras
        object["revision"] = .string(composer.revision.token)
        object["capturedAt"] = timestampJSON(composer.capturedAt)
        object["transcriptResetGeneration"] = .number(Decimal(composer.transcriptResetGeneration))
        object["content"] = contentJSON(composer.content)
        return .object(object)
    }

    private static func content(_ json: AgentRecoveryJSONValue, path: String) throws -> AgentRecoveryInputContent {
        var reader = try Reader(json, path: path)
        return try AgentRecoveryInputContent(
            text: reader.string("text"),
            images: reader.array("images").enumerated().map { try image($1, path: "\(path).images[\($0)]") },
            taggedFiles: reader.array("taggedFiles").enumerated().map { try taggedFile($1, path: "\(path).taggedFiles[\($0)]") },
            workflow: reader.optional("workflow").map { try workflow($0, path: "\(path).workflow") },
            interviewFirst: reader.bool("interviewFirst"),
            extras: reader.extras
        )
    }

    private static func contentJSON(_ content: AgentRecoveryInputContent) -> AgentRecoveryJSONValue {
        var object = content.extras
        object["text"] = .string(content.text)
        object["images"] = .array(content.images.map(imageJSON))
        object["taggedFiles"] = .array(content.taggedFiles.map(taggedFileJSON))
        if let workflow = content.workflow {
            object["workflow"] = workflowJSON(workflow)
        }
        object["interviewFirst"] = .bool(content.interviewFirst)
        return .object(object)
    }

    private static func image(_ json: AgentRecoveryJSONValue, path: String) throws -> AgentRecoveryImageReference {
        var reader = try Reader(json, path: path)
        let id = try reader.uuid("id")
        let kind = try reader.string("kind")
        let location: AgentRecoveryImageReference.Location
        switch kind {
        case "managedFile":
            location = try .managedFile(fileName: reader.string("fileName"))
        case "remoteURL":
            location = try .remoteURL(reader.string("url"))
        default:
            throw AgentRecoveryDecodingError(reason: .unknownVariant("\(path).kind=\(kind)"))
        }
        return try AgentRecoveryImageReference(
            id: id,
            location: location,
            title: reader.optionalString("title"),
            createdAt: reader.timestamp("createdAt"),
            extras: reader.extras
        )
    }

    private static func imageJSON(_ image: AgentRecoveryImageReference) -> AgentRecoveryJSONValue {
        var object = image.extras
        object["id"] = .string(image.id.uuidString)
        switch image.location {
        case let .managedFile(fileName):
            object["kind"] = .string("managedFile")
            object["fileName"] = .string(fileName)
        case let .remoteURL(url):
            object["kind"] = .string("remoteURL")
            object["url"] = .string(url)
        }
        if let title = image.title {
            object["title"] = .string(title)
        }
        object["createdAt"] = timestampJSON(image.createdAt)
        return .object(object)
    }

    private static func taggedFile(_ json: AgentRecoveryJSONValue, path: String) throws -> AgentRecoveryTaggedFileReference {
        var reader = try Reader(json, path: path)
        return try AgentRecoveryTaggedFileReference(
            id: reader.uuid("id"),
            relativePath: reader.string("relativePath"),
            displayName: reader.string("displayName"),
            createdAt: reader.timestamp("createdAt"),
            extras: reader.extras
        )
    }

    private static func taggedFileJSON(_ file: AgentRecoveryTaggedFileReference) -> AgentRecoveryJSONValue {
        var object = file.extras
        object["id"] = .string(file.id.uuidString)
        object["relativePath"] = .string(file.relativePath)
        object["displayName"] = .string(file.displayName)
        object["createdAt"] = timestampJSON(file.createdAt)
        return .object(object)
    }

    private static func workflow(_ json: AgentRecoveryJSONValue, path: String) throws -> AgentRecoveryWorkflowSnapshot {
        var reader = try Reader(json, path: path)
        let kind = try reader.string("kind")
        let source: AgentRecoveryWorkflowSnapshot.Source
        switch kind {
        case "builtIn":
            let raw = try reader.string("builtIn")
            guard let workflow = AgentWorkflow(rawValue: raw) else {
                throw AgentRecoveryDecodingError(reason: .unknownVariant("\(path).builtIn=\(raw)"))
            }
            source = .builtIn(workflow)
        case "custom":
            source = try .custom(id: reader.uuid("customID"))
        default:
            throw AgentRecoveryDecodingError(reason: .unknownVariant("\(path).kind=\(kind)"))
        }
        return try AgentRecoveryWorkflowSnapshot(
            source: source,
            displayName: reader.string("displayName"),
            iconName: reader.string("iconName"),
            accentColorHex: reader.optionalString("accentColorHex"),
            tooltipText: reader.optionalString("tooltipText"),
            descriptionText: reader.optionalString("descriptionText"),
            template: reader.optionalString("template"),
            extras: reader.extras
        )
    }

    private static func workflowJSON(_ workflow: AgentRecoveryWorkflowSnapshot) -> AgentRecoveryJSONValue {
        var object = workflow.extras
        switch workflow.source {
        case let .builtIn(builtIn):
            object["kind"] = .string("builtIn")
            object["builtIn"] = .string(builtIn.rawValue)
        case let .custom(id):
            object["kind"] = .string("custom")
            object["customID"] = .string(id.uuidString)
        }
        object["displayName"] = .string(workflow.displayName)
        object["iconName"] = .string(workflow.iconName)
        setOptional(&object, "accentColorHex", workflow.accentColorHex)
        setOptional(&object, "tooltipText", workflow.tooltipText)
        setOptional(&object, "descriptionText", workflow.descriptionText)
        setOptional(&object, "template", workflow.template)
        return .object(object)
    }

    // MARK: Intents and attempts

    private static func intent(_ json: AgentRecoveryJSONValue, path: String) throws -> AgentRecoveryIntent {
        var reader = try Reader(json, path: path)
        let originRaw = try reader.string("origin")
        guard let origin = AgentRecoveryIntentOrigin(rawValue: originRaw) else {
            throw AgentRecoveryDecodingError(reason: .unknownVariant("\(path).origin=\(originRaw)"))
        }
        let stateRaw = try reader.string("deliveryState")
        guard let state = AgentRecoveryDeliveryState(rawValue: stateRaw) else {
            throw AgentRecoveryDecodingError(reason: .unknownVariant("\(path).deliveryState=\(stateRaw)"))
        }
        return try AgentRecoveryIntent(
            intentID: reader.uuid("intentID"),
            userItemID: reader.uuid("userItemID"),
            origin: origin,
            target: intentTarget(reader.required("target"), path: "\(path).target"),
            createdAt: reader.timestamp("createdAt"),
            appInstanceID: reader.uuid("appInstanceID"),
            transcriptResetGeneration: reader.uint64("transcriptResetGeneration"),
            deliveryState: state,
            payload: content(reader.required("payload"), path: "\(path).payload"),
            scheduleReference: reader.optional("scheduleReference").map {
                try scheduleReference($0, path: "\(path).scheduleReference")
            },
            pendingHandoff: reader.optional("pendingHandoff").map {
                try pendingHandoff($0, path: "\(path).pendingHandoff")
            },
            staleTargetMarkedAt: reader.optional("staleTargetMarkedAt").map {
                try timestamp($0, path: "\(path).staleTargetMarkedAt")
            },
            withdrawnAt: reader.optional("withdrawnAt").map { try timestamp($0, path: "\(path).withdrawnAt") },
            scheduledTransferCancellation: reader.optional("scheduledTransferCancellation").map {
                try scheduledTransferCancellation($0, path: "\(path).scheduledTransferCancellation")
            },
            extras: reader.extras
        )
    }

    private static func scheduledTransferCancellation(
        _ json: AgentRecoveryJSONValue,
        path: String
    ) throws -> AgentRecoveryScheduledTransferCancellation {
        var reader = try Reader(json, path: path)
        return try AgentRecoveryScheduledTransferCancellation(
            decisionID: reader.uuid("decisionID"),
            scheduleID: reader.uuid("scheduleID"),
            scheduleAttemptID: reader.uuid("scheduleAttemptID"),
            recordedAt: reader.timestamp("recordedAt"),
            extras: reader.extras
        )
    }

    private static func scheduledTransferCancellationJSON(
        _ cancellation: AgentRecoveryScheduledTransferCancellation
    ) -> AgentRecoveryJSONValue {
        var object = cancellation.extras
        object["decisionID"] = .string(cancellation.decisionID.uuidString)
        object["scheduleID"] = .string(cancellation.scheduleID.uuidString)
        object["scheduleAttemptID"] = .string(cancellation.scheduleAttemptID.uuidString)
        object["recordedAt"] = timestampJSON(cancellation.recordedAt)
        return .object(object)
    }

    private static func intentJSON(_ intent: AgentRecoveryIntent) -> AgentRecoveryJSONValue {
        var object = intent.extras
        object["intentID"] = .string(intent.intentID.uuidString)
        object["userItemID"] = .string(intent.userItemID.uuidString)
        object["origin"] = .string(intent.origin.rawValue)
        object["target"] = intentTargetJSON(intent.target)
        object["createdAt"] = timestampJSON(intent.createdAt)
        object["appInstanceID"] = .string(intent.appInstanceID.uuidString)
        object["transcriptResetGeneration"] = .number(Decimal(intent.transcriptResetGeneration))
        object["deliveryState"] = .string(intent.deliveryState.rawValue)
        object["payload"] = contentJSON(intent.payload)
        if let reference = intent.scheduleReference {
            var referenceObject = reference.extras
            referenceObject["scheduleID"] = .string(reference.scheduleID.uuidString)
            referenceObject["scheduleAttemptID"] = .string(reference.scheduleAttemptID.uuidString)
            object["scheduleReference"] = .object(referenceObject)
        }
        if let pendingHandoff = intent.pendingHandoff {
            object["pendingHandoff"] = pendingHandoffJSON(pendingHandoff)
        }
        if let staleTargetMarkedAt = intent.staleTargetMarkedAt {
            object["staleTargetMarkedAt"] = timestampJSON(staleTargetMarkedAt)
        }
        if let withdrawnAt = intent.withdrawnAt {
            object["withdrawnAt"] = timestampJSON(withdrawnAt)
        }
        if let cancellation = intent.scheduledTransferCancellation {
            object["scheduledTransferCancellation"] = scheduledTransferCancellationJSON(cancellation)
        }
        return .object(object)
    }

    private static func intentTarget(_ json: AgentRecoveryJSONValue, path: String) throws -> AgentRecoveryIntentTarget {
        var reader = try Reader(json, path: path)
        let kind = try reader.string("kind")
        let liveRun: AgentRecoveryRunTarget?
        switch kind {
        case "session":
            liveRun = nil
        case "liveRun":
            var runReader = try Reader(reader.required("run"), path: "\(path).run")
            liveRun = try AgentRecoveryRunTarget(
                runAttemptID: runReader.uuid("runAttemptID"),
                processRunID: runReader.optionalUUID("processRunID"),
                providerConversationID: runReader.optionalString("providerConversationID"),
                extras: runReader.extras
            )
        default:
            throw AgentRecoveryDecodingError(reason: .unknownVariant("\(path).kind=\(kind)"))
        }
        return AgentRecoveryIntentTarget(liveRun: liveRun, extras: reader.extras)
    }

    private static func intentTargetJSON(_ target: AgentRecoveryIntentTarget) -> AgentRecoveryJSONValue {
        var object = target.extras
        if let run = target.liveRun {
            var runObject = run.extras
            runObject["runAttemptID"] = .string(run.runAttemptID.uuidString)
            setOptional(&runObject, "processRunID", run.processRunID?.uuidString)
            setOptional(&runObject, "providerConversationID", run.providerConversationID)
            object["kind"] = .string("liveRun")
            object["run"] = .object(runObject)
        } else {
            object["kind"] = .string("session")
        }
        return .object(object)
    }

    private static func scheduleReference(_ json: AgentRecoveryJSONValue, path: String) throws -> AgentRecoveryScheduleReference {
        var reader = try Reader(json, path: path)
        return try AgentRecoveryScheduleReference(
            scheduleID: reader.uuid("scheduleID"),
            scheduleAttemptID: reader.uuid("scheduleAttemptID"),
            extras: reader.extras
        )
    }

    private static func pendingHandoff(
        _ json: AgentRecoveryJSONValue,
        path: String
    ) throws -> AgentRecoveryPendingHandoffSnapshot {
        var reader = try Reader(json, path: path)
        return try AgentRecoveryPendingHandoffSnapshot(
            payloadID: reader.uuid("payloadID"),
            payload: reader.string("payload"),
            createdAt: reader.optional("createdAt").map { try timestamp($0, path: "\(path).createdAt") },
            sourceItemID: reader.optionalUUID("sourceItemID"),
            prependedText: reader.string("prependedText"),
            extras: reader.extras
        )
    }

    private static func pendingHandoffJSON(_ snapshot: AgentRecoveryPendingHandoffSnapshot) -> AgentRecoveryJSONValue {
        var object = snapshot.extras
        object["payloadID"] = .string(snapshot.payloadID.uuidString)
        object["payload"] = .string(snapshot.payload)
        if let createdAt = snapshot.createdAt {
            object["createdAt"] = timestampJSON(createdAt)
        }
        setOptional(&object, "sourceItemID", snapshot.sourceItemID?.uuidString)
        object["prependedText"] = .string(snapshot.prependedText)
        return .object(object)
    }

    private static func attempt(_ json: AgentRecoveryJSONValue, path: String) throws -> AgentRecoveryAttempt {
        var reader = try Reader(json, path: path)
        return try AgentRecoveryAttempt(
            attemptID: reader.uuid("attemptID"),
            intentID: reader.uuid("intentID"),
            userItemID: reader.uuid("userItemID"),
            runAttemptID: reader.optionalUUID("runAttemptID"),
            transcriptTurnID: reader.optionalUUID("transcriptTurnID"),
            appInstanceID: reader.uuid("appInstanceID"),
            dispatchedAt: reader.timestamp("dispatchedAt"),
            outcome: reader.optional("outcome").map { try attemptOutcome($0, path: "\(path).outcome") },
            supersededOutcome: reader.optional("supersededOutcome").map {
                try attemptOutcome($0, path: "\(path).supersededOutcome")
            },
            extras: reader.extras
        )
    }

    private static func attemptJSON(_ attempt: AgentRecoveryAttempt) -> AgentRecoveryJSONValue {
        var object = attempt.extras
        object["attemptID"] = .string(attempt.attemptID.uuidString)
        object["intentID"] = .string(attempt.intentID.uuidString)
        object["userItemID"] = .string(attempt.userItemID.uuidString)
        setOptional(&object, "runAttemptID", attempt.runAttemptID?.uuidString)
        setOptional(&object, "transcriptTurnID", attempt.transcriptTurnID?.uuidString)
        object["appInstanceID"] = .string(attempt.appInstanceID.uuidString)
        object["dispatchedAt"] = timestampJSON(attempt.dispatchedAt)
        if let outcome = attempt.outcome {
            object["outcome"] = attemptOutcomeJSON(outcome)
        }
        if let superseded = attempt.supersededOutcome {
            object["supersededOutcome"] = attemptOutcomeJSON(superseded)
        }
        return .object(object)
    }

    // MARK: Run attempts

    private static func runAttempt(_ json: AgentRecoveryJSONValue, path: String) throws -> AgentRecoveryRunAttempt {
        var reader = try Reader(json, path: path)
        return try AgentRecoveryRunAttempt(
            runAttemptID: reader.uuid("runAttemptID"),
            transcriptResetGeneration: reader.uint64("transcriptResetGeneration"),
            processRunID: reader.optionalUUID("processRunID"),
            transcriptTurnID: reader.optionalUUID("transcriptTurnID"),
            startedAt: reader.timestamp("startedAt"),
            appInstanceID: reader.optionalUUID("appInstanceID"),
            terminal: reader.optional("terminal").map { try runTerminal($0, path: "\(path).terminal") },
            shutdown: reader.optional("shutdown").map { try runShutdown($0, path: "\(path).shutdown") },
            extras: reader.extras
        )
    }

    private static func runAttemptJSON(_ run: AgentRecoveryRunAttempt) -> AgentRecoveryJSONValue {
        var object = run.extras
        object["runAttemptID"] = .string(run.runAttemptID.uuidString)
        object["transcriptResetGeneration"] = .number(Decimal(run.transcriptResetGeneration))
        setOptional(&object, "processRunID", run.processRunID?.uuidString)
        setOptional(&object, "transcriptTurnID", run.transcriptTurnID?.uuidString)
        object["startedAt"] = timestampJSON(run.startedAt)
        // Absent for a legacy attempt (unknown owner); never written as a placeholder.
        setOptional(&object, "appInstanceID", run.appInstanceID?.uuidString)
        if let terminal = run.terminal {
            var terminalObject = terminal.extras
            terminalObject["commitID"] = .string(terminal.commitID.uuidString)
            terminalObject["terminalState"] = .string(terminal.terminalState.rawValue)
            setOptional(&terminalObject, "expectedRunID", terminal.expectedRunID?.uuidString)
            terminalObject["recordedAt"] = timestampJSON(terminal.recordedAt)
            object["terminal"] = .object(terminalObject)
        }
        if let shutdown = run.shutdown {
            var shutdownObject = shutdown.extras
            shutdownObject["reason"] = .string(shutdown.reason.rawValue)
            shutdownObject["observedAt"] = timestampJSON(shutdown.observedAt)
            if let lastConfirmedActivityAt = shutdown.lastConfirmedActivityAt {
                shutdownObject["lastConfirmedActivityAt"] = timestampJSON(lastConfirmedActivityAt)
            }
            object["shutdown"] = .object(shutdownObject)
        }
        return .object(object)
    }

    private static func runTerminal(_ json: AgentRecoveryJSONValue, path: String) throws -> AgentRecoveryRunTerminalEvidence {
        var reader = try Reader(json, path: path)
        let stateRaw = try reader.string("terminalState")
        guard let state = AgentSessionRunState(rawValue: stateRaw), state.isTerminalForCommit else {
            throw AgentRecoveryDecodingError(reason: .unknownVariant("\(path).terminalState=\(stateRaw)"))
        }
        return try AgentRecoveryRunTerminalEvidence(
            commitID: reader.uuid("commitID"),
            terminalState: state,
            expectedRunID: reader.optionalUUID("expectedRunID"),
            recordedAt: reader.timestamp("recordedAt"),
            extras: reader.extras
        )
    }

    private static func runShutdown(_ json: AgentRecoveryJSONValue, path: String) throws -> AgentRecoveryRunShutdownEvidence {
        var reader = try Reader(json, path: path)
        let reasonRaw = try reader.string("reason")
        guard let reason = AgentRecoveryShutdownReason(rawValue: reasonRaw) else {
            throw AgentRecoveryDecodingError(reason: .unknownVariant("\(path).reason=\(reasonRaw)"))
        }
        return try AgentRecoveryRunShutdownEvidence(
            reason: reason,
            observedAt: reader.timestamp("observedAt"),
            lastConfirmedActivityAt: reader.optional("lastConfirmedActivityAt").map {
                try timestamp($0, path: "\(path).lastConfirmedActivityAt")
            },
            extras: reader.extras
        )
    }

    private static func attemptOutcome(_ json: AgentRecoveryJSONValue, path: String) throws -> AgentRecoveryAttemptOutcome {
        var reader = try Reader(json, path: path)
        let kind = try reader.string("kind")
        let outcome: AgentRecoveryDeliveryOutcome
        switch kind {
        case "providerAccepted":
            outcome = .providerAccepted
        case "deliveryUnknown":
            outcome = .deliveryUnknown
        case "failed":
            let failureRaw = try reader.string("failureKind")
            guard let failureKind = AgentRecoveryFailureKind(rawValue: failureRaw) else {
                throw AgentRecoveryDecodingError(reason: .unknownVariant("\(path).failureKind=\(failureRaw)"))
            }
            outcome = try .failed(failureKind, message: reader.optionalString("message"))
        default:
            throw AgentRecoveryDecodingError(reason: .unknownVariant("\(path).kind=\(kind)"))
        }
        return try AgentRecoveryAttemptOutcome(
            outcome: outcome,
            recordedAt: reader.timestamp("recordedAt"),
            extras: reader.extras
        )
    }

    private static func attemptOutcomeJSON(_ outcome: AgentRecoveryAttemptOutcome) -> AgentRecoveryJSONValue {
        var object = outcome.extras
        switch outcome.outcome {
        case .providerAccepted:
            object["kind"] = .string("providerAccepted")
        case .deliveryUnknown:
            object["kind"] = .string("deliveryUnknown")
        case let .failed(failureKind, message):
            object["kind"] = .string("failed")
            object["failureKind"] = .string(failureKind.rawValue)
            setOptional(&object, "message", message)
        }
        object["recordedAt"] = timestampJSON(outcome.recordedAt)
        return .object(object)
    }

    // MARK: Primitive helpers

    private static func setOptional(_ object: inout AgentRecoveryExtras, _ key: String, _ value: String?) {
        if let value {
            object[key] = .string(value)
        }
    }

    private static func timestampJSON(_ timestamp: AgentRecoveryTimestamp) -> AgentRecoveryJSONValue {
        .number(Decimal(timestamp.millisecondsSince1970))
    }

    private static func timestamp(_ json: AgentRecoveryJSONValue, path: String) throws -> AgentRecoveryTimestamp {
        try AgentRecoveryTimestamp(millisecondsSince1970: Reader.int64(json, path: path))
    }

    /// Reads one JSON object, tracking which members were consumed so the rest become extras.
    private struct Reader {
        private let object: [String: AgentRecoveryJSONValue]
        private let path: String
        private var consumed: Set<String> = []

        init(_ json: AgentRecoveryJSONValue, path: String) throws {
            guard case let .object(object) = json else {
                throw AgentRecoveryDecodingError(reason: .malformed("\(path) is not an object"))
            }
            self.object = object
            self.path = path
        }

        var extras: AgentRecoveryExtras {
            object.filter { !consumed.contains($0.key) }
        }

        mutating func required(_ key: String) throws -> AgentRecoveryJSONValue {
            consumed.insert(key)
            guard let value = object[key] else {
                throw AgentRecoveryDecodingError(reason: .malformed("\(path).\(key) is missing"))
            }
            return value
        }

        /// Absent means `nil`; an explicit `null` is malformed (it would not round-trip).
        mutating func optional(_ key: String) throws -> AgentRecoveryJSONValue? {
            consumed.insert(key)
            guard let value = object[key] else { return nil }
            if case .null = value {
                throw AgentRecoveryDecodingError(reason: .malformed("\(path).\(key) is null"))
            }
            return value
        }

        mutating func string(_ key: String) throws -> String {
            try Self.string(required(key), path: "\(path).\(key)")
        }

        mutating func optionalString(_ key: String) throws -> String? {
            try optional(key).map { try Self.string($0, path: "\(path).\(key)") }
        }

        mutating func uuid(_ key: String) throws -> UUID {
            try Self.uuid(required(key), path: "\(path).\(key)")
        }

        mutating func optionalUUID(_ key: String) throws -> UUID? {
            try optional(key).map { try Self.uuid($0, path: "\(path).\(key)") }
        }

        mutating func bool(_ key: String) throws -> Bool {
            guard case let .bool(value) = try required(key) else {
                throw AgentRecoveryDecodingError(reason: .malformed("\(path).\(key) is not a bool"))
            }
            return value
        }

        mutating func int(_ key: String) throws -> Int {
            let value = try Self.int64(required(key), path: "\(path).\(key)")
            guard let int = Int(exactly: value) else {
                throw AgentRecoveryDecodingError(reason: .malformed("\(path).\(key) is out of range"))
            }
            return int
        }

        mutating func uint64(_ key: String) throws -> UInt64 {
            let keyPath = "\(path).\(key)"
            let decimal = try Self.integralDecimal(required(key), path: keyPath)
            let value = NSDecimalNumber(decimal: decimal).uint64Value
            guard decimal >= 0, Decimal(value) == decimal else {
                throw AgentRecoveryDecodingError(reason: .malformed("\(keyPath) is out of range"))
            }
            return value
        }

        mutating func timestamp(_ key: String) throws -> AgentRecoveryTimestamp {
            try AgentRecoveryTimestamp(millisecondsSince1970: Self.int64(required(key), path: "\(path).\(key)"))
        }

        mutating func array(_ key: String) throws -> [AgentRecoveryJSONValue] {
            guard case let .array(values) = try required(key) else {
                throw AgentRecoveryDecodingError(reason: .malformed("\(path).\(key) is not an array"))
            }
            return values
        }

        static func string(_ json: AgentRecoveryJSONValue, path: String) throws -> String {
            guard case let .string(value) = json else {
                throw AgentRecoveryDecodingError(reason: .malformed("\(path) is not a string"))
            }
            return value
        }

        static func uuid(_ json: AgentRecoveryJSONValue, path: String) throws -> UUID {
            // Canonical uppercase spelling only, so the value re-encodes exactly.
            guard let value = try UUID(uuidString: string(json, path: path)),
                  value.uuidString == (try? string(json, path: path))
            else {
                throw AgentRecoveryDecodingError(reason: .malformed("\(path) is not a canonical UUID"))
            }
            return value
        }

        static func int64(_ json: AgentRecoveryJSONValue, path: String) throws -> Int64 {
            let decimal = try integralDecimal(json, path: path)
            let value = NSDecimalNumber(decimal: decimal).int64Value
            guard Decimal(value) == decimal else {
                throw AgentRecoveryDecodingError(reason: .malformed("\(path) is out of range"))
            }
            return value
        }

        static func integralDecimal(_ json: AgentRecoveryJSONValue, path: String) throws -> Decimal {
            guard case let .number(decimal) = json else {
                throw AgentRecoveryDecodingError(reason: .malformed("\(path) is not a number"))
            }
            var input = decimal
            var rounded = Decimal()
            NSDecimalRound(&rounded, &input, 0, .plain)
            guard rounded == decimal else {
                throw AgentRecoveryDecodingError(reason: .malformed("\(path) is not an integer"))
            }
            return decimal
        }
    }
}
