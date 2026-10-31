import Foundation

/// Runs blocking work on its own threads instead of Swift's small cooperative pool.
///
/// ImageIO's HEIC and AVIF encoders hand tiles to dispatch queues and then wait for them. If every
/// cooperative thread is stuck waiting like that, the tiles never run and the app stalls for good.
func offloaded<T>(_ work: @escaping () throws -> T) async throws -> T {
    let job = UncheckedSendable(work)
    let result = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UncheckedSendable<T>, any Error>) in
        OffloadQueue.shared.async {
            continuation.resume(with: Result { UncheckedSendable(try job.value()) })
        }
    }
    return result.value
}

/// Carries a value across threads when the caller guarantees nobody else touches it meanwhile.
private struct UncheckedSendable<Value>: @unchecked Sendable {
    let value: Value

    init(_ value: Value) {
        self.value = value
    }
}

private enum OffloadQueue {
    static let shared = DispatchQueue(label: "MediaEngine.offloaded", qos: .userInitiated, attributes: .concurrent)
}
