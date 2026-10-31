import AfterLocalization
import AfterPlatform
import Foundation
import Darwin

/// Give the private, app-owned model runtime real executable identities. Keeping
/// compatibility symlinks in the same directory preserves Ollama's library and
/// llama-server discovery without changing argv or touching external providers.
package enum ManagedModelRuntime {
    package static let serverName = "После ИИ"
    package static let modelName = "После Модель"

    package static func brandedExecutable(root: URL) throws -> URL {
        let manager = FileManager.default
        let runtime = root.appendingPathComponent("runtime")
        let base = runtime.appendingPathComponent("ollama")
        try ownedDirectory(runtime)
        try ownedDirectory(base)
        let lockURL = base.appendingPathComponent(".posle-identity.lock")
        let descriptor = lockURL.path.withCString { Darwin.open($0, O_RDWR | O_CREAT | O_NOFOLLOW, 0o600) }
        guard descriptor >= 0 else { throw failure() }
        defer { Darwin.close(descriptor) }
        var information = stat()
        guard fstat(descriptor, &information) == 0,
              information.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              information.st_uid == getuid(), flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { throw failure() }
        defer { flock(descriptor, LOCK_UN) }
        let bin = base.appendingPathComponent("bin")
        if manager.fileExists(atPath: bin.path) { try ownedDirectory(bin) }
        let candidates = [bin, base]
        guard let directory = candidates.first(where: {
            exists($0.appendingPathComponent("ollama")) || exists($0.appendingPathComponent(serverName))
        }) else {
            throw notPrepared()
        }
        let server = try brand(directory: directory, original: "ollama", display: serverName)
        let modelDirectories = [directory, base.appendingPathComponent("lib/ollama")]
        if let models = modelDirectories.first(where: {
            exists($0.appendingPathComponent("llama-server")) || exists($0.appendingPathComponent(modelName))
        }) {
            if models != directory {
                try ownedDirectory(base.appendingPathComponent("lib"))
                try ownedDirectory(models)
            }
            _ = try brand(directory: models, original: "llama-server", display: modelName)
        }
        return server
    }

    private static func exists(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil
    }

    private static func attributes(_ url: URL) throws -> [FileAttributeKey: Any] {
        do { return try FileManager.default.attributesOfItem(atPath: url.path) }
        catch let error as CocoaError where [.fileNoSuchFile, .fileReadNoSuchFile].contains(error.code) {
            throw notPrepared()
        } catch { throw failure() }
    }

    private static func ownedDirectory(_ url: URL) throws {
        let values = try attributes(url)
        guard values[.type] as? FileAttributeType == .typeDirectory,
              (values[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() else { throw failure() }
    }

    private static func ownedFile(_ url: URL) throws {
        let values = try attributes(url)
        guard values[.type] as? FileAttributeType == .typeRegular,
              (values[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() else { throw failure() }
    }

    private static func ownedExecutable(_ url: URL) throws {
        try ownedFile(url)
        guard FileManager.default.isExecutableFile(atPath: url.path) else { throw failure() }
    }

    private static func brand(directory: URL, original: String, display: String) throws -> URL {
        try ownedDirectory(directory)
        let manager = FileManager.default
        let source = directory.appendingPathComponent(original)
        let destination = directory.appendingPathComponent(display)
        if let values = try? manager.attributesOfItem(atPath: source.path) {
            if values[.type] as? FileAttributeType == .typeSymbolicLink {
                guard try manager.destinationOfSymbolicLink(atPath: source.path) == display else { throw failure() }
                try ownedExecutable(destination)
                return destination
            }
            try ownedExecutable(source)
            // A verified replacement may repair our old nonexecutable file;
            // it must never replace a symlink or a file owned by someone else.
            if exists(destination) { try ownedFile(destination) }
            // rename is atomic, keeps the verified Mach-O bytes/signature and
            // replaces a previous branded version only after a runtime update.
            let result = source.path.withCString { from in
                destination.path.withCString { to in Darwin.rename(from, to) }
            }
            guard result == 0 else { throw failure() }
        } else {
            // Recover if an earlier launch stopped between rename and symlink.
            try ownedExecutable(destination)
        }
        try manager.createSymbolicLink(atPath: source.path, withDestinationPath: display)
        return destination
    }

    private static func notPrepared() -> AppError {
        .message(L("Локальный ИИ «After» не подготовлен. В настройках «Конспект и карточки → На Mac → After» нажмите «Подготовить ИИ»."))
    }

    private static func failure() -> AppError {
        .message(L("Не удалось подготовить процессы локального ИИ «After». В настройках «Конспект и карточки» повторите подготовку ИИ."))
    }
}
