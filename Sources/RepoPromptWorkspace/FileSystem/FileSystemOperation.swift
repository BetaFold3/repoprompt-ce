import Foundation

class FileSystemOperation: Operation, @unchecked Sendable {
    let fileSystemService: FileSystemService

    init(fileSystemService: FileSystemService) {
        self.fileSystemService = fileSystemService
        super.init()
    }

    func createFile(atRelativePath relativePath: String, content: String) async throws {
        try await fileSystemService.createFile(atRelativePath: relativePath, content: content)
    }

    func editFile(atRelativePath relativePath: String, newContent: String) async throws {
        try await fileSystemService.editFile(atRelativePath: relativePath, newContent: newContent)
    }

    func deleteFile(atRelativePath relativePath: String) async throws {
        try await fileSystemService.deleteFile(atRelativePath: relativePath)
    }
}
