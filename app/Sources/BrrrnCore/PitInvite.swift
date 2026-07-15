import Foundation

/// One-string invite: `code` alone joins on the already-configured hub;
/// `code@https://hub.example` carries the hub along, so a newcomer needs to
/// paste exactly one thing.
public enum PitInvite {
    public struct Parsed: Equatable, Sendable {
        public var code: String
        public var hubURL: String?
    }

    public static func compose(code: String, hubURL: String?) -> String {
        guard let hubURL, !hubURL.isEmpty else { return code }
        return "\(code)@\(hubURL)"
    }

    public static func parse(_ raw: String) -> Parsed {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let at = trimmed.firstIndex(of: "@") else {
            return Parsed(code: trimmed.lowercased(), hubURL: nil)
        }
        let code = String(trimmed[..<at]).trimmingCharacters(in: .whitespaces).lowercased()
        var hub = String(trimmed[trimmed.index(after: at)...]).trimmingCharacters(in: .whitespaces)
        if !hub.isEmpty && !hub.contains("://") {
            hub = "https://\(hub)"
        }
        return Parsed(code: code, hubURL: hub.isEmpty ? nil : hub)
    }
}
