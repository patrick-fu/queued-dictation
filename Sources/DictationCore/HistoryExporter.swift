import Foundation

public struct HistoryExportSnapshot: Sendable {
    public let audio: Data?
    public let rawTranscription: String?
    public let polishedText: String?
    public let coachResult: CoachResult?

    public init(audio: Data? = nil, rawTranscription: String? = nil, polishedText: String? = nil,
                coachResult: CoachResult? = nil) {
        self.audio = audio
        self.rawTranscription = rawTranscription
        self.polishedText = polishedText
        self.coachResult = coachResult
    }
}

public enum HistoryExportItem: CaseIterable, Sendable {
    case audio, rawTranscription, polishedText, coachResult

    public var fileName: String {
        switch self {
        case .audio: "original.wav"
        case .rawTranscription: "transcription.txt"
        case .polishedText: "polished.txt"
        case .coachResult: "coach.json"
        }
    }

    public var title: String {
        switch self {
        case .audio: "原始音频"
        case .rawTranscription: "原始转写"
        case .polishedText: "润色文本"
        case .coachResult: "带教结果"
        }
    }
}

public enum HistoryExportError: Error, Equatable, LocalizedError, Sendable {
    case noProducts, unavailableItem, archiveTooLarge, cannotWrite

    public var errorDescription: String? {
        switch self {
        case .noProducts: "这条历史没有可导出的产物。"
        case .unavailableItem: "这条历史尚无所选产物，未生成空文件。"
        case .archiveTooLarge: "这条历史超过普通 ZIP 的 4 GiB 格式上限，请分别下载现有产物。"
        case .cannotWrite: "导出文件无法保存，请检查所选位置的权限和可用空间；原文件已保留。"
        }
    }
}

public enum HistoryExporter {
    public static func availableItems(in snapshot: HistoryExportSnapshot) -> [HistoryExportItem] {
        HistoryExportItem.allCases.filter { item in
            switch item {
            case .audio: snapshot.audio?.isEmpty == false
            case .rawTranscription: snapshot.rawTranscription?.isEmpty == false
            case .polishedText: snapshot.polishedText?.isEmpty == false
            case .coachResult: snapshot.coachResult != nil
            }
        }
    }

    // 调用者先从加密历史读取真实产物，并检查目标位于加密目录之外。
    public static func export(_ item: HistoryExportItem, from snapshot: HistoryExportSnapshot, to destination: URL) throws {
        try write(bytes(for: item, in: snapshot), to: destination)
    }

    public static func exportZIP(_ snapshot: HistoryExportSnapshot, to destination: URL) throws {
        try write(encodedZIP(snapshot), to: destination)
    }

    static func encodedItem(_ item: HistoryExportItem, from snapshot: HistoryExportSnapshot) throws -> Data {
        try bytes(for: item, in: snapshot)
    }

    static func encodedZIP(_ snapshot: HistoryExportSnapshot) throws -> Data {
        let items = try availableItems(in: snapshot).map { ($0.fileName, try bytes(for: $0, in: snapshot)) }
        guard !items.isEmpty else { throw HistoryExportError.noProducts }
        return try archive(items)
    }

