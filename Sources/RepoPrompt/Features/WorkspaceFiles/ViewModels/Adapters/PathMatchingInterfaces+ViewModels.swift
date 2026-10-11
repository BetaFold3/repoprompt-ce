import Foundation

extension FrozenFileRecord {
    /// Internal convenience initializer from a FileViewModel
    init(from vm: FileViewModel) {
        name = vm.name
        relativePath = vm.relativePath
        fullPath = vm.standardizedFullPath
        rootFolderPath = vm.standardizedRootFolderPath
    }
}

extension FrozenFolderRecord {
    /// Internal convenience initializer from a FolderViewModel
    init(from vm: FolderViewModel) {
        name = vm.name
        displayName = vm.name
        relativePath = vm.relativePath
        fullPath = vm.standardizedFullPath
        rootPath = (vm.rootPath as NSString).standardizingPath
    }
}
