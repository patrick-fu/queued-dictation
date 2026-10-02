import CryptoKit
import Darwin
import Foundation

public struct FavoriteFeedback: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let createdAt: Date
    public let sourceSegmentID: UUID?
    public let rawText: String
    public let polishedText: String?
    public let feedback: CoachFeedback

    public init(id: UUID = UUID(), createdAt: Date = Date(), sourceSegmentID: UUID? = nil,
                rawText: String, polishedText: String? = nil, feedback: CoachFeedback) {
        self.id = id; self.createdAt = createdAt; self.sourceSegmentID = sourceSegmentID
        self.rawText = rawText; self.polishedText = polishedText; self.feedback = feedback
    }
}

public enum FavoritesError: Error, Equatable, LocalizedError, Sendable {
    case invalidSnapshot, missingFavorite, unreadableFavorites, dataKeyUnavailable, storageUnavailable
    case localStorageLimit, diskSpaceLow, unsafeExportDestination

    public var errorDescription: String? {
        switch self {
        case .invalidSnapshot: "没有可收藏的完整带教建议，或对应文本超过大小限制。"
        case .missingFavorite: "找不到这条带教收藏。"
        case .unreadableFavorites: "无法解密本地收藏。原数据已保留，请恢复原本地数据密钥。"
        case .dataKeyUnavailable: "无法取得本地数据密钥。原收藏已保留，请恢复钥匙串访问。"
        case .storageUnavailable: "无法安全保存或读取收藏，请检查磁盘和数据目录。"
        case .localStorageLimit: "本地数据空间额度不足，无法新增收藏。请先导出或主动删除不需要的数据。"
        case .diskSpaceLow: "真实磁盘空间不足，无法为收藏加密保存保留安全余量。"
        case .unsafeExportDestination: "请选择本地加密数据目录以外的位置下载收藏。"
        }
    }
}

@MainActor
public final class FavoritesStore {
    public let vaultRoot: URL
    public var onChange: (() -> Void)?
    private let keys: any LocalDataKeyProviding
    private let maximumLocalBytes: () throws -> UInt64
    private let diskSpace: (URL) throws -> UInt64
    private let reservedBytes: () throws -> UInt64
    private var key: SymmetricKey?
    private let files = FileManager.default
    private let magic = Data("QDENC1".utf8)
    private let maximumEncodedBytes = 4 * 1_024 * 1_024
    private let finalizationReserve: UInt64 = 1_024 * 1_024
    private let diskReserve: UInt64 = 64 * 1_024 * 1_024
    private var directory: URL { vaultRoot.appendingPathComponent("favorites", isDirectory: true) }

    public init(vaultRoot: URL, keys: any LocalDataKeyProviding,
                maximumLocalBytes: @escaping () throws -> UInt64 = { 5 * 1_024 * 1_024 * 1_024 },
                diskSpace: @escaping (URL) throws -> UInt64 = { try FileSystemCapacity.availableBytes(at: $0) },
                reservedBytes: @escaping () throws -> UInt64 = { 0 }) {
        self.vaultRoot = vaultRoot.standardizedFileURL; self.keys = keys
        self.maximumLocalBytes = maximumLocalBytes; self.diskSpace = diskSpace; self.reservedBytes = reservedBytes
    }

    public func save(_ favorite: FavoriteFeedback) throws {
        try validate(favorite)
        let encoded = try JSONEncoder().encode(favorite)
        guard encoded.count <= maximumEncodedBytes else { throw FavoritesError.invalidSnapshot }
        try requireCapacity(for: UInt64(encoded.count + magic.count + 28))
        try open()
        try secureDirectory(vaultRoot)
        try secureDirectory(directory)
        let target = path(favorite.id)
        if try footprintIfPresent(target) != nil { _ = try entry(favorite.id) }
        try writeEncrypted(encoded, to: target, context: "\(favorite.id)/favorite-v1")
        onChange?()
    }

