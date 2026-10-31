import AppKit
import ConversionKit
import Observation

@MainActor
@Observable
final class ConversionJob: Identifiable {
    enum State: Equatable {
        case waiting
        case running(progress: Double)
        case finished(output: URL, note: String?)
        case failed(message: String)
        case cancelled
    }

    let id = UUID()
    let input: URL
    let action: ConversionAction
    var state: State = .waiting
    fileprivate var task: Task<Void, Never>?

    init(input: URL, action: ConversionAction) {
        self.input = input
        self.action = action
    }

    var isActive: Bool {
        switch state {
        case .waiting, .running: true
        default: false
        }
    }
}

/// Runs conversions a few at a time and keeps a short history for the menu bar list.
@MainActor
@Observable
final class JobQueue {
    private(set) var jobs: [ConversionJob] = []
    /// Set when something failed and the person has not looked at the list since.
    var hasUnseenFailure = false
    /// Changes when a job ends, so the menu bar icon can acknowledge it.
    private(set) var lastFinishedAt: Date?
    /// Called when the queue runs dry, with what that stretch of work produced and whether anything failed.
    @ObservationIgnored var onBatchFinished: (([URL], Bool) -> Void)?

    private let settings: AppSettings
    private let historyLimit = 50
    private var batchOutputs: [URL] = []
    private var batchHadFailure = false

    init(settings: AppSettings) {
        self.settings = settings
    }

    var activeJobs: [ConversionJob] {
        jobs.filter(\.isActive)
    }

    /// Average progress of what is in flight, for the menu bar icon. Nil when idle.
    var overallProgress: Double? {
        let active = activeJobs
        guard !active.isEmpty else { return nil }
        let total = active.reduce(0.0) { sum, job in
            if case .running(let progress) = job.state { return sum + progress }
            return sum
        }
        return total / Double(active.count)
    }

    @discardableResult
    func add(_ urls: [URL], action: ConversionAction) -> [ConversionJob] {
        let new = ConversionCatalog.applicableInputs(urls, for: action).map { ConversionJob(input: $0, action: action) }
        jobs.insert(contentsOf: new.reversed(), at: 0)
        trimHistory()
        startWaitingJobs()
        return new
    }

    func cancel(_ job: ConversionJob) {
        job.task?.cancel()
        if job.state == .waiting { job.state = .cancelled }
    }

    func cancelAll() {
        jobs.filter(\.isActive).forEach(cancel)
    }

    func retry(_ job: ConversionJob) {
        remove(job)
        add([job.input], action: job.action)
    }

    func remove(_ job: ConversionJob) {
        jobs.removeAll { $0.id == job.id }
    }

    func clearFinished() {
        jobs.removeAll { !$0.isActive }
        hasUnseenFailure = false
    }

    private func trimHistory() {
        while jobs.count > historyLimit, let index = jobs.lastIndex(where: { !$0.isActive }) {
            jobs.remove(at: index)
        }
    }

    private func startWaitingJobs() {
        var running = jobs.filter { if case .running = $0.state { true } else { false } }.count
        // The list is newest first, so the oldest waiting job goes first.
        for job in jobs.reversed() where job.state == .waiting && running < settings.maximumJobs {
            running += 1
            start(job)
        }
    }

    private func start(_ job: ConversionJob) {
        job.state = .running(progress: 0)
        let options = settings.conversionOptions
        let input = job.input
        let action = job.action
        job.task = Task { [weak self] in
            let handler: ProgressHandler = { value in
                Task { @MainActor in
                    if case .running = job.state { job.state = .running(progress: value) }
                }
            }
            do {
                let result = try await Converter.run(action, on: input, options: options, progress: handler)
                job.state = .finished(output: result.output, note: result.note)
                self?.batchOutputs.append(result.output)
            } catch is CancellationError {
                job.state = .cancelled
            } catch {
                job.state = .failed(message: error.localizedDescription)
                self?.hasUnseenFailure = true
                self?.batchHadFailure = true
            }
            self?.lastFinishedAt = Date()
            self?.startWaitingJobs()
            self?.finishBatchIfIdle()
        }
    }

    private func finishBatchIfIdle() {
        guard activeJobs.isEmpty else { return }
        let outputs = batchOutputs
        let hadFailure = batchHadFailure
        batchOutputs = []
        batchHadFailure = false
        // A batch that was only cancelled has nothing to announce.
        if !outputs.isEmpty || hadFailure { onBatchFinished?(outputs, hadFailure) }
    }
}
