import Foundation

// 未发送的角色继续等待；已发失败不进入这个错误分支。
enum PendingDispatchWait: Error { case network, retryAfter }

enum RetryAfter: Sendable {
    case seconds(TimeInterval), date(Date)

    static func from(_ response: HTTPURLResponse) -> RetryAfter? {
        guard [429, 503].contains(response.statusCode),
              let header = response.value(forHTTPHeaderField: "Retry-After"), header.utf8.count <= 256 else { return nil }
        let value = header.trimmingCharacters(in: .whitespaces)
        if !value.isEmpty, value.utf8.allSatisfy({ (48...57).contains($0) }), let seconds = Double(value), seconds.isFinite {
            return .seconds(seconds)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.isLenient = false
        for format in ["EEE',' dd MMM yyyy HH':'mm':'ss 'GMT'", "EEEE',' dd-MMM-yy HH':'mm':'ss 'GMT'", "EEE MMM d HH':'mm':'ss yyyy"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: value), date.timeIntervalSince1970.isFinite { return .date(date) }
        }
        return nil
    }
}

@MainActor
final class DispatchBackoff {
    var onReady: (() -> Void)?
    private let network: any NetworkAvailabilityProviding
    private let timing: any RequestTiming
    private let now: () -> Date
    private struct Scope: Hashable {
        let id: UUID
        let baseURL: String
        init(_ service: ModelService) {
            id = service.id
            baseURL = service.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
    }
    private var deadlines: [Scope: TimeInterval] = [:]
    private var wakeup: Task<Void, Never>?
    private var wakeupIdentity = UUID()

    init(network: any NetworkAvailabilityProviding, timing: any RequestTiming, now: @escaping () -> Date) {
        self.network = network; self.timing = timing; self.now = now
        network.onChange = { [weak self] in self?.onReady?() }
    }

    func require(_ service: ModelService) throws {
        guard let url = URL(string: service.baseURL), network.isAvailable(for: url) else { throw PendingDispatchWait.network }
        let scope = Scope(service)
        if let deadline = deadlines[scope], deadline > timing.instant {
            scheduleWakeup()
            throw PendingDispatchWait.retryAfter
        }
        deadlines[scope] = nil
    }

    func record(_ retryAfter: RetryAfter?, for service: ModelService) {
        guard let retryAfter else { return }
        let interval: TimeInterval
        switch retryAfter {
        case .seconds(let seconds): interval = seconds
        case .date(let date): interval = max(0, date.timeIntervalSince(now()))
        }
        guard interval.isFinite, interval >= 0 else { return }
        let sum = timing.instant + interval
        let deadline = sum.isFinite ? sum : Double.greatestFiniteMagnitude
        let scope = Scope(service)
        deadlines[scope] = max(deadlines[scope] ?? 0, deadline)
        scheduleWakeup()
    }

    func stopWakeups() {
        wakeupIdentity = UUID(); wakeup?.cancel(); wakeup = nil
    }

    private func scheduleWakeup() {
        stopWakeups()
        deadlines = deadlines.filter { $0.value > timing.instant }
        guard let earliest = deadlines.values.min() else { return }
        // 有效的大延迟不能截短后放行；分段唤醒避免超出系统 sleep 的有限范围。
        let deadline = min(earliest, timing.instant + 86_400)
        let identity = wakeupIdentity
        wakeup = Task { @MainActor [weak self] in
            guard let self else { return }
            do { try await self.timing.wait(until: deadline) } catch { return }
            guard !Task.isCancelled, self.wakeupIdentity == identity else { return }
            self.wakeup = nil
            self.scheduleWakeup()
            self.onReady?()
        }
    }
}
