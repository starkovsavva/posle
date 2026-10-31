import AfterLocalization
import AfterPlatform
import Foundation
import Darwin

private final class WorkerEventResult: @unchecked Sendable {
    private let lock = NSLock()
    private var result: WorkerEvent?
    func record(_ event: WorkerEvent) {
        guard event.event == "done" else { return }
        lock.lock(); result = event; lock.unlock()
    }
    var value: WorkerEvent? { lock.lock(); defer { lock.unlock() }; return result }
}

/// One execution owns one child, even if cancellation arrives after a newer
/// request has started. No callbacks execute while the state lock is held.
private final class WorkerExecution: @unchecked Sendable {
    let process = Process()
    private let lock = NSLock()
    private var cancelled = false
    private var started = false
    private var finished = false
    private var escalationScheduled = false

    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }

    func start() throws {
        lock.lock(); defer { lock.unlock() }
        guard !cancelled else { throw CancellationError() }
        try process.run()
        started = true
    }

    func cancel() {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        cancelled = true
        let running = started && process.isRunning
        let schedule = running && !escalationScheduled
        if schedule { escalationScheduled = true }
        lock.unlock()
        if running { process.terminate() }
        if schedule {
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) { [self] in
                lock.lock(); defer { lock.unlock() }
                guard !finished, cancelled, started, process.isRunning else { return }
                // Only this execution's still-running child is eligible. A
                // later run never shares its Process instance or cancellation.
                _ = Darwin.kill(process.processIdentifier, SIGKILL)
            }
        }
    }

    func finish() { lock.lock(); finished = true; lock.unlock() }
}

/// Drain both pipes concurrently, retaining at most one bounded JSONL frame.
/// Admission is exclusive; a subprocess never runs on the main thread.
package final class ProcessRunner: @unchecked Sendable {
    // Actual workers return bounded previews/plans or model inventories. Keep
    // generous headroom above their limits without accepting an endless line.
    private static let maximumFrameBytes = 16 * 1024 * 1024
    private let lock = NSLock()
    private var active: WorkerExecution?
    private var cancelled = false

    package init() {}

    package func resetCancellation() { lock.lock(); cancelled = false; lock.unlock() }

    package func cancel() {
        lock.lock(); cancelled = true; let current = active; lock.unlock()
        current?.cancel()
    }

    private func admit() throws -> WorkerExecution {
        lock.lock(); defer { lock.unlock() }
        guard active == nil else {
            throw AppError.message(L("Дождитесь завершения текущей обработки или записи."))
        }
        guard !cancelled else { throw CancellationError() }
        let execution = WorkerExecution(); active = execution
        return execution
    }

    private func release(_ execution: WorkerExecution) {
        lock.lock(); defer { lock.unlock() }
        if active === execution { active = nil }
    }

    @discardableResult
    package func run(_ executable: URL, arguments: [String], environment: [String: String] = [:], input: Data? = nil,
             event: @escaping @Sendable (WorkerEvent) -> Void) async throws -> WorkerEvent? {
        try Task.checkCancellation()
        let execution = try admit()
        defer { release(execution) }
        return try await withTaskCancellationHandler {
          try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<WorkerEvent?, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let completion = WorkerEventResult()
                let process = execution.process
                let output = Pipe(), errors = Pipe()
                process.executableURL = executable
                process.arguments = arguments
                let inputPipe = input.map { _ in Pipe() }
                if let inputPipe { _ = fcntl(inputPipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) }
                process.standardInput = inputPipe ?? FileHandle.nullDevice as Any
                process.standardOutput = output; process.standardError = errors
                process.environment = ProcessEnvironment.withoutSecrets(ProcessInfo.processInfo.environment).merging(environment) { _, new in new }
                do { try execution.start() }
                catch {
                    try? inputPipe?.fileHandleForWriting.close()
                    execution.finish(); continuation.resume(throwing: error); return
                }
                // Read stderr even when noisy downloads/ffmpeg fill the OS pipe buffer.
                let group = DispatchGroup()
                if let input, let inputPipe {
                    group.enter()
                    DispatchQueue.global(qos: .utility).async {
                        defer { try? inputPipe.fileHandleForWriting.close(); group.leave() }
                        try? inputPipe.fileHandleForWriting.write(contentsOf: input)
                    }
                }
                let diagnostic = LockedTail()
                group.enter()
                DispatchQueue.global(qos: .utility).async {
                    while true {
                        let data = errors.fileHandleForReading.availableData
                        if data.isEmpty { break }
                        diagnostic.append(data)
                    }
                    group.leave()
                }
                var pending = Data()
                var lastFailure: WorkerFailure?
                var protocolFailure: WorkerFailure?
                func deliver(_ data: Data) {
                    guard !execution.isCancelled else { return }
                    if let decoded = try? JSONDecoder().decode(WorkerEvent.self, from: data) {
                        if decoded.event == "error", let message = decoded.message {
                            lastFailure = WorkerFailure(message: message, chatGPTDiagnostics: decoded.chatGPTDiagnostics)
                        }
                        completion.record(decoded)
                        event(decoded)
                    } else if let line = String(data: data, encoding: .utf8), !line.isEmpty {
                        event(WorkerEvent(event: "progress", message: String(line.suffix(240))))
                    }
                }
                func append(_ fragment: Data.SubSequence) -> Bool {
                    guard fragment.count <= Self.maximumFrameBytes - pending.count else {
                        protocolFailure = WorkerFailure(message: L("Ответ обработчика превышает допустимый размер. Повторите операцию с меньшим объёмом данных."))
                        pending.removeAll(keepingCapacity: false)
                        execution.cancel()
                        return false
                    }
                    pending.append(contentsOf: fragment)
                    return true
                }
                while true {
                    let data = output.fileHandleForReading.availableData
                    if data.isEmpty { break }
                    // After a protocol failure, keep draining without retaining
                    // any more bytes so neither pipe can block child teardown.
                    guard protocolFailure == nil, !execution.isCancelled else {
                        pending.removeAll(keepingCapacity: false)
                        continue
                    }
                    var offset = data.startIndex
                    while let newline = data[offset...].firstIndex(of: 10) {
                        guard append(data[offset..<newline]) else { break }
                        deliver(pending)
                        pending.removeAll(keepingCapacity: true)
                        offset = data.index(after: newline)
                    }
                    if protocolFailure == nil { _ = append(data[offset...]) }
                }
                if protocolFailure == nil, !pending.isEmpty { deliver(pending) }
                process.waitUntilExit()
                group.wait()
                let wasCancelled = execution.isCancelled
                execution.finish()
                if let protocolFailure { continuation.resume(throwing: protocolFailure) }
                else if wasCancelled { continuation.resume(throwing: CancellationError()) }
                else if process.terminationStatus == 0 { continuation.resume(returning: completion.value) }
                else {
                    let fallback = process.terminationReason == .uncaughtSignal
                        ? L("Обработка остановлена. Исходная запись сохранена.")
                        : LF("Не удалось завершить обработку. {0}", arguments: [String(describing: diagnostic.text)])
                    continuation.resume(throwing: lastFailure ?? WorkerFailure(message: fallback, chatGPTDiagnostics: nil))
                }
            }
          }
        } onCancel: {
            execution.cancel()
        }
    }
}

private final class LockedTail: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func append(_ value: Data) {
        lock.lock(); defer { lock.unlock() }
        data.append(value)
        if data.count > 2000 { data = data.suffix(2000) }
    }
    var text: String {
        lock.lock(); defer { lock.unlock() }
        return String(data: data, encoding: .utf8) ?? L("Откройте настройки и проверьте установку моделей.")
    }
}
