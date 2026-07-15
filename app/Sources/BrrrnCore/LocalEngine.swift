import Foundation

public enum EngineError: Error, LocalizedError, Sendable {
    case binaryNotFound
    case launchFailed(String)
    case processFailed(status: Int32, stderr: String)
    case emptyOutput

    public var errorDescription: String? {
        switch self {
        case .binaryNotFound:
            return "brrrn binary not found. Set BRRRN_BIN or install brrrn."
        case .launchFailed(let message):
            return "could not launch brrrn: \(message)"
        case .processFailed(let status, let stderr):
            let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return detail.isEmpty ? "brrrn exited with status \(status)" : detail
        case .emptyOutput:
            return "brrrn produced no output"
        }
    }
}

/// Runs the brrrn CLI off the main thread and decodes its JSON output.
public enum LocalEngine {
    /// Watchdog limit: a cold scan takes about 8 seconds, so this is generous.
    public static let timeoutSeconds: TimeInterval = 90

    /// `brrrn --json`
    public static func allTimeReport(binary: String) async throws -> BurnReport {
        try await report(binary: binary, arguments: ["--json"])
    }

    /// `brrrn --period week --json`
    public static func weekReport(binary: String) async throws -> BurnReport {
        try await report(binary: binary, arguments: ["--period", "week", "--json"])
    }

    public static func report(binary: String, arguments: [String]) async throws -> BurnReport {
        let data = try await run(binary: binary, arguments: arguments)
        guard !data.isEmpty else { throw EngineError.emptyOutput }
        return try JSONDecoder().decode(BurnReport.self, from: data)
    }

    /// Pushes today/yesterday (or the initial full backfill) to configured pits.
    public static func submit(binary: String) async throws {
        _ = try await run(binary: binary, arguments: ["submit"])
    }

    /// `brrrn pit new [--name <name>]`, returning the freshly minted code.
    public static func createPit(binary: String, name: String?) async throws -> String {
        var arguments = ["pit", "new"]
        if let name, !name.isEmpty {
            arguments.append(contentsOf: ["--name", name])
        }
        let data = try await run(binary: binary, arguments: arguments)
        let output = String(data: data, encoding: .utf8) ?? ""
        guard let line = output.split(separator: "\n").first(where: { $0.hasPrefix("created pit: ") }),
              case let code = line.dropFirst("created pit: ".count).trimmingCharacters(in: .whitespaces),
              !code.isEmpty
        else {
            throw EngineError.emptyOutput
        }
        return code
    }

    /// `brrrn pit join <code> --as <handle>`; the CLI claims the handle and
    /// persists the secret/machine ID into the shared config.
    public static func joinPit(binary: String, code: String, handle: String) async throws {
        _ = try await run(binary: binary, arguments: ["pit", "join", code, "--as", handle])
    }

    private static func run(binary: String, arguments: [String]) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: binary)
                process.arguments = arguments

                let stdout = Pipe()
                let stderr = Pipe()
                process.standardOutput = stdout
                process.standardError = stderr
                process.standardInput = FileHandle.nullDevice

                // Drain stderr as it arrives so a chatty CLI can never fill
                // the pipe buffer and deadlock against our stdout read.
                let stderrBuffer = LockedBuffer()
                stderr.fileHandleForReading.readabilityHandler = { handle in
                    let chunk = handle.availableData
                    if chunk.isEmpty {
                        handle.readabilityHandler = nil
                    } else {
                        stderrBuffer.append(chunk)
                    }
                }

                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: EngineError.launchFailed(error.localizedDescription))
                    return
                }

                // Watchdog: kill a hung scan so refresh state can recover.
                let box = ProcessBox(process)
                DispatchQueue.global().asyncAfter(deadline: .now() + timeoutSeconds) {
                    box.terminateIfRunning()
                }

                let output = stdout.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                stderr.fileHandleForReading.readabilityHandler = nil

                if process.terminationStatus == 0 {
                    continuation.resume(returning: output)
                } else {
                    let message = String(data: stderrBuffer.data, encoding: .utf8) ?? ""
                    continuation.resume(throwing: EngineError.processFailed(
                        status: process.terminationStatus,
                        stderr: message
                    ))
                }
            }
        }
    }
}

/// Process is not Sendable; this box confines the only cross-thread use
/// (the watchdog terminate call, which Process documents as thread-safe).
private final class ProcessBox: @unchecked Sendable {
    private let process: Process

    init(_ process: Process) {
        self.process = process
    }

    func terminateIfRunning() {
        if process.isRunning {
            process.terminate()
        }
    }
}

private final class LockedBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()

    func append(_ chunk: Data) {
        lock.lock()
        storage.append(chunk)
        lock.unlock()
    }

    var data: Data {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
