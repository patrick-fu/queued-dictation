import Darwin
import Foundation

final class HistoryExportOperation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var worker: Task<Void, Error>?

    func attach(_ task: Task<Void, Error>) {
        let stop = lock.withLock { worker = task; return cancelled }
        if stop { task.cancel() }
    }

    func cancel() {
        let task = lock.withLock { cancelled = true; return worker }
        task?.cancel()
    }

    func write(_ data: Data, to destination: URL, vault: URL) throws {
        guard destination.isFileURL else { throw HistoryExportError.cannotWrite }
        let pending = destination.deletingLastPathComponent().appendingPathComponent(".history-export-\(UUID()).tmp")
        defer { try? FileManager.default.removeItem(at: pending) }
        try Task.checkCancellation()
        try data.write(to: pending, options: .atomic)
        try Task.checkCancellation()
        // 取消只与最后的 rename 互斥；认证、编码和长文件写入均不阻塞主线程。
        try lock.withLock {
            guard !cancelled else { throw CancellationError() }
            try Task.checkCancellation()
            let root = vault.standardizedFileURL.resolvingSymlinksInPath().path
            let output = destination.standardizedFileURL.resolvingSymlinksInPath().path
            guard output != root, !output.hasPrefix(root + "/") else { throw DictationError.unsafeExportDestination }
            guard rename(pending.path, destination.path) == 0 else { throw HistoryExportError.cannotWrite }
        }
    }
}
