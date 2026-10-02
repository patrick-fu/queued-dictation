import Darwin
import Foundation
import Testing
import DictationCore

@MainActor
@Suite
struct HistoryExportBehaviorTests {
    @Test
    func allProducedArtifactsCanBeDownloadedAndOpenedByIndependentZIPReaders() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let source = ControlledMicrophone()
        let app = RecordingApplication(source: source, historyDirectory: directory.appendingPathComponent("vault"), keys: TestDataKey())
        #expect(await app.startRecording())
        let samples = Data([0x00, 0x80, 0xff, 0x7f, 0x01, 0x00, 0xff, 0xff, 0x00, 0x00, 0x34, 0x12])
        source.emit(PCMChunk(samples: samples, sampleRate: 16_000))
        await app.finishRecording()
        let entry = try #require(app.history().first)
        let original = directory.appendingPathComponent("recording.wav")
        try app.exportAudio(entry.id, to: original)
        let audio = try Data(contentsOf: original)
        let raw = "I has a café. 这是原始转写。\n🙂 e\u{301}"
        let polished = "I have a café. 这是润色文本。\n🙂 é"
        let coach = try CoachResult.validate(content: """
            {"kind":"card","suggestions":[{"category":"grammar","original":"I has","improved":"I have","reason":"主语 I 使用 have。"}]}
            """, rawText: raw)
        let snapshot = HistoryExportSnapshot(audio: audio, rawTranscription: raw, polishedText: polished, coachResult: coach)
        #expect(HistoryExporter.availableItems(in: snapshot) == [.audio, .rawTranscription, .polishedText, .coachResult])
        for item in HistoryExporter.availableItems(in: snapshot) {
            try HistoryExporter.export(item, from: snapshot, to: directory.appendingPathComponent(item.fileName))
        }
        #expect(try Data(contentsOf: directory.appendingPathComponent("original.wav")) == audio)
        #expect(try Data(contentsOf: directory.appendingPathComponent("transcription.txt")) == Data(raw.utf8))
        #expect(try Data(contentsOf: directory.appendingPathComponent("polished.txt")) == Data(polished.utf8))
        let archive = directory.appendingPathComponent("entry.zip")
        try HistoryExporter.exportZIP(snapshot, to: archive)
        try runExportTool("/usr/bin/unzip", arguments: ["-t", archive.path])
        let extracted = directory.appendingPathComponent("extracted")
        try runExportTool("/usr/bin/ditto", arguments: ["-x", "-k", archive.path, extracted.path])
        #expect(try FileManager.default.contentsOfDirectory(atPath: extracted.path).sorted() == ["coach.json", "original.wav", "polished.txt", "transcription.txt"])
        for name in ["original.wav", "transcription.txt", "polished.txt", "coach.json"] {
            #expect(try Data(contentsOf: extracted.appendingPathComponent(name)) == Data(contentsOf: directory.appendingPathComponent(name)))
        }
        try runExportTool("/usr/bin/python3", arguments: ["-c", """
            import base64, binascii, io, json, sys, wave, zipfile
            with zipfile.ZipFile(sys.argv[1]) as archive:
                assert archive.namelist() == ['original.wav', 'transcription.txt', 'polished.txt', 'coach.json']
                assert archive.testzip() is None
                for item in archive.infolist():
                    assert item.CRC == binascii.crc32(archive.read(item.filename))
                with wave.open(io.BytesIO(archive.read('original.wav'))) as audio:
                    assert (audio.getnchannels(), audio.getsampwidth(), audio.getframerate(), audio.getnframes()) == (1, 2, 16000, 6)
                    assert audio.readframes(6) == bytes.fromhex('0080ff7f0100ffff00003412')
                assert archive.read('transcription.txt') == base64.b64decode(sys.argv[2])
                assert archive.read('polished.txt') == base64.b64decode(sys.argv[3])
                assert json.loads(archive.read('coach.json')) == {'kind':'card', 'suggestions':[{'category':'grammar','original':'I has','improved':'I have','reason':'主语 I 使用 have。'}]}
            print('ZIP CRC, PCM WAV, Unicode text and coach payload verified')
            """, archive.path, Data(raw.utf8).base64EncodedString(), Data(polished.utf8).base64EncodedString()])
    }

    @Test
    func retentionDefaultsToThirtyDaysAndEverySupportedChoiceSurvivesReload() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("retention.json")
        let settings = HistoryRetentionSettings(file: file)
        #expect(try settings.load() == .days30)
        for period in [HistoryRetentionPeriod.days7, .days30, .days90, .days365, .forever] {
            try settings.save(period)
            #expect(try HistoryRetentionSettings(file: file).load() == period)
            #expect(try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? Int == 0o700)
            #expect(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int == 0o600)
        }
        #expect(try String(contentsOf: file, encoding: .utf8) == "0")
    }

    @Test
    func savingIntoAnExistingWritableDirectoryRestrictsItToOwnerAccess() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("retention.json")
        let settings = HistoryRetentionSettings(file: file)
        try settings.save(.days90)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        try settings.save(.days7)
        #expect(try settings.load() == .days7)
        #expect(try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? Int == 0o700)
        #expect(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int == 0o600)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["retention.json"])
    }

    @Test
    func everyCombinationOfProducedArtifactsHasExactlyThoseFilesInItsZIP() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let source = ControlledMicrophone()
        let app = RecordingApplication(source: source, historyDirectory: directory.appendingPathComponent("vault"), keys: TestDataKey())
        #expect(await app.startRecording())
        source.emit(testAudio())
        await app.finishRecording()
        let id = try #require(app.history().first).id
        let reference = directory.appendingPathComponent("reference.wav")
        try app.exportAudio(id, to: reference)
        let audio = try Data(contentsOf: reference)
        let raw = "实际转写 café\n"
        let polished = "实际润色 🙂\n"
        let cases: [(HistoryExportSnapshot, [String])] = [
            (.init(audio: audio), ["original.wav"]),
            (.init(rawTranscription: raw), ["transcription.txt"]),
            (.init(polishedText: polished), ["polished.txt"]),
            (.init(coachResult: .noCard), ["coach.json"]),
            (.init(audio: audio, rawTranscription: raw), ["original.wav", "transcription.txt"]),
            (.init(audio: audio, polishedText: polished), ["original.wav", "polished.txt"]),
            (.init(audio: audio, coachResult: .noCard), ["original.wav", "coach.json"]),
            (.init(rawTranscription: raw, polishedText: polished), ["transcription.txt", "polished.txt"]),
            (.init(rawTranscription: raw, coachResult: .noCard), ["transcription.txt", "coach.json"]),
            (.init(polishedText: polished, coachResult: .noCard), ["polished.txt", "coach.json"]),
            (.init(audio: audio, rawTranscription: raw, polishedText: polished), ["original.wav", "transcription.txt", "polished.txt"]),
            (.init(audio: audio, rawTranscription: raw, coachResult: .noCard), ["original.wav", "transcription.txt", "coach.json"]),
            (.init(audio: audio, polishedText: polished, coachResult: .noCard), ["original.wav", "polished.txt", "coach.json"]),
            (.init(rawTranscription: raw, polishedText: polished, coachResult: .noCard), ["transcription.txt", "polished.txt", "coach.json"]),
            (.init(audio: audio, rawTranscription: raw, polishedText: polished, coachResult: .noCard), ["original.wav", "transcription.txt", "polished.txt", "coach.json"])
        ]
        for (index, (snapshot, names)) in cases.enumerated() {
            #expect(HistoryExporter.availableItems(in: snapshot).map(\.fileName) == names)
            try HistoryExporter.exportZIP(snapshot, to: directory.appendingPathComponent("variant-\(index).zip"))
        }
        let expectedNames = try JSONEncoder().encode(cases.map { $0.1 }).base64EncodedString()
        try runExportTool("/usr/bin/python3", arguments: ["-c", """
            import base64, json, pathlib, sys, zipfile
            expected_names = json.loads(base64.b64decode(sys.argv[2]))
            expected_data = {'original.wav':base64.b64decode(sys.argv[3]), 'transcription.txt':base64.b64decode(sys.argv[4]), 'polished.txt':base64.b64decode(sys.argv[5])}
            for index, names in enumerate(expected_names):
                with zipfile.ZipFile(pathlib.Path(sys.argv[1]) / f'variant-{index}.zip') as archive:
                    assert archive.namelist() == names
                    assert archive.testzip() is None
                    for name in names:
                        if name == 'coach.json':
                            assert json.loads(archive.read(name)) == {'kind':'no_card'}
                        else:
                            assert archive.read(name) == expected_data[name]
            print('All 15 nonempty artifact combinations verified without missing-item files')
            """, directory.path, expectedNames, audio.base64EncodedString(), Data(raw.utf8).base64EncodedString(), Data(polished.utf8).base64EncodedString()])
    }

    @Test
    func missingArtifactsAndEmptySnapshotsNeverCreateOrReplaceAnExport() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent("existing.txt")
        let original = Data("用户已有文件".utf8)
        try original.write(to: destination)
        let empty = HistoryExportSnapshot(audio: Data(), rawTranscription: "", polishedText: "")
        #expect(HistoryExporter.availableItems(in: empty).isEmpty)
        #expect(throws: HistoryExportError.noProducts) { try HistoryExporter.exportZIP(empty, to: destination) }
        for item in HistoryExportItem.allCases {
            #expect(throws: HistoryExportError.unavailableItem) { try HistoryExporter.export(item, from: empty, to: destination) }
        }
        #expect(try Data(contentsOf: destination) == original)
        let missing = directory.appendingPathComponent("absent.wav")
        #expect(throws: HistoryExportError.unavailableItem) { try HistoryExporter.export(.audio, from: empty, to: missing) }
        #expect(!FileManager.default.fileExists(atPath: missing.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["existing.txt"])
    }

    @Test
    func failedExportLeavesTheExistingTargetAndNoTemporaryPlaintextFiles() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            try? FileManager.default.removeItem(at: directory)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent("entry.zip")
        let original = Data("现有目标字节".utf8)
        try original.write(to: destination)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        let snapshot = HistoryExportSnapshot(rawTranscription: "新的产物")
        #expect(throws: HistoryExportError.cannotWrite) { try HistoryExporter.exportZIP(snapshot, to: destination) }
        #expect(throws: HistoryExportError.cannotWrite) { try HistoryExporter.export(.rawTranscription, from: snapshot, to: destination) }
        #expect(try Data(contentsOf: destination) == original)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["entry.zip"])
    }

    @Test
    func zip64SizedArtifactsAreRejectedBeforeTouchingTheExistingTarget() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent("entry.zip")
        let original = Data("必须保留的原 ZIP".utf8)
        try original.write(to: destination)
        let allocation = Int(UInt32.max)
        guard let memory = mmap(nil, allocation, PROT_READ, MAP_PRIVATE | MAP_ANON, -1, 0), memory != MAP_FAILED else {
            throw POSIXError(.ENOMEM)
        }
        defer { munmap(memory, allocation) }
        for size in [allocation, allocation - 100] {
            let oversized = Data(bytesNoCopy: memory, count: size, deallocator: .none)
            #expect(throws: HistoryExportError.archiveTooLarge) {
                try HistoryExporter.exportZIP(HistoryExportSnapshot(audio: oversized), to: destination)
            }
        }
        #expect(try Data(contentsOf: destination) == original)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["entry.zip"])
    }

    @Test
    func invalidAndUnreadableRetentionSettingsDoNotBecomeDefaultsOrOverwriteTheFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("retention.json")
        let settings = HistoryRetentionSettings(file: file)
        for invalid in ["-1", "1", "14", "31", "366"] {
            let original = Data(invalid.utf8)
            try original.write(to: file)
            #expect(throws: HistoryRetentionSettingsError.invalidPeriod) { try settings.load() }
            #expect(try Data(contentsOf: file) == original)
        }
        for corrupt in ["{", "null", "\"永久\"", "{}"] {
            let original = Data(corrupt.utf8)
            try original.write(to: file)
            #expect(throws: HistoryRetentionSettingsError.unreadableConfiguration) { try settings.load() }
            #expect(try Data(contentsOf: file) == original)
        }
        try settings.save(.days90)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path) }
        #expect(throws: HistoryRetentionSettingsError.unreadableConfiguration) { try settings.load() }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        #expect(try settings.load() == .days90)
    }

    @Test(arguments: [0o500, 0o000])
    func failedRetentionSavePreservesThePriorEffectiveValueAndDirectoryPermissions(mode: Int) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            try? FileManager.default.removeItem(at: directory)
        }
        let file = directory.appendingPathComponent("retention.json")
        let settings = HistoryRetentionSettings(file: file)
        try settings.save(.days7)
        let prior = try Data(contentsOf: file)
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: directory.path)
        #expect(throws: HistoryRetentionSettingsError.cannotSave) { try settings.save(.forever) }
        #expect(try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? Int == mode)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        #expect(try settings.load() == .days7)
        #expect(try Data(contentsOf: file) == prior)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["retention.json"])
    }

    @Test
    func immutableRetentionTargetRejectsReplacementAndPreservesThePriorEffectiveValue() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("retention.json")
        let settings = HistoryRetentionSettings(file: file)
        try settings.save(.days90)
        let prior = try Data(contentsOf: file)
        guard Darwin.chflags(file.path, UInt32(UF_IMMUTABLE)) == 0 else { throw POSIXError(.EPERM) }
        defer { Darwin.chflags(file.path, 0) }
        #expect(throws: HistoryRetentionSettingsError.cannotSave) { try settings.save(.forever) }
        #expect(try settings.load() == .days90)
        #expect(try Data(contentsOf: file) == prior)
        #expect(try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? Int == 0o700)
        #expect(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int == 0o600)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["retention.json"])
    }

    @Test
    func expirationUsesTheSelectedPeriodAndProtectsUnfinishedRequestsAndFutureDates() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        for (period, days) in [(HistoryRetentionPeriod.days7, 7), (.days30, 30), (.days90, 90), (.days365, 365)] {
            let boundary = now.addingTimeInterval(-Double(days) * 86_400)
            #expect(period.shouldExpire(recordedAt: boundary, now: now, isTerminal: true, hasActiveRequest: false))
            #expect(!period.shouldExpire(recordedAt: boundary.addingTimeInterval(1), now: now, isTerminal: true, hasActiveRequest: false))
            #expect(!period.shouldExpire(recordedAt: .distantPast, now: now, isTerminal: false, hasActiveRequest: false))
            #expect(!period.shouldExpire(recordedAt: .distantPast, now: now, isTerminal: true, hasActiveRequest: true))
            #expect(!period.shouldExpire(recordedAt: now.addingTimeInterval(1), now: now, isTerminal: true, hasActiveRequest: false))
        }
        #expect(!HistoryRetentionPeriod.forever.shouldExpire(recordedAt: .distantPast, now: now, isTerminal: true, hasActiveRequest: false))
    }
}

private func runExportTool(_ executable: String, arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    let output = Pipe()
    process.standardOutput = output
    process.standardError = output
    try process.run()
    let bytes = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let message = String(decoding: bytes, as: UTF8.self)
    print("\(executable) exit \(process.terminationStatus): \(message)")
    #expect(process.terminationStatus == 0, Comment(rawValue: message))
}
