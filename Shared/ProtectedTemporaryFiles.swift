import Foundation

nonisolated enum ProtectedTemporaryFiles {
    static func prepareDirectory(_ directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        try protect(directory)
    }

    static func protect(_ original: URL) throws {
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: original.path)
        var url = original
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
    }

    static func ownedFile(_ path: String, in directory: URL) -> URL? {
        let file = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        let root = directory.standardizedFileURL.resolvingSymlinksInPath().path
        return file.path.hasPrefix(root + "/") ? file : nil
    }
}
