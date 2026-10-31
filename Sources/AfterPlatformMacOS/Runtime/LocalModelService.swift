import AfterLocalization
import AfterPlatform
import Foundation
import AfterCore

@MainActor
package final class LocalModelService {
    private var process: Process?
    private var generation = UUID()
    private var port = 11436
    private var externalURL: String?
    package var baseURL: String { externalURL ?? "http://127.0.0.1:\(port)" }
    private let session: URLSession
    package init(session: URLSession? = nil) {
        if let session { self.session = session }
        else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.connectionProxyDictionary = [:]
            configuration.timeoutIntervalForRequest = 2
            self.session = URLSession(configuration: configuration)
        }
    }

    package static func validatedEndpoint(_ value: String) throws -> String {
        guard let url = URL(string: value), let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == "http", let host = components.host?.lowercased(),
              ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host),
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              components.port.map({ (1...65535).contains($0) }) ?? true,
              ["", "/"].contains(components.path) else {
            throw AppError.message(L("Укажите локальный адрес сервера без /v1, например http://127.0.0.1:1234. Номер порта должен быть от 1 до 65535."))
        }
        var clean = components
        clean.path = ""
        guard let endpoint = clean.string else { throw AppError.message(L("Проверьте адрес локального сервера.")) }
        return endpoint
    }

    package func ensure(root: URL, settings: AppSettings, cancelled: @MainActor () -> Bool = { false }) async throws {
        // A request cancelled before admission cannot supersede another startup.
        try Task.checkCancellation()
        guard !cancelled() else { throw AppError.message(L("Обработка остановлена. Запись сохранена.")) }
        let token = UUID(); generation = token
        func checkCurrent() throws {
            try Task.checkCancellation()
            guard generation == token else { throw CancellationError() }
            guard !cancelled() else { throw AppError.message(L("Обработка остановлена. Запись сохранена.")) }
        }
        try checkCurrent()
        if settings.localProvider != "managed" {
            guard ["ollama", "lmstudio"].contains(settings.localProvider) else {
                throw AppError.message(L("Выберите After, Ollama или LM Studio в настройках."))
            }
            stopProcess()
            externalURL = try Self.validatedEndpoint(settings.resolvedLocalEndpoint)
            // Rust checks connection, HTTP errors and the actual selected model.
            // This service owns only the managed process; external servers are untouched.
            try checkCurrent()
            return
        }
        externalURL = nil
        if let owned = process, owned.isRunning {
            let ready = await healthy()
            try checkCurrent()
            if process === owned, owned.isRunning, ready { return }
        }
        if process != nil { stopProcess() }
        // Missing or damaged app-owned runtime is independent of ASR readiness.
        // Validate it before probing ports; never fall back to an external provider.
        let binary = try ManagedModelRuntime.brandedExecutable(root: root)
        // The managed service owns its port and model cache. External servers are selected explicitly.
        var available = false
        for candidate in 11436...11456 {
            try checkCurrent()
            port = candidate
            let occupied = await healthy()
            try checkCurrent()
            if !occupied { available = true; break }
        }
        guard available else { throw AppError.message(L("Порты локального ИИ заняты. Перезапустите After.")) }
        let p = Process(); p.executableURL = binary; p.arguments = ["serve"]
        p.standardInput = FileHandle.nullDevice; p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        p.environment = ProcessEnvironment.withoutSecrets(ProcessInfo.processInfo.environment).merging([
            "OLLAMA_HOST": "127.0.0.1:\(port)", "OLLAMA_MODELS": root.appendingPathComponent("cache/ollama-models").path,
            "OLLAMA_NO_CLOUD": "1", "OLLAMA_CONTEXT_LENGTH": "16384", "OLLAMA_NUM_PARALLEL": "1",
            "OLLAMA_MAX_LOADED_MODELS": "1", "OLLAMA_KEEP_ALIVE": "0"
        ]) { _, new in new }
        do { try p.run() }
        catch {
            throw AppError.message(L("Не удалось запустить локальный ИИ «After». В настройках «Конспект и карточки» повторите подготовку ИИ."))
        }
        process = p
        do {
            for _ in 0..<40 {
                try checkCurrent()
                guard process === p, p.isRunning else {
                    throw AppError.message(L("Локальный ИИ не запустился. Повторите подготовку в настройках."))
                }
                let ready = await healthy()
                try checkCurrent()
                // A successful HTTP probe is insufficient if this launch
                // exited or was replaced while the request was suspended.
                guard process === p, p.isRunning else {
                    throw AppError.message(L("Локальный ИИ не запустился. Повторите подготовку в настройках."))
                }
                if ready { return }
                try await Task.sleep(for: .milliseconds(250))
            }
            throw AppError.message(L("Локальный ИИ долго запускается. Повторите через несколько секунд."))
        } catch {
            // A superseding ensure may have reused this same healthy process.
            // Only the still-current startup owns cleanup, never a stale task.
            if generation == token, process === p { stopProcess() }
            throw error
        }
    }
    private func healthy() async -> Bool {
        let path = "/api/tags"
        guard let url = URL(string: baseURL + path) else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 1
        guard let (_, response) = try? await session.data(for: request) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }
    package func stop() {
        generation = UUID()
        stopProcess()
    }
    private func stopProcess() {
        if process?.isRunning == true { process?.terminate() }
        process = nil; externalURL = nil
    }
}
