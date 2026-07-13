import Foundation

public enum PitClientError: Error, LocalizedError, Sendable {
    case invalidHubURL
    case badStatus(Int, String)

    public var errorDescription: String? {
        switch self {
        case .invalidHubURL:
            return "invalid brrrn hub URL"
        case .badStatus(let status, let message):
            return "hub returned \(status): \(message)"
        }
    }
}

public struct PitClient: Sendable {
    public var session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func boards(config: BrrrnConfig) async throws -> [PitBoard] {
        try await withThrowingTaskGroup(of: PitBoard.self) { group in
            for code in config.pits {
                group.addTask { try await board(hubURL: config.hubURL, code: code) }
            }
            var boards: [PitBoard] = []
            for try await board in group {
                boards.append(board)
            }
            let order = Dictionary(uniqueKeysWithValues: config.pits.enumerated().map { ($1, $0) })
            return boards.sorted { (order[$0.code] ?? .max) < (order[$1.code] ?? .max) }
        }
    }

    public func board(hubURL: String, code: String) async throws -> PitBoard {
        try await fetch(hubURL: hubURL, path: "/pit/\(code)/board")
    }

    public func member(hubURL: String, code: String, handle: String) async throws -> MemberDetail {
        let encoded = handle.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? handle
        return try await fetch(hubURL: hubURL, path: "/pit/\(code)/member/\(encoded)")
    }

    private func fetch<T: Decodable>(hubURL: String, path: String) async throws -> T {
        guard let url = URL(string: hubURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + path) else {
            throw PitClientError.invalidHubURL
        }
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse else {
            throw PitClientError.badStatus(0, "non-HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? JSONDecoder().decode(ErrorResponse.self, from: data).error) ?? "request failed"
            throw PitClientError.badStatus(http.statusCode, message)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}

private struct ErrorResponse: Decodable {
    let error: String
}
