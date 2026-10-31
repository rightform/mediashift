import ConversionCore
import Foundation

/// Sits between raw progress numbers and the caller's handler. Values only go up, calls are
/// throttled, and nothing reaches 1 until `finish()` says the work is really done.
final class ProgressSink: @unchecked Sendable {
    private let handler: ProgressHandler?
    private let lock = NSLock()
    private var last = -1.0
    private var lastTime = Date.distantPast

    init(_ handler: ProgressHandler?) {
        self.handler = handler
    }

    func report(_ value: Double) {
        guard let handler else { return }
        let clamped = min(max(value, 0), 0.999)
        lock.lock()
        let now = Date()
        let isFirst = last < 0
        let moved = clamped - last
        let due = moved >= 0.005 || (moved > 0 && now.timeIntervalSince(lastTime) >= 0.25)
        if isFirst || due {
            last = clamped
            lastTime = now
            lock.unlock()
            handler(clamped)
        } else {
            lock.unlock()
        }
    }

    func finish() {
        handler?(1)
    }

    /// A reporter that maps 0...1 onto part of the whole, for work done in several steps.
    func scaled(to range: ClosedRange<Double>) -> @Sendable (Double) -> Void {
        { [self] value in
            report(range.lowerBound + min(max(value, 0), 1) * (range.upperBound - range.lowerBound))
        }
    }
}
