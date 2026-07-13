import Foundation

/// Finds the brrrn CLI. Lookup order:
/// 1. BRRRN_BIN environment variable
/// 2. /opt/homebrew/bin/brrrn
/// 3. /usr/local/bin/brrrn
/// 4. ~/repos/kevin-dev/brrrn/target/release/brrrn
///
/// The file-exists check and environment are injectable for tests.
public struct BinaryLocator: Sendable {
    public var environment: [String: String]
    public var homeDirectory: String
    public var fileExists: @Sendable (String) -> Bool

    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: String = NSHomeDirectory(),
        fileExists: @escaping @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) {
        self.environment = environment
        self.homeDirectory = homeDirectory
        self.fileExists = fileExists
    }

    /// Candidate paths in priority order.
    public func candidates() -> [String] {
        var paths: [String] = []
        if let override = environment["BRRRN_BIN"], !override.isEmpty {
            paths.append(override)
        }
        paths.append("/opt/homebrew/bin/brrrn")
        paths.append("/usr/local/bin/brrrn")
        paths.append(homeDirectory + "/repos/kevin-dev/brrrn/target/release/brrrn")
        return paths
    }

    /// First candidate that exists on disk, or nil when brrrn is not installed.
    public func locate() -> String? {
        candidates().first(where: fileExists)
    }
}
