import Darwin
import Foundation

public enum BrrrnConfigLoadState: Sendable, Equatable {
    case missing
    case valid(BrrrnConfig)
    case malformed(String)
}

public enum BrrrnConfigStoreError: Error, LocalizedError, Sendable, Equatable {
    case malformed(String)
    case invalidHubURL
    case invalidIdentifier
    case fileSystem(String)

    public var errorDescription: String? {
        switch self {
        case .malformed(let message):
            return "invalid brrrn config: \(message)"
        case .invalidHubURL:
            return "hub URL must use https (localhost may use http)"
        case .invalidIdentifier:
            return "social identifier cannot be empty"
        case .fileSystem(let message):
            return message
        }
    }
}

public actor BrrrnConfigStore {
    public let url: URL

    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(url: URL = BrrrnConfig.defaultURL()) {
        self.url = url
    }

    public func load() async -> BrrrnConfigLoadState {
        await acquire()
        defer { release() }
        return readState()
    }

    @discardableResult
    public func setHubURL(_ value: String) async throws -> BrrrnConfig {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard Self.isAllowedHubURL(normalized) else {
            throw BrrrnConfigStoreError.invalidHubURL
        }
        return try await mutate { $0.hubURL = normalized }
    }

    @discardableResult
    public func appendPit(_ code: String) async throws -> BrrrnConfig {
        try await append(code, to: \.pits)
    }

    @discardableResult
    public func appendRelationship(_ identifier: String) async throws -> BrrrnConfig {
        try await append(identifier, to: \.relationships)
    }

    @discardableResult
    public func appendBackfillMarker(_ identifier: String) async throws -> BrrrnConfig {
        try await append(identifier, to: \.backfilledPits)
    }

    public func serialize<T: Sendable>(
        _ operation: @Sendable () async throws -> T
    ) async rethrows -> T {
        await acquire()
        defer { release() }
        return try await operation()
    }

    private func append(
        _ value: String,
        to keyPath: WritableKeyPath<BrrrnConfig, [String]>
    ) async throws -> BrrrnConfig {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { throw BrrrnConfigStoreError.invalidIdentifier }
        return try await mutate { config in
            if !config[keyPath: keyPath].contains(normalized) {
                config[keyPath: keyPath].append(normalized)
            }
        }
    }

    private func mutate(_ change: (inout BrrrnConfig) throws -> Void) async throws -> BrrrnConfig {
        await acquire()
        defer { release() }
        return try withFileLock {
            var config: BrrrnConfig
            switch readState() {
            case .missing:
                config = BrrrnConfig(hubURL: "", handle: "")
            case .valid(let value):
                config = value
            case .malformed(let message):
                throw BrrrnConfigStoreError.malformed(message)
            }
            try change(&config)
            try writeAtomically(config)
            return config
        }
    }

    private func readState() -> BrrrnConfigLoadState {
        guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
        do {
            return .valid(try BrrrnConfig.load(from: Data(contentsOf: url)))
        } catch {
            return .malformed(error.localizedDescription)
        }
    }

    private func withFileLock<T>(_ operation: () throws -> T) throws -> T {
        let parent = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        } catch {
            throw BrrrnConfigStoreError.fileSystem("cannot create \(parent.path): \(error.localizedDescription)")
        }

        let lockURL = URL(fileURLWithPath: url.path + ".lock")
        let processMutex = ProcessLockRegistry.shared.mutex(for: lockURL)
        processMutex.lock()
        defer { processMutex.unlock() }

        let descriptor = Darwin.open(lockURL.path, O_RDWR | O_CREAT, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw fileSystemError("cannot open config lock") }
        defer { Darwin.close(descriptor) }
        guard Darwin.fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else {
            throw fileSystemError("cannot protect config lock")
        }
        guard Darwin.lockf(descriptor, F_LOCK, 0) == 0 else {
            throw fileSystemError("cannot lock config")
        }
        defer { Darwin.lockf(descriptor, F_ULOCK, 0) }
        return try operation()
    }

    private func writeAtomically(_ config: BrrrnConfig) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var data = try encoder.encode(config)
        data.append(0x0A)

        let parent = url.deletingLastPathComponent()
        let temporary = parent.appendingPathComponent(".\(url.lastPathComponent).tmp-\(UUID().uuidString)")
        let descriptor = Darwin.open(
            temporary.path,
            O_WRONLY | O_CREAT | O_EXCL,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else { throw fileSystemError("cannot create temporary config") }
        var shouldRemoveTemporary = true
        defer {
            Darwin.close(descriptor)
            if shouldRemoveTemporary {
                try? FileManager.default.removeItem(at: temporary)
            }
        }

        try data.withUnsafeBytes { bytes in
            guard var pointer = bytes.baseAddress else { return }
            var remaining = bytes.count
            while remaining > 0 {
                let written = Darwin.write(descriptor, pointer, remaining)
                guard written > 0 else { throw fileSystemError("cannot write temporary config") }
                pointer = pointer.advanced(by: written)
                remaining -= written
            }
        }
        guard Darwin.fsync(descriptor) == 0 else { throw fileSystemError("cannot sync temporary config") }
        guard Darwin.rename(temporary.path, url.path) == 0 else { throw fileSystemError("cannot replace config") }
        shouldRemoveTemporary = false
        guard Darwin.chmod(url.path, S_IRUSR | S_IWUSR) == 0 else {
            throw fileSystemError("cannot protect config")
        }

        let directoryDescriptor = Darwin.open(parent.path, O_RDONLY)
        guard directoryDescriptor >= 0 else {
            throw fileSystemError("cannot open config directory")
        }
        defer { Darwin.close(directoryDescriptor) }
        guard Darwin.fsync(directoryDescriptor) == 0 else {
            throw fileSystemError("cannot sync config directory")
        }
    }

    private static func isAllowedHubURL(_ value: String) -> Bool {
        guard
            let components = URLComponents(string: value),
            let scheme = components.scheme?.lowercased(),
            let host = components.host?.lowercased(),
            !host.isEmpty
        else {
            return false
        }
        if scheme == "https" { return true }
        return scheme == "http" && ["localhost", "127.0.0.1", "::1"].contains(host)
    }

    private func acquire() async {
        if !busy {
            busy = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        guard !waiters.isEmpty else {
            busy = false
            return
        }
        waiters.removeFirst().resume()
    }

    private func fileSystemError(_ prefix: String) -> BrrrnConfigStoreError {
        let detail = String(cString: strerror(errno))
        return .fileSystem("\(prefix): \(detail)")
    }
}

private final class ProcessLockRegistry: @unchecked Sendable {
    static let shared = ProcessLockRegistry()

    private let registryMutex = NSLock()
    private var mutexes: [String: NSLock] = [:]

    func mutex(for url: URL) -> NSLock {
        let key = url.standardizedFileURL.path
        registryMutex.lock()
        defer { registryMutex.unlock() }
        if let existing = mutexes[key] {
            return existing
        }
        let created = NSLock()
        mutexes[key] = created
        return created
    }
}