    public func entries() throws -> [FavoriteFeedback] {
        guard !(try contents(vaultRoot)).isEmpty else { return [] }
        try open()
        return try contents(directory).filter { !$0.lastPathComponent.hasPrefix(".") }.map { url in
            guard url.pathExtension == "enc", let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent) else {
                throw FavoritesError.unreadableFavorites
            }
            return try entry(id)
        }.sorted { $0.createdAt != $1.createdAt ? $0.createdAt > $1.createdAt : $0.id.uuidString > $1.id.uuidString }
    }

    public func entry(_ id: UUID) throws -> FavoriteFeedback {
        guard !(try contents(vaultRoot)).isEmpty else { throw FavoritesError.missingFavorite }
        try open()
        _ = try contents(directory)
        let url = path(id)
        guard try footprintIfPresent(url) != nil else { throw FavoritesError.missingFavorite }
        do {
            let favorite = try JSONDecoder().decode(FavoriteFeedback.self, from: read(url, context: "\(id)/favorite-v1"))
            guard favorite.id == id else { throw FavoritesError.unreadableFavorites }
            try validate(favorite)
            return favorite
        } catch { throw FavoritesError.unreadableFavorites }
    }

    public func delete(_ id: UUID) throws {
        _ = try entry(id)
        do { try files.removeItem(at: path(id)) }
        catch { throw FavoritesError.storageUnavailable }
        onChange?()
    }

    public func text(_ id: UUID) throws -> String {
        let favorite = try entry(id)
        var sections = ["带教收藏", "收藏时间：\(favorite.createdAt.formatted(date: .numeric, time: .shortened))",
                        "原始转写\n\(favorite.rawText)"]
        if let polished = favorite.polishedText { sections.append("润色文本\n\(polished)") }
        for (index, suggestion) in favorite.feedback.suggestions.enumerated() {
            let category: String
            switch suggestion.category.rawValue {
            case "grammar": category = "语法"
            case "expression": category = "表达"
            case "fluency": category = "流利度"
            default: category = suggestion.category.rawValue
            }
            var lines = ["建议 \(index + 1) · \(category)"]
            if !suggestion.original.isEmpty { lines.append("原表达：\(suggestion.original)") }
            lines.append("改进：\(suggestion.improved)")
            lines.append("原因：\(suggestion.reason)")
            sections.append(lines.joined(separator: "\n"))
        }
        return sections.joined(separator: "\n\n") + "\n"
    }

    public func exportText(_ id: UUID, to destination: URL) throws {
        try requireSafeExport(destination)
        try Data(text(id).utf8).write(to: destination, options: .atomic)
    }

    public func exportJSON(_ id: UUID, to destination: URL) throws {
        try requireSafeExport(destination)
        let favorite = try entry(id)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .secondsSince1970
        try encoder.encode(favorite).write(to: destination, options: .atomic)
    }

    public func bytesConsumed() throws -> UInt64 {
        _ = try contents(vaultRoot)
        return try contents(directory).reduce(UInt64(0)) { total, url in
            let (next, overflow) = total.addingReportingOverflow(try footprint(url))
            guard !overflow else { throw FavoritesError.storageUnavailable }
            return next
        }
    }

    private func validate(_ favorite: FavoriteFeedback) throws {
        guard favorite.createdAt.timeIntervalSinceReferenceDate.isFinite,
              CoachSettings.validText(favorite.rawText, maximumBytes: 256 * 1_024),
              favorite.polishedText.map({ CoachSettings.validText($0, maximumBytes: 256 * 1_024) }) ?? true,
              (1...2).contains(favorite.feedback.suggestions.count),
              favorite.feedback.suggestions.allSatisfy({ suggestion in
                  suggestion.original.utf8.count <= 8_192 && (suggestion.original.isEmpty || CoachSettings.validText(suggestion.original, maximumBytes: 8_192))
                    && CoachSettings.validText(suggestion.improved, maximumBytes: 8_192)
                    && CoachSettings.validText(suggestion.reason, maximumBytes: 8_192)
              }) else { throw FavoritesError.invalidSnapshot }
    }

    private func open() throws {
        let existing = !(try contents(vaultRoot)).isEmpty
        if key == nil {
            let bytes: Data
            do { bytes = try keys.loadKey(createIfMissing: !existing) }
            catch { throw FavoritesError.dataKeyUnavailable }
            guard bytes.count == 32 else { throw FavoritesError.dataKeyUnavailable }
            key = SymmetricKey(data: bytes)
        }
        do {
            let marker = vaultRoot.appendingPathComponent("vault.enc")
            if existing {
                guard try read(marker, context: "vault-v1") == Data("queued-dictation-vault-1".utf8) else {
                    throw FavoritesError.unreadableFavorites
                }
            } else {
                try secureDirectory(vaultRoot)
                try writeEncrypted(Data("queued-dictation-vault-1".utf8), to: marker, context: "vault-v1")
            }
        } catch {
            key = nil
            if let error = error as? FavoritesError { throw error }
            throw FavoritesError.storageUnavailable
        }
    }

    private func writeEncrypted(_ data: Data, to target: URL, context: String) throws {
        guard let key else { throw FavoritesError.dataKeyUnavailable }
        let sealed = try AES.GCM.seal(data, using: key, authenticating: Data(context.utf8))
        guard let combined = sealed.combined else { throw FavoritesError.storageUnavailable }
        let ciphertext = magic + combined
        try requireCapacity(for: UInt64(ciphertext.count))
        let staging = target.deletingLastPathComponent().appendingPathComponent(".\(UUID()).enc-tmp")
        defer { try? files.removeItem(at: staging) }
        // 只将密文写入 0600 临时文件；完成权限、真实占用检查后才原子替换已有收藏。
        let descriptor = Darwin.open(staging.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw FavoritesError.storageUnavailable }
        var closed = false
        defer { if !closed { Darwin.close(descriptor) } }
        guard fchmod(descriptor, 0o600) == 0 else { throw FavoritesError.storageUnavailable }
        try ciphertext.withUnsafeBytes { pointer in
            guard let base = pointer.baseAddress else { throw FavoritesError.storageUnavailable }
            var offset = 0
            while offset < pointer.count {
                let count = Darwin.write(descriptor, base.advanced(by: offset), pointer.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw FavoritesError.storageUnavailable }
                offset += count
            }
        }
        guard fsync(descriptor) == 0 else { throw FavoritesError.storageUnavailable }
        let closeResult = Darwin.close(descriptor)
        closed = true
        guard closeResult == 0 else { throw FavoritesError.storageUnavailable }
        _ = try footprint(staging)
        try requireCapacity(for: 0)
        guard rename(staging.path, target.path) == 0 else { throw FavoritesError.storageUnavailable }
    }

    private func read(_ url: URL, context: String) throws -> Data {
        guard let key else { throw FavoritesError.dataKeyUnavailable }
        do {
            var measured = url
            measured.removeAllCachedResourceValues()
            let info = try measured.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
            guard info.isRegularFile == true, info.isSymbolicLink != true,
                  let size = info.fileSize, size >= magic.count + 28, size <= maximumEncodedBytes + magic.count + 28 else {
                throw FavoritesError.unreadableFavorites
            }
            let ciphertext = try Data(contentsOf: measured)
            guard ciphertext.starts(with: magic) else { throw FavoritesError.unreadableFavorites }
            let box = try AES.GCM.SealedBox(combined: ciphertext.dropFirst(magic.count))
            return try AES.GCM.open(box, using: key, authenticating: Data(context.utf8))
        } catch { throw FavoritesError.unreadableFavorites }
    }

    private func requireCapacity(for additional: UInt64) throws {
        let used = try vaultBytes(), limit = try maximumLocalBytes(), reserved = try reservedBytes()
        guard used <= limit, reserved <= limit - used, additional <= limit - used - reserved,
              finalizationReserve <= limit - used - reserved - additional else { throw FavoritesError.localStorageLimit }
        let (withReserve, firstOverflow) = additional.addingReportingOverflow(finalizationReserve)
        let (needed, secondOverflow) = withReserve.addingReportingOverflow(reserved)
        let (diskNeeded, thirdOverflow) = needed.addingReportingOverflow(diskReserve)
        guard !firstOverflow, !secondOverflow, !thirdOverflow,
              try diskSpace(vaultRoot) >= diskNeeded else { throw FavoritesError.diskSpaceLow }
    }

    private func vaultBytes() throws -> UInt64 {
        guard !(try contents(vaultRoot)).isEmpty else { return 0 }
        var enumerationFailed = false, total: UInt64 = 0
        guard let iterator = files.enumerator(at: vaultRoot,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey],
            errorHandler: { _, _ in enumerationFailed = true; return false }) else { throw FavoritesError.storageUnavailable }
        for case let url as URL in iterator {
            let info = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
            guard info.isSymbolicLink != true else { throw FavoritesError.storageUnavailable }
            if info.isRegularFile == true {
                let (next, overflow) = total.addingReportingOverflow(try footprint(url))
                guard !overflow else { throw FavoritesError.storageUnavailable }
                total = next
            } else if info.isDirectory != true { throw FavoritesError.storageUnavailable }
        }
        guard !enumerationFailed else { throw FavoritesError.storageUnavailable }
        return total
    }

    private func footprint(_ url: URL) throws -> UInt64 {
        var measured = url
        measured.removeAllCachedResourceValues()
        let info = try measured.resourceValues(forKeys: [.fileSizeKey, .totalFileAllocatedSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard info.isRegularFile == true, info.isSymbolicLink != true,
              let size = info.fileSize, let allocated = info.totalFileAllocatedSize, size >= 0, allocated >= 0 else {
            throw FavoritesError.storageUnavailable
        }
        return UInt64(max(size, allocated))
    }

    private func footprintIfPresent(_ url: URL) throws -> UInt64? {
        do { return try footprint(url) }
        catch let error as NSError where error.domain == NSCocoaErrorDomain && (error.code == NSFileNoSuchFileError || error.code == NSFileReadNoSuchFileError) { return nil }
    }

    private func contents(_ directory: URL) throws -> [URL] {
        do {
            let info = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard info.isDirectory == true, info.isSymbolicLink != true else { throw FavoritesError.storageUnavailable }
            return try files.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        } catch let error as NSError {
            if error.domain == NSCocoaErrorDomain, error.code == NSFileNoSuchFileError || error.code == NSFileReadNoSuchFileError { return [] }
            throw FavoritesError.storageUnavailable
        }
    }

    private func secureDirectory(_ directory: URL) throws {
        do {
            _ = try contents(directory)
            if files.fileExists(atPath: directory.path), !files.isWritableFile(atPath: directory.path) {
                throw FavoritesError.storageUnavailable
            }
            try files.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        } catch { throw FavoritesError.storageUnavailable }
    }

    private func requireSafeExport(_ destination: URL) throws {
        guard destination.isFileURL else { throw FavoritesError.unsafeExportDestination }
        let root = vaultRoot.standardizedFileURL.resolvingSymlinksInPath()
        let candidate = destination.standardizedFileURL.resolvingSymlinksInPath()
        guard candidate.path != root.path, !candidate.path.hasPrefix(root.path + "/") else { throw FavoritesError.unsafeExportDestination }
        if let rootIdentity = try root.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier as? NSObject {
            var ancestor = candidate.deletingLastPathComponent()
            while true {
                if let identity = try ancestor.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier as? NSObject,
                   rootIdentity.isEqual(identity) { throw FavoritesError.unsafeExportDestination }
                if ancestor.path == "/" { break }
                ancestor.deleteLastPathComponent()
            }
        }
    }

    private func path(_ id: UUID) -> URL { directory.appendingPathComponent("\(id).enc") }
}
