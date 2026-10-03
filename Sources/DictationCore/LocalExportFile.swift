import Darwin
import Foundation

enum LocalExportError: Error { case unsafeDestination, cannotWrite }

final class LocalExportFile {
    private let parent: URL
    private let vault: URL
    private let name: String
    private var directory: Int32 = -1
    private var pending: String?

    init(destination: URL, vault: URL) throws {
        guard destination.isFileURL else { throw LocalExportError.unsafeDestination }
        parent = destination.deletingLastPathComponent().standardizedFileURL
        self.vault = vault.standardizedFileURL
        name = destination.lastPathComponent
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0") else {
            throw LocalExportError.cannotWrite
        }
        let resolved = parent.resolvingSymlinksInPath()
        try requireOutsideVault(resolved)
        directory = Darwin.open(resolved.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw LocalExportError.cannotWrite }
        do { try validateDirectory() }
        catch { Darwin.close(directory); directory = -1; throw error }
    }

    deinit {
        if let pending { unlinkat(directory, pending, 0) }
        if directory >= 0 { Darwin.close(directory) }
    }

    func write(_ data: Data) throws {
        try validateDirectory()
        let temporary = ".local-export-\(UUID()).tmp"
        let descriptor = openat(directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw LocalExportError.cannotWrite }
        pending = temporary
        var closed = false
        defer { if !closed { Darwin.close(descriptor) } }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if written < 0 && errno == EINTR { continue }
                guard written > 0 else { throw LocalExportError.cannotWrite }
                offset += written
            }
        }
        guard fsync(descriptor) == 0 else { throw LocalExportError.cannotWrite }
        let result = Darwin.close(descriptor)
        closed = true
        guard result == 0 else { throw LocalExportError.cannotWrite }
    }

    func commit() throws {
        try validateDirectory()
        guard let pending else { throw LocalExportError.cannotWrite }
        // 两个相对路径共享同一已核验目录句柄，链接变化不能重定向 rename 或清理。
        guard renameat(directory, pending, directory, name) == 0 else { throw LocalExportError.cannotWrite }
        self.pending = nil
    }

    private func validateDirectory() throws {
        var actual = stat(), selected = stat()
        guard fstat(directory, &actual) == 0, actual.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else {
            throw LocalExportError.cannotWrite
        }
        var bytes = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(directory, F_GETPATH, &bytes) == 0 else { throw LocalExportError.cannotWrite }
        let actualPath = bytes.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        let actualURL = URL(fileURLWithPath: actualPath, isDirectory: true)
        try requireOutsideVault(actualURL)
        let currentParent = parent.resolvingSymlinksInPath()
        try requireOutsideVault(currentParent)
        guard fstatat(AT_FDCWD, currentParent.path, &selected, 0) == 0,
              selected.st_dev == actual.st_dev, selected.st_ino == actual.st_ino,
              faccessat(directory, ".", W_OK | X_OK, 0) == 0 else { throw LocalExportError.cannotWrite }
    }

    private func requireOutsideVault(_ directory: URL) throws {
        let root = vault.resolvingSymlinksInPath()
        let path = directory.standardizedFileURL.path
        guard path != root.path, !path.hasPrefix(root.path + "/") else { throw LocalExportError.unsafeDestination }
        var rootInfo = stat()
        guard fstatat(AT_FDCWD, root.path, &rootInfo, 0) == 0 else { throw LocalExportError.cannotWrite }
        var ancestor = directory
        while true {
            var info = stat()
            guard fstatat(AT_FDCWD, ancestor.path, &info, 0) == 0 else { throw LocalExportError.cannotWrite }
            guard info.st_dev != rootInfo.st_dev || info.st_ino != rootInfo.st_ino else {
                throw LocalExportError.unsafeDestination
            }
            if ancestor.path == "/" { break }
            ancestor.deleteLastPathComponent()
        }
    }
}