    private static func bytes(for item: HistoryExportItem, in snapshot: HistoryExportSnapshot) throws -> Data {
        guard availableItems(in: snapshot).contains(item) else { throw HistoryExportError.unavailableItem }
        switch item {
        case .audio: return snapshot.audio!
        case .rawTranscription: return Data(snapshot.rawTranscription!.utf8)
        case .polishedText: return Data(snapshot.polishedText!.utf8)
        case .coachResult:
            let payload: CoachPayload
            switch snapshot.coachResult! {
            case .noCard: payload = CoachPayload(kind: "no_card", suggestions: nil)
            case .card(let feedback): payload = CoachPayload(kind: "card", suggestions: feedback.suggestions)
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            return try encoder.encode(payload)
        }
    }

    private struct CoachPayload: Encodable {
        let kind: String
        let suggestions: [CoachSuggestion]?
    }

    private static func write(_ data: Data, to destination: URL) throws {
        guard destination.isFileURL else { throw HistoryExportError.cannotWrite }
        do { try data.write(to: destination, options: .atomic) }
        catch { throw HistoryExportError.cannotWrite }
    }

    private static func archive(_ items: [(String, Data)]) throws -> Data {
        // 0xffffffff 是 ZIP64 哨兵。先验证完整布局，避免截断、整数转换失败或写出半个归档。
        let maximum = UInt64(UInt32.max) - 1
        var total: UInt64 = 22
        for (name, data) in items {
            guard UInt64(data.count) <= maximum else { throw HistoryExportError.archiveTooLarge }
            total += UInt64(data.count) + 30 + 46 + UInt64(name.utf8.count) * 2
            guard total <= maximum else { throw HistoryExportError.archiveTooLarge }
        }
        var archive = Data()
        archive.reserveCapacity(Int(total))
        var central = Data()
        let timestamp = dosTimestamp()
        for (name, data) in items {
            let nameBytes = Data(name.utf8)
            let offset = UInt32(archive.count)
            let size = UInt32(data.count)
            let crc = crc32(data)
            archive.zipAppend(UInt32(0x04034b50))
            archive.zipAppend(UInt16(10))
            archive.zipAppend(UInt16(0))
            archive.zipAppend(UInt16(0))
            archive.zipAppend(timestamp.time)
            archive.zipAppend(timestamp.date)
            archive.zipAppend(crc)
            archive.zipAppend(size)
            archive.zipAppend(size)
            archive.zipAppend(UInt16(nameBytes.count))
            archive.zipAppend(UInt16(0))
            archive.append(nameBytes)
            archive.append(data)

            central.zipAppend(UInt32(0x02014b50))
            central.zipAppend(UInt16(0x0314))
            central.zipAppend(UInt16(10))
            central.zipAppend(UInt16(0))
            central.zipAppend(UInt16(0))
            central.zipAppend(timestamp.time)
            central.zipAppend(timestamp.date)
            central.zipAppend(crc)
            central.zipAppend(size)
            central.zipAppend(size)
            central.zipAppend(UInt16(nameBytes.count))
            central.zipAppend(UInt16(0))
            central.zipAppend(UInt16(0))
            central.zipAppend(UInt16(0))
            central.zipAppend(UInt16(0))
            central.zipAppend(UInt32(0o100600) << 16)
            central.zipAppend(offset)
            central.append(nameBytes)
        }
        let centralOffset = UInt32(archive.count)
        archive.append(central)
        archive.zipAppend(UInt32(0x06054b50))
        archive.zipAppend(UInt16(0))
        archive.zipAppend(UInt16(0))
        archive.zipAppend(UInt16(items.count))
        archive.zipAppend(UInt16(items.count))
        archive.zipAppend(UInt32(central.count))
        archive.zipAppend(centralOffset)
        archive.zipAppend(UInt16(0))
        return archive
    }

    private static func dosTimestamp() -> (time: UInt16, date: UInt16) {
        let fields = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day, .hour, .minute, .second], from: Date())
        let year = min(2107, max(1980, fields.year ?? 1980))
        let time = (fields.hour ?? 0) << 11 | (fields.minute ?? 0) << 5 | (fields.second ?? 0) / 2
        let date = (year - 1980) << 9 | (fields.month ?? 1) << 5 | (fields.day ?? 1)
        return (UInt16(time), UInt16(date))
    }

    private static let crcTable: [UInt32] = (0..<256).map { value in
        var crc = UInt32(value)
        for _ in 0..<8 { crc = crc & 1 == 0 ? crc >> 1 : (crc >> 1) ^ 0xedb88320 }
        return crc
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var crc = UInt32.max
        for byte in data { crc = crcTable[Int((crc ^ UInt32(byte)) & 0xff)] ^ (crc >> 8) }
        return ~crc
    }
}

private extension Data {
    mutating func zipAppend<T: FixedWidthInteger>(_ value: T) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }
}
