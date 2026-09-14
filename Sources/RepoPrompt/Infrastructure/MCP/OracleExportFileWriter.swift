import Foundation
import MCP

struct GeneratedOracleExportCleanupReceipt: @unchecked Sendable {
    let logicalPath: String
    fileprivate let physicalPath: String
    fileprivate let physicalRootPath: String
    fileprivate let rootID: UUID
    fileprivate let rootScope: WorkspaceLookupRootScope
}

struct GeneratedOracleExportFileWriter {
    let store: WorkspaceFileContextStore

    @discardableResult
    func write(path rawPath: String, content: String, destination: OracleExportDestination) async throws -> String {
        try await writeArtifact(
            path: rawPath,
            content: content,
            destination: destination
        ).logicalPath
    }

    func writeArtifact(
        path rawPath: String,
        content: String,
        destination: OracleExportDestination
    ) async throws -> GeneratedOracleExportCleanupReceipt {
        let logicalPath = try resolvedAbsoluteExportPath(rawPath, destination: destination)
        let physicalPath = StandardizedPath.absolute(destination.lookupContext.translateInputPath(logicalPath))
        let physicalRootPath = StandardizedPath.absolute(
            destination.lookupContext.translateInputPath(destination.primaryRootPath)
        )
        let scopedRoots = await store.rootRefs(scope: destination.lookupContext.rootScope)
        guard let scopedRoot = scopedRoots.first(where: { $0.standardizedFullPath == physicalRootPath }) else {
            throw MCPError.invalidParams(
                "Cannot create generated Oracle export at '\(logicalPath)': destination root is not loaded in the bound read_file workspace scope."
            )
        }
        guard physicalPath == scopedRoot.standardizedFullPath
            || StandardizedPath.isDescendant(physicalPath, of: scopedRoot.standardizedFullPath)
        else {
            throw MCPError.invalidParams(
                "Cannot create generated Oracle export at '\(logicalPath)': translated target path is outside the bound workspace root."
            )
        }

        let fm = FileManager.default
        guard !fm.fileExists(atPath: physicalPath) else {
            throw MCPError.invalidParams("Cannot create generated Oracle export at '\(logicalPath)': path already exists.")
        }

        let mutationService = WorkspaceFileMutationService(store: store)
        do {
            let writeResult = try await mutationService.createFileWithPostcondition(
                userPath: physicalPath,
                content: content,
                rootScope: destination.lookupContext.rootScope,
                pathResolutionPolicy: .literalPreferredIfStronger
            )

            if let reason = writeResult.catalogIneligibility {
                throw MCPError.invalidParams(
                    "Generated Oracle export was written to '\(logicalPath)', but that path is not readable by read_file because \(reason.description). Remove the workspace policy/ignore exclusion for this export path and try again."
                )
            }
            guard writeResult.materializedFile != nil else {
                throw MCPError.invalidParams(
                    "Generated Oracle export was written to '\(logicalPath)', but RepoPrompt did not add it to the workspace catalog, so read_file cannot read it."
                )
            }

            _ = await store.awaitAppliedIngressForExplicitRequest(
                userPath: physicalPath,
                fallbackScope: destination.lookupContext.rootScope
            )
            try await assertReadFileCanReadExport(
                physicalPath: physicalPath,
                logicalPath: logicalPath,
                expectedContent: content,
                rootScope: destination.lookupContext.rootScope
            )
            return GeneratedOracleExportCleanupReceipt(
                logicalPath: logicalPath,
                physicalPath: physicalPath,
                physicalRootPath: scopedRoot.standardizedFullPath,
                rootID: scopedRoot.id,
                rootScope: destination.lookupContext.rootScope
            )
        } catch let error as MCPError {
            await cleanupCreatedExportIfPresent(
                physicalPath: physicalPath,
                root: scopedRoot,
                rootScope: destination.lookupContext.rootScope
            )
            throw error
        } catch is FileManagerError {
            await cleanupCreatedExportIfPresent(
                physicalPath: physicalPath,
                root: scopedRoot,
                rootScope: destination.lookupContext.rootScope
            )
            throw MCPError.invalidParams(
                "Cannot create generated Oracle export at '\(logicalPath)': filesystem operation failed."
            )
        } catch {
            await cleanupCreatedExportIfPresent(
                physicalPath: physicalPath,
                root: scopedRoot,
                rootScope: destination.lookupContext.rootScope
            )
            throw MCPError.invalidParams(
                "Cannot create generated Oracle export at '\(logicalPath)': export creation or verification failed."
            )
        }
    }

