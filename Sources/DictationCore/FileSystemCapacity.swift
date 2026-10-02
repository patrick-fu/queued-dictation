import Foundation

public enum FileSystemCapacity {
    public static func availableBytes(at url: URL) throws -> UInt64 {
        var path = url
        while !FileManager.default.fileExists(atPath: path.path), path.path != "/" {
            path.deleteLastPathComponent()
        }
        let attributes = try FileManager.default.attributesOfFileSystem(forPath: path.path)
        guard let value = attributes[.systemFreeSize] as? NSNumber else { throw DictationError.storageUnavailable }
        return value.uint64Value
    }
}
