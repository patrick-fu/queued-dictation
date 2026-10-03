import Foundation
import Testing
import DictationCore

@MainActor
@Suite
struct ResourceSettingsBehaviorTests {
    @Test
    func savedResourceLimitsRemainExactWhenSettingsAreReopened() throws {
        let fixture = try ResourceSettingsFixture()
        defer { fixture.remove() }
        let configuration = ResourceConfiguration(
            maximumPendingSegments: 47,
            maximumPendingDuration: 1_800.125,
            maximumPendingAudioBytes: 100_663_297,
            maximumRecordingDuration: 300.75,
            maximumLocalBytes: 6_442_450_945,
            automaticSendingWindow: 86_400.25
        )

        try fixture.settings.save(configuration)

        #expect(try ResourceSettings(file: fixture.file).load() == configuration)
    }

    @Test
    func savedSettingsAreOnlyAccessibleByTheirOwner() throws {
        let fixture = try ResourceSettingsFixture()
        defer { fixture.remove() }

        try fixture.settings.save(ResourceConfiguration())

        let folder = try FileManager.default.attributesOfItem(atPath: fixture.file.deletingLastPathComponent().path)
        let file = try FileManager.default.attributesOfItem(atPath: fixture.file.path)
        #expect((folder[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        #expect((file[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test
    func invalidLimitsNeverReplaceTheLastSavedConfiguration() throws {
        let fixture = try ResourceSettingsFixture()
        defer { fixture.remove() }
        let previous = ResourceConfiguration(maximumPendingSegments: 17, maximumRecordingDuration: 67.1)
        try fixture.settings.save(previous)
        let saved = try Data(contentsOf: fixture.file)
        let invalid = [
            ResourceConfiguration(maximumPendingSegments: 0),
            ResourceConfiguration(maximumPendingSegments: 101),
            ResourceConfiguration(maximumPendingDuration: 59.99),
            ResourceConfiguration(maximumPendingDuration: 7_200.01),
            ResourceConfiguration(maximumPendingDuration: .nan),
            ResourceConfiguration(maximumPendingDuration: .infinity),
            ResourceConfiguration(maximumPendingAudioBytes: 67_108_863),
            ResourceConfiguration(maximumPendingAudioBytes: 2_147_483_649),
            ResourceConfiguration(maximumPendingAudioBytes: .max),
            ResourceConfiguration(maximumRecordingDuration: 59.99),
            ResourceConfiguration(maximumRecordingDuration: 3_600.01),
            ResourceConfiguration(maximumRecordingDuration: .nan),
            ResourceConfiguration(maximumRecordingDuration: -.infinity),
            ResourceConfiguration(maximumLocalBytes: 1_073_741_823),
            ResourceConfiguration(maximumLocalBytes: 107_374_182_401),
            ResourceConfiguration(maximumLocalBytes: .max),
            ResourceConfiguration(automaticSendingWindow: 3_599.99),
            ResourceConfiguration(automaticSendingWindow: 604_800.01),
            ResourceConfiguration(automaticSendingWindow: .nan),
            ResourceConfiguration(automaticSendingWindow: .infinity)
        ]

        for configuration in invalid {
            #expect(throws: (any Error).self) { try fixture.settings.save(configuration) }
            #expect(try Data(contentsOf: fixture.file) == saved)
            #expect(try fixture.settings.load() == previous)
        }
    }

    @Test
    func onlyMissingSettingsUseTheSpecificationDefaults() throws {
        let fixture = try ResourceSettingsFixture()
        defer { fixture.remove() }

        let initial = try fixture.settings.load()
        #expect(initial.maximumPendingSegments == 20)
        #expect(initial.maximumPendingDuration == 1_800)
        #expect(initial.maximumPendingAudioBytes == 268_435_456)
        #expect(initial.maximumRecordingDuration == 300)
        #expect(initial.maximumLocalBytes == 5_368_709_120)
        #expect(initial.automaticSendingWindow == 86_400)
        #expect(!FileManager.default.fileExists(atPath: fixture.file.path))

        try FileManager.default.createDirectory(at: fixture.file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let unusable = [
            Data("not JSON".utf8),
            Data("{}".utf8),
            Data(#"{"maximumPendingSegments":101,"maximumPendingDuration":1800,"maximumPendingAudioBytes":268435456,"maximumRecordingDuration":300,"maximumLocalBytes":5368709120,"automaticSendingWindow":86400}"#.utf8),
            Data(#"{"maximumPendingSegments":1.5,"maximumPendingDuration":1800,"maximumPendingAudioBytes":268435456,"maximumRecordingDuration":300,"maximumLocalBytes":5368709120,"automaticSendingWindow":86400}"#.utf8)
        ]
        for bytes in unusable {
            try bytes.write(to: fixture.file)
            #expect(throws: (any Error).self) { try fixture.settings.load() }
            #expect(try Data(contentsOf: fixture.file) == bytes)
        }
    }

    @Test
    func rawFractionalCountsAndBytesAreRejectedWithoutChangingTheSourceFile() throws {
        let fixture = try ResourceSettingsFixture()
        defer { fixture.remove() }
        try fixture.settings.save(ResourceConfiguration())
        let variants: [(count: String, pending: String, local: String, failure: ResourceSettingsError)] = [
            ("1.0000000000000001", "67108864", "1073741824", .invalidPendingSegments),
            ("17", "67108864.0000000001", "1073741824", .invalidPendingAudioBytes),
            ("17", "67108864", "1073741824.00000001", .invalidLocalBytes),
            ("100.00000000000000000001", "67108864", "1073741824", .invalidPendingSegments),
            ("17", "2147483648.0000000001", "1073741824", .invalidPendingAudioBytes),
            ("17", "67108864", "107374182400.0000000001", .invalidLocalBytes),
            ("1.000000000000000000000000000000000000001", "67108864", "1073741824", .invalidPendingSegments),
            ("17", "67108864.000000000000000000000000000000001", "1073741824", .invalidPendingAudioBytes),
            ("17", "67108864", "1073741824.000000000000000000000000000001", .invalidLocalBytes)
        ]
        for variant in variants {
            let raw = Data("{\"maximumPendingSegments\":\(variant.count),\"maximumPendingDuration\":1800,\"maximumPendingAudioBytes\":\(variant.pending),\"maximumRecordingDuration\":300,\"maximumLocalBytes\":\(variant.local),\"automaticSendingWindow\":86400}".utf8)
            try raw.write(to: fixture.file)

            #expect(throws: variant.failure) { try fixture.settings.load() }
            #expect(try Data(contentsOf: fixture.file) == raw)
        }
    }

    @Test
    func escapedRootIntegerKeysCannotHideFractionalValues() throws {
        let fixture = try ResourceSettingsFixture()
        defer { fixture.remove() }
        try fixture.settings.save(ResourceConfiguration())
        let raw = Data(#"{"\u006daximumPendingSegments":1.000000000000000000000000000000000000001,"maximumPendingDuration":1800,"maximumPendingAudioBytes":67108864,"maximumRecordingDuration":300,"maximumLocalBytes":1073741824,"automaticSendingWindow":86400}"#.utf8)
        try raw.write(to: fixture.file)

        #expect(throws: ResourceSettingsError.invalidPendingSegments) { try fixture.settings.load() }
        #expect(try Data(contentsOf: fixture.file) == raw)
    }

    @Test(arguments: ["0.1e1", "1.0"])
    func wholeScientificCountsAndBytesStillLoadWithFractionalTimesAndUnrelatedText(countToken: String) throws {
        let fixture = try ResourceSettingsFixture()
        defer { fixture.remove() }
        try fixture.settings.save(ResourceConfiguration())
        let raw = Data(#"{"\u006daximumPendingSegments":\#(countToken),"maximumPendingDuration":61.125,"maximumPendingAudioBytes":671088650e-1,"maximumRecordingDuration":67.1,"maximumLocalBytes":1073741825.0000000000000000000000000000000000000000000,"automaticSendingWindow":3600.25,"ignored":{"maximumPendingSegments":1.000000000000000000000000000000000000001},"description":"\"maximumPendingAudioBytes\":67108864.000000000000000000000000000000001"}"#.utf8)
        try raw.write(to: fixture.file)

        let configuration = try fixture.settings.load()

        #expect(configuration == ResourceConfiguration(maximumPendingSegments: 1, maximumPendingDuration: 61.125,
                                                       maximumPendingAudioBytes: 67_108_865, maximumRecordingDuration: 67.1,
                                                       maximumLocalBytes: 1_073_741_825, automaticSendingWindow: 3_600.25))
        #expect(try Data(contentsOf: fixture.file) == raw)
        try fixture.settings.save(configuration)
        #expect(try ResourceSettings(file: fixture.file).load() == configuration)
    }

    @Test
    func automaticSendingExpiresAfterTheRecordingEndOrExplicitRenewalWindow() throws {
        let configuration = ResourceConfiguration()
        let recordingEndedAt = Date(timeIntervalSince1970: 300)

        #expect(try !configuration.isAutomaticSendingExpired(recordingEndedAt: recordingEndedAt,
                                                            now: Date(timeIntervalSince1970: 86_699.5)))
        #expect(try !configuration.isAutomaticSendingExpired(recordingEndedAt: recordingEndedAt,
                                                            now: Date(timeIntervalSince1970: 86_700)))
        #expect(try configuration.isAutomaticSendingExpired(recordingEndedAt: recordingEndedAt,
                                                           now: Date(timeIntervalSince1970: 86_700.5)))

        let renewedAt = Date(timeIntervalSince1970: 172_800)
        #expect(try !configuration.isAutomaticSendingExpired(recordingEndedAt: recordingEndedAt, renewedAt: renewedAt,
                                                            now: Date(timeIntervalSince1970: 259_200)))
        #expect(try configuration.isAutomaticSendingExpired(recordingEndedAt: recordingEndedAt, renewedAt: renewedAt,
                                                           now: Date(timeIntervalSince1970: 259_200.5)))
        #expect(throws: (any Error).self) {
            try configuration.isAutomaticSendingExpired(recordingEndedAt: Date(timeIntervalSince1970: .nan),
                                                        now: Date(timeIntervalSince1970: 86_700))
        }
    }

    @Test
    func savedFractionalLimitsConvertForTheExistingQueueAndRecorder() throws {
        let fixture = try ResourceSettingsFixture()
        defer { fixture.remove() }
        try fixture.settings.save(ResourceConfiguration(maximumPendingSegments: 9,
                                                       maximumPendingDuration: 61.125,
                                                       maximumPendingAudioBytes: 67_108_865,
                                                       maximumRecordingDuration: 67.1,
                                                       maximumLocalBytes: 1_073_741_825))
        let saved = try fixture.settings.load()

        let queue = try saved.queueLimits
        let recording = try saved.recordingLimits

        #expect(queue.maximumPendingSegments == 9)
        #expect(queue.maximumPendingDuration == 61.125)
        #expect(queue.maximumPendingAudioBytes == 67_108_865)
        #expect(recording.maximumDuration == 67.1)
        #expect(recording.maximumLocalBytes == 1_073_741_825)
        #expect(throws: ResourceSettingsError.invalidPendingSegments) {
            try ResourceConfiguration(maximumPendingSegments: 101).queueLimits
        }
        #expect(throws: ResourceSettingsError.invalidLocalBytes) {
            try ResourceConfiguration(maximumLocalBytes: .max).recordingLimits
        }
    }

    @Test
    func directoryPermissionFailureKeepsThePreviousConfigurationAndCanBeRetried() throws {
        let fixture = try ResourceSettingsFixture()
        defer { fixture.remove() }
        let previous = ResourceConfiguration(maximumPendingSegments: 17)
        let replacement = ResourceConfiguration(maximumPendingSegments: 63)
        try fixture.settings.save(previous)
        let saved = try Data(contentsOf: fixture.file)
        let folder = fixture.file.deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path) }

        #expect(throws: ResourceSettingsError.cannotSave) { try fixture.settings.save(replacement) }
        #expect(try Data(contentsOf: fixture.file) == saved)
        #expect(try ResourceSettings(file: fixture.file).load() == previous)
        let attributes = try FileManager.default.attributesOfItem(atPath: folder.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o500)

        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        try fixture.settings.save(replacement)
        #expect(try ResourceSettings(file: fixture.file).load() == replacement)
    }

    @Test
    func everySpecificationEndpointCanBeSavedWithoutClamping() throws {
        let fixture = try ResourceSettingsFixture()
        defer { fixture.remove() }
        let endpoints = [
            ResourceConfiguration(maximumPendingSegments: 1, maximumPendingDuration: 60,
                                  maximumPendingAudioBytes: 67_108_864, maximumRecordingDuration: 60,
                                  maximumLocalBytes: 1_073_741_824, automaticSendingWindow: 3_600),
            ResourceConfiguration(maximumPendingSegments: 100, maximumPendingDuration: 7_200,
                                  maximumPendingAudioBytes: 2_147_483_648, maximumRecordingDuration: 3_600,
                                  maximumLocalBytes: 107_374_182_400, automaticSendingWindow: 604_800)
        ]
        for configuration in endpoints {
            try fixture.settings.save(configuration)
            #expect(try ResourceSettings(file: fixture.file).load() == configuration)
        }
    }

    @Test
    func unreadableSettingsNeverFallBackToDefaultsOrReplaceTheirContents() throws {
        let fixture = try ResourceSettingsFixture()
        defer { fixture.remove() }
        let previous = ResourceConfiguration(maximumPendingSegments: 73)
        try fixture.settings.save(previous)
        let saved = try Data(contentsOf: fixture.file)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: fixture.file.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fixture.file.path) }

        #expect(throws: ResourceSettingsError.unreadableConfiguration) { try fixture.settings.load() }

        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fixture.file.path)
        #expect(try Data(contentsOf: fixture.file) == saved)
        #expect(try ResourceSettings(file: fixture.file).load() == previous)
    }

    @Test
    func aNonFileURLCannotOverwriteAMatchingLocalConfigurationPath() throws {
        let fixture = try ResourceSettingsFixture()
        defer { fixture.remove() }
        try fixture.settings.save(ResourceConfiguration(maximumPendingSegments: 23))
        let saved = try Data(contentsOf: fixture.file)
        let remote = try #require(URL(string: "http://127.0.0.1" + fixture.file.path))

        #expect(throws: ResourceSettingsError.cannotSave) {
            try ResourceSettings(file: remote).save(ResourceConfiguration(maximumPendingSegments: 71))
        }
        #expect(try Data(contentsOf: fixture.file) == saved)
    }
}

@MainActor
private struct ResourceSettingsFixture {
    let root: URL
    let file: URL
    let settings: ResourceSettings

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("queued-dictation-resource-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        file = root.appendingPathComponent("settings/resource-settings.json")
        settings = ResourceSettings(file: file)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}
