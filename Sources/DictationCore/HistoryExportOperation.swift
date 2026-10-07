import Darwin
import Foundation

final class HistoryExportOperation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var worker: Task<Void, Error>?
    private let preparedOutput: LocalExportFile?

    init() { preparedOutput = nil }

    init(destination: URL, vault: URL) throws {
        guard destination.isFileURL else { throw HistoryExportError.cannotWrite }
        do { preparedOutput = try LocalExportFile(destination: destination, vault: vault) }
        catch LocalExportError.unsafeDestination { throw DictationError.unsafeExportDestination }
        catch LocalExportError.cannotWrite { throw HistoryExportError.cannotWrite }
    }

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
        try Task.checkCancellation()
        do {
            let output = try preparedOutput ?? LocalExportFile(destination: destination, vault: vault)
            try output.write(data)
            try Task.checkCancellation()
            // 取消只与最后的提交互斥；认证、编码和长文件写入均不阻塞主线程。
            try lock.withLock {
                guard !cancelled else { throw CancellationError() }
                try Task.checkCancellation()
                try output.commit()
            }
        } catch LocalExportError.unsafeDestination { throw DictationError.unsafeExportDestination }
        catch LocalExportError.cannotWrite { throw HistoryExportError.cannotWrite }
    }
}
