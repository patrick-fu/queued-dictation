import Foundation
import Testing
import DictationCore

@Suite(.serialized)
@MainActor
struct HistoryLifecycleBehaviorTests {
    @Test
    func realManualPolishAndIndependentCoachRemainProtectedUntilExplicitDeletion() async throws {
        let f = try ArtifactFixture(polishEnabled: false, coachEnabled: true)
        defer { f.remove() }
        let id = try await f.record()
        f.server.reply(try await f.request(.asr), object: ["text": "Keep actual unfinished feedback."])
        let coach = try await f.request(.coach)
        try f.polishSettings.save(.init(enabled: true))
        try f.app.repolish(id)
        #expect(try f.app.history().first?.polish?.status == .waitingForConfiguration)
        f.clock.date.addTimeInterval(31 * 86_400)
        #expect(try f.app.history().contains { $0.id == id })
        #expect(!f.server.disconnected(coach))
        #expect(f.app.coachScheduler?.inFlightCount == 1)
        try f.app.deleteHistory(id)
        try await artifactWait { f.server.disconnected(coach) }
        #expect(try f.app.history().isEmpty)
    }

    @Test
    func skippedMainWithAbandonedPolishShouldExpire() async throws {
        let f = try ArtifactFixture(polishEnabled: true, coachEnabled: false)
        defer { f.remove() }
        try f.polishSettings.save(.init(enabled: true))
        let id = try await f.record()
        f.server.reply(try await f.request(.asr), object: ["text": "Skip the abandoned polish request."])
        try await artifactWait { (try? f.app.history().first?.polish?.status) == .waitingForConfiguration }
        try f.app.skipMainDelivery(id)
        let completed = try #require(f.app.history().first)
        #expect(completed.disposition == .completed && completed.delivery == .skipped)
        #expect(f.app.mainRequestBudget.activeCount == 0)
        f.clock.date.addTimeInterval(31 * 86_400)
        let retained = try f.app.history()
        print("PROBE skipped-polish retained=\(retained.count) disposition=\(completed.disposition.rawValue) delivery=\(completed.delivery!.rawValue) polish=\(completed.polish!.status.rawValue) activeMain=\(f.app.mainRequestBudget.activeCount) requests=\(f.server.requests.count)")
        #expect(retained.isEmpty, "Explicitly skipped main work without a coach should obey the selected retention period.")
    }

    @Test
    func successfulCancellationAfterUnsavedCoachFailureShouldExpire() async throws {
        let f = try ArtifactFixture(polishEnabled: false, coachEnabled: true)
        defer { f.remove() }
        let id = try await f.record()
        f.server.reply(try await f.request(.asr), object: ["text": "I go yesterday."])
        let request = try await f.request(.coach)
        f.capacity.bytes = 0
        f.server.replyChat(request, content: "{\"kind\":\"card\",\"suggestions\":[{\"category\":\"grammar\",\"original\":\"go\",\"improved\":\"went\",\"reason\":\"Use the past tense for yesterday.\"}]}")
        try await artifactWait { (try? f.app.history().first?.coach?.failure) == .storageFailure }
        f.capacity.bytes = 100 * 1_024 * 1_024 * 1_024
        try f.app.cancelRecordedSegment(id)
        let cancelled = try #require(f.app.history().first)
        #expect(cancelled.disposition == .cancelled)
        #expect(f.app.coachScheduler?.pendingCount == 0 && f.app.coachScheduler?.inFlightCount == 0)
        f.clock.date.addTimeInterval(31 * 86_400)
        let retained = try f.app.history()
        #expect(retained.isEmpty, "A persisted successful explicit cancellation must not be protected forever by a stale unsaved failure overlay.")
        let restarted = RecordingApplication(source: ArtifactMicrophone(), historyDirectory: f.history, keys: TestDataKey(), now: { f.clock.date })
        let freshCount = try restarted.history().count
        print("PROBE cancelled-unsaved retained=\(retained.count) disposition=\(cancelled.disposition.rawValue) displayedCoach=\(cancelled.coach!.status.rawValue) activeCoach=\(f.app.coachScheduler!.inFlightCount) pendingCoach=\(f.app.coachScheduler!.pendingCount) freshCount=\(freshCount) requests=\(f.server.requests.count)")
        #expect(freshCount == 0)
    }

    @Test
    func clearingExpiredRowsWithSynchronousHistoryRefreshShouldSucceed() async throws {
        let f = try ArtifactFixture(polishEnabled: false, coachEnabled: false)
        defer { f.remove() }
        for ordinal in 0..<2 {
            let id = try await f.record()
            f.server.reply(try await f.request(.asr, ordinal: ordinal), object: ["text": "Completed row \(ordinal)."])
            try await artifactWait { (try? f.app.history().first { $0.id == id }?.disposition) == .completed }
        }
        f.clock.date.addTimeInterval(31 * 86_400)
        var recursiveReads = 0
        f.app.onChange = {
            recursiveReads += 1
            if recursiveReads < 8 { _ = try? f.app.history() }
        }
        var error: String?
        do { try f.app.clearHistory() } catch let failure { error = String(describing: failure) }
        f.app.onChange = nil
        let remaining = try f.app.history().count
        print("PROBE clear-reentrant error=\(error ?? "none") remaining=\(remaining) recursiveReads=\(recursiveReads) requests=\(f.server.requests.count)")
        #expect(error == nil, "A synchronous UI refresh must not make clearHistory fail after successful deletion.")
        #expect(remaining == 0)
    }
}