    func remove(receipt: GeneratedOracleExportCleanupReceipt) async -> Bool {
        guard receipt.physicalPath == receipt.physicalRootPath
            || StandardizedPath.isDescendant(
                receipt.physicalPath,
                of: receipt.physicalRootPath
            )
        else { return false }

        let fm = FileManager.default
        if fm.fileExists(atPath: receipt.physicalPath) {
            do {
                try fm.removeItem(atPath: receipt.physicalPath)
            } catch {
                return false
            }
        }
        guard !fm.fileExists(atPath: receipt.physicalPath) else { return false }

        let rootStillLoaded = await store.rootRefs(scope: receipt.rootScope).contains {
            $0.id == receipt.rootID
                && $0.standardizedFullPath == receipt.physicalRootPath
        }
        if rootStillLoaded {
            let prefix = receipt.physicalRootPath.hasSuffix("/")
                ? receipt.physicalRootPath
                : receipt.physicalRootPath + "/"
            if receipt.physicalPath.hasPrefix(prefix) {
                let relativePath = StandardizedPath.relative(
                    String(receipt.physicalPath.dropFirst(prefix.count))
                )
                await store.replayObservedFileSystemDeltas(
                    rootID: receipt.rootID,
                    deltas: [.fileRemoved(relativePath)]
                )
                _ = await store.awaitAppliedIngressForExplicitRequest(
                    userPath: receipt.physicalPath,
                    fallbackScope: receipt.rootScope
                )
            }
        }
        return true
    }

    func remove(path rawPath: String, destination: OracleExportDestination) async {
        guard let logicalPath = try? resolvedAbsoluteExportPath(rawPath, destination: destination) else { return }
        let physicalPath = StandardizedPath.absolute(destination.lookupContext.translateInputPath(logicalPath))
        let physicalRootPath = StandardizedPath.absolute(
            destination.lookupContext.translateInputPath(destination.primaryRootPath)
        )
        let scopedRoots = await store.rootRefs(scope: destination.lookupContext.rootScope)
        guard let scopedRoot = scopedRoots.first(where: { $0.standardizedFullPath == physicalRootPath }),
              physicalPath == scopedRoot.standardizedFullPath
              || StandardizedPath.isDescendant(physicalPath, of: scopedRoot.standardizedFullPath)
        else { return }
        await cleanupCreatedExportIfPresent(
            physicalPath: physicalPath,
            root: scopedRoot,
            rootScope: destination.lookupContext.rootScope
        )
    }

    private func resolvedAbsoluteExportPath(_ rawPath: String, destination: OracleExportDestination) throws -> String {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw MCPError.invalidParams("Cannot create generated Oracle export: export path is empty.")
        }
        let expandedPath = (trimmed as NSString).expandingTildeInPath
        guard expandedPath.hasPrefix("/") else {
            throw MCPError.invalidParams("Cannot create generated Oracle export: generated export path must resolve to an absolute workspace path, got '\(trimmed)'.")
        }
        let resolvedPath = StandardizedPath.absolute(expandedPath)
        let rootPath = StandardizedPath.absolute(destination.primaryRootPath)
        guard resolvedPath == rootPath || StandardizedPath.isDescendant(resolvedPath, of: rootPath) else {
            throw MCPError.invalidParams("Cannot create generated Oracle export: generated path escapes the workspace primary root.")
        }
        return resolvedPath
    }

    private func cleanupCreatedExportIfPresent(
        physicalPath: String,
        root: WorkspaceRootRef,
        rootScope: WorkspaceLookupRootScope
    ) async {
        guard FileManager.default.fileExists(atPath: physicalPath) else { return }
        try? FileManager.default.removeItem(atPath: physicalPath)
        let rootPrefix = root.standardizedFullPath.hasSuffix("/") ? root.standardizedFullPath : root.standardizedFullPath + "/"
        guard physicalPath.hasPrefix(rootPrefix) else { return }
        let relativePath = StandardizedPath.relative(String(physicalPath.dropFirst(rootPrefix.count)))
        await store.replayObservedFileSystemDeltas(rootID: root.id, deltas: [.fileRemoved(relativePath)])
        _ = await store.awaitAppliedIngressForExplicitRequest(
            userPath: physicalPath,
            fallbackScope: rootScope
        )
    }

    private func assertReadFileCanReadExport(
        physicalPath: String,
        logicalPath: String,
        expectedContent: String,
        rootScope: WorkspaceLookupRootScope
    ) async throws {
        let readableService = WorkspaceReadableFileService(store: store)
        let readable = await readableService.resolveReadableFile(
            physicalPath,
            profile: .mcpRead,
            rootScope: rootScope
        )
        guard case let .workspace(file) = readable else {
            throw MCPError.invalidParams(
                "Generated Oracle export was written to '\(logicalPath)', but read_file cannot resolve that exact path in the bound workspace."
            )
        }
        guard file.standardizedFullPath == physicalPath else {
            throw MCPError.invalidParams(
                "Generated Oracle export was written to '\(logicalPath)', but read_file resolved a different workspace file."
            )
        }
        do {
            guard let loadedContent = try await store.readContent(rootID: file.rootID, relativePath: file.standardizedRelativePath) else {
                throw MCPError.invalidParams(
                    "Generated Oracle export was written to '\(logicalPath)', but read_file cannot load its contents."
                )
            }
            guard loadedContent == expectedContent else {
                throw MCPError.invalidParams(
                    "Generated Oracle export was written to '\(logicalPath)', but read_file loaded different contents."
                )
            }
        } catch let error as MCPError {
            throw error
        } catch {
            throw MCPError.invalidParams(
                "Generated Oracle export was written to '\(logicalPath)', but read_file cannot load its contents."
            )
        }
    }
}
