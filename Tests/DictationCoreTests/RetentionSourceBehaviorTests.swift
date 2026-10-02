import Foundation
import Testing
import DictationCore

@MainActor
@Suite
struct RetentionSourceBehaviorTests {
    @Test(arguments: ["30.0000000000000001", "7.000000000000000000000000000000000000001",
                      "3.000000000000000000000000000000000000001e1"])
    func nonintegerSourceIsRejectedWithoutChangingTheOriginalFile(source: String) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("retention.json")
        let original = Data(source.utf8)
        try original.write(to: file)
        #expect(throws: HistoryRetentionSettingsError.invalidPeriod) { try HistoryRetentionSettings(file: file).load() }
        #expect(try Data(contentsOf: file) == original)
    }

    @Test
    func mathematicalIntegersAndTheSingleNumericSaveFormatRemainUsable() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("retention.json")
        let settings = HistoryRetentionSettings(file: file)
        #expect(try settings.load() == .days30)
        for (period, saved) in [(HistoryRetentionPeriod.days7, "7"), (.days30, "30"), (.days90, "90"), (.days365, "365"), (.forever, "0")] {
            try settings.save(period)
            #expect(try Data(contentsOf: file) == Data(saved.utf8))
            #expect(try settings.load() == period)
        }
        let variants: [(String, HistoryRetentionPeriod)] = [
            ("7.0", .days7), ("3e1", .days30), ("30.000000000000000000000000000000000000000", .days30),
            ("0.7e1", .days7), ("3650e-1", .days365), ("0e-10", .forever), ("-0", .forever)
        ]
        for (source, expected) in variants {
            let original = Data(source.utf8)
            try original.write(to: file)
            #expect(try settings.load() == expected)
            #expect(try Data(contentsOf: file) == original)
        }
    }

    @Test(arguments: ["0e9223372036854775808", "0.0e-9223372036854775808"])
    func mathematicalZeroRemainsForeverWhenItsExponentExceedsMachineArithmetic(source: String) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("retention.json")
        let original = Data(source.utf8)
        #expect(try JSONDecoder().decode(Int.self, from: original) == 0)
        try original.write(to: file)
        #expect(try HistoryRetentionSettings(file: file).load() == .forever)
        #expect(try Data(contentsOf: file) == original)
    }

    @Test(arguments: [String.Encoding.utf8, .utf16, .utf16LittleEndian, .utf16BigEndian, .utf32LittleEndian, .utf32BigEndian])
    func systemSupportedJSONEncodingsKeepWholeNumbersAndRejectFractionalSources(encoding: String.Encoding) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("retention.json")
        let settings = HistoryRetentionSettings(file: file)
        for (source, expected) in [("7", HistoryRetentionPeriod.days7), ("0", .forever), ("3e1", .days30)] {
            let original = try #require(source.data(using: encoding))
            #expect(try JSONDecoder().decode(Int.self, from: original) == expected.rawValue)
            try original.write(to: file)
            #expect(try settings.load() == expected)
            #expect(try Data(contentsOf: file) == original)
        }
        let fractional = try #require("7.000000000000000000000000000000000000001".data(using: encoding))
        try fractional.write(to: file)
        #expect(throws: HistoryRetentionSettingsError.invalidPeriod) { try settings.load() }
        #expect(try Data(contentsOf: file) == fractional)
    }

    @Test
    func invalidSourcesStayRejectedAndBOMEncodingsKeepTheirOriginalBytes() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("retention.json")
        let settings = HistoryRetentionSettings(file: file)
        let badSources = [Data(), Data([0xff]), Data("[30]".utf8), Data("\"30\"".utf8), Data("true".utf8), Data("30.".utf8), Data("0.000000000000000000000000000000000000001".utf8)]
        for original in badSources {
            #expect(throws: (any Error).self) { try JSONDecoder().decode(Int.self, from: original) }
            try original.write(to: file)
            #expect(throws: HistoryRetentionSettingsError.unreadableConfiguration) { try settings.load() }
            #expect(try Data(contentsOf: file) == original)
        }
        let bom = Data([0xef, 0xbb, 0xbf]) + Data("30".utf8)
        #expect(try JSONDecoder().decode(Int.self, from: bom) == 30)
        try bom.write(to: file)
        #expect(try settings.load() == .days30)
        #expect(try Data(contentsOf: file) == bom)
        let utf32BOM = try #require("7".data(using: .utf32))
        try utf32BOM.write(to: file)
        if (try? JSONDecoder().decode(Int.self, from: utf32BOM)) == 7 {
            #expect(try settings.load() == .days7)
        } else {
            #expect(throws: HistoryRetentionSettingsError.unreadableConfiguration) { try settings.load() }
        }
        #expect(try Data(contentsOf: file) == utf32BOM)
    }

    @Test
    func coachRootObjectConcurrencyKeepsItsExactSourceCheck() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("coach.json")
        let settings = CoachSettings(file: file)
        for (token, valid) in [("3.000000000000000000000000000000000000001", false), ("0.3e1", true)] {
            let original = Data(#"{"enabled":false,"\u0063oncurrency":\#(token),"timeout":30.5,"corner":"bottomRight","ignored":{"concurrency":3.000000000000000000000000000000000000001}}"#.utf8)
            try original.write(to: file)
            if valid {
                let loaded = try settings.load()
                #expect(loaded.concurrency == 3 && loaded.timeout == 30.5)
            } else {
                #expect(throws: CoachFailure.invalidConfiguration) { try settings.load() }
            }
            #expect(try Data(contentsOf: file) == original)
        }
    }
}
