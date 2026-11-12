import AppKit

/// Простой таймер / фокус-сессия.
@MainActor
final class FocusTimer: ObservableObject {
    enum State: Equatable {
        case idle
        case running(end: Date)
        case paused(remaining: TimeInterval)
    }

    static let presets: [(minutes: Int, hint: String)] = [
        (5, L("Short break")), (15, L("Long break")), (25, L("Focus session")), (50, L("Deep work")),
    ]

    @Published private(set) var state: State = .idle
    @Published private(set) var total: TimeInterval = 25 * 60
    @Published private(set) var now = Date()
    var onFinish: (() -> Void)?
    private var ticker: Timer?

    var remaining: TimeInterval {
        switch state {
        case .idle: return total
        case .running(let end): return max(0, end.timeIntervalSince(now))
        case .paused(let r): return r
        }
    }

    var progress: Double { total > 0 ? min(1, max(0, 1 - remaining / total)) : 0 }
    var isActive: Bool { state != .idle }
    var isRunning: Bool {
        if case .running = state { return true }
        return false
    }

    func start(minutes: Int) {
        total = TimeInterval(minutes * 60)
        now = Date()
        state = .running(end: now.addingTimeInterval(total))
        startTicker()
    }

    func togglePause() {
        switch state {
        case .running(let end):
            state = .paused(remaining: max(0, end.timeIntervalSinceNow))
            stopTicker()
        case .paused(let r):
            now = Date()
            state = .running(end: now.addingTimeInterval(r))
            startTicker()
        case .idle:
            break
        }
    }

    func addFiveMinutes() {
        switch state {
        case .running(let end): state = .running(end: end.addingTimeInterval(300)); total += 300
        case .paused(let r): state = .paused(remaining: r + 300); total += 300
        case .idle: break
        }
    }

    func stop() {
        state = .idle
        stopTicker()
    }

    private func startTicker() {
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func stopTicker() {
        ticker?.invalidate()
        ticker = nil
    }

    private func tick() {
        now = Date()
        if case .running(let end) = state, end <= now {
            stop()
            NSSound(named: NSSound.Name("Glass"))?.play()
            onFinish?()
        }
    }

    static func format(_ t: TimeInterval) -> String {
        let s = Int(ceil(t))
        return s >= 3600
            ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
            : String(format: "%d:%02d", s / 60, s % 60)
    }
}
