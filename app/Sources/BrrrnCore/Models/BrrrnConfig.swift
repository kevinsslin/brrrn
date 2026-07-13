import Foundation

/// Pit configuration written by `brrrn pit join`, read from
/// ~/.config/brrrn/config.json.
public struct BrrrnConfig: Codable, Sendable, Equatable {
    public var hubURL: String
    public var handle: String
    public var secret: String?
    public var machineID: String?
    public var pits: [String]

    enum CodingKeys: String, CodingKey {
        case hubURL = "hub_url"
        case handle
        case secret
        case machineID = "machine_id"
        case pits
    }

    public init(
        hubURL: String,
        handle: String,
        secret: String? = nil,
        machineID: String? = nil,
        pits: [String] = []
    ) {
        self.hubURL = hubURL
        self.handle = handle
        self.secret = secret
        self.machineID = machineID
        self.pits = pits
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        hubURL = try container.decode(String.self, forKey: .hubURL)
        handle = try container.decode(String.self, forKey: .handle)
        secret = try container.decodeIfPresent(String.self, forKey: .secret)
        machineID = try container.decodeIfPresent(String.self, forKey: .machineID)
        pits = try container.decodeIfPresent([String].self, forKey: .pits) ?? []
    }

    public static func load(from data: Data) throws -> BrrrnConfig {
        try JSONDecoder().decode(BrrrnConfig.self, from: data)
    }

    /// Default location: ~/.config/brrrn/config.json
    public static func defaultURL(homeDirectory: String = NSHomeDirectory()) -> URL {
        URL(fileURLWithPath: homeDirectory)
            .appendingPathComponent(".config/brrrn/config.json")
    }

    /// Loads the default config file. Returns nil when the file is missing
    /// or malformed (the app then shows the "no pit configured" hint).
    public static func loadDefault(homeDirectory: String = NSHomeDirectory()) -> BrrrnConfig? {
        let url = defaultURL(homeDirectory: homeDirectory)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? load(from: data)
    }

    /// True when there is at least one pit worth showing.
    public var hasPits: Bool { !pits.isEmpty }
}
