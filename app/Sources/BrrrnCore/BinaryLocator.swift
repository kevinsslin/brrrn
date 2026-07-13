import Foundation

/// Finds the brrrn CLI. Lookup order:
/// 1. BRRRN_BIN environment variable
/// 2. brrrn bundled beside the menu app executable
/// 3. /opt/homebrew/bin/brrrn
/// 4. /usr/local/bin/brrrn
/// 5. the development checkout fallback
///
/// Paths and file-existence checks are injectable for tests.
public struct BinaryLocator: Sendable {
    public var environment: [String: String]
    public var homeDirectory: String
    public var executablePath: String?
    public var fileExists: @Sendable (String) -> Bool

    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: String = NSHomeDirectory(),
        executablePath: String? = Bundle.main.executableURL?.path,
        fileExists: @escaping @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) {
        self.environment = environment
        self.homeDirectory = homeDirectory
        self.executablePath = executablePath
        self.fileExists = fileExists
    }

    public func candidates() -> [String] {
        var paths: [String] = []
        if let override = environment["BRRRN_BIN"], !override.isEmpty {
            paths.append(override)
        }
        if let executablePath {
            let sibling = URL(fileURLWithPath: executablePath)
                .deletingLastPathComponent()
                .appendingPathComponent("brrrn")
                .path
            paths.append(sibling)
        }
        paths.append("/opt/homebrew/bin/brrrn")
        paths.append("/usr/local/bin/brrrn")
        paths.append(homeDirectory + "/repos/kevin-dev/brrrn/target/release/brrrn")
        return paths
    }

    public func locate() -> String? {
        candidates().first(where: fileExists)
    }
}
