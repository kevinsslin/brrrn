import Foundation

public enum JSONValue: Codable, Sendable, Equatable {
    case null
    case bool(Bool)
    case integer(Int64)
    case unsignedInteger(UInt64)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .integer(value)
        } else if let value = try? container.decode(UInt64.self) {
            self = .unsignedInteger(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case .bool(let value):
            try container.encode(value)
        case .integer(let value):
            try container.encode(value)
        case .unsignedInteger(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .string(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        }
    }
}

/// Shared configuration read and written by the Rust CLI and native app.
public struct BrrrnConfig: Codable, Sendable, Equatable {
    public var hubURL: String
    public var handle: String
    public var secret: String?
    public var machineID: String?
    public var pits: [String]
    public var relationships: [String]
    public var backfilledPits: [String]
    public var extraFields: [String: JSONValue]

    private static let knownKeys = Set([
        "hub_url",
        "handle",
        "secret",
        "machine_id",
        "pits",
        "relationships",
        "backfilled_pits",
    ])

    public init(
        hubURL: String,
        handle: String,
        secret: String? = nil,
        machineID: String? = nil,
        pits: [String] = [],
        relationships: [String] = [],
        backfilledPits: [String] = [],
        extraFields: [String: JSONValue] = [:]
    ) {
        self.hubURL = hubURL
        self.handle = handle
        self.secret = secret
        self.machineID = machineID
        self.pits = pits
        self.relationships = relationships
        self.backfilledPits = backfilledPits
        self.extraFields = extraFields
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicCodingKey.self)
        let hubKey = DynamicCodingKey("hub_url")
        let handleKey = DynamicCodingKey("handle")
        let pitsKey = DynamicCodingKey("pits")
        let relationshipsKey = DynamicCodingKey("relationships")
        let backfilledPitsKey = DynamicCodingKey("backfilled_pits")
        hubURL = container.contains(hubKey)
            ? try container.decode(String.self, forKey: hubKey)
            : ""
        handle = container.contains(handleKey)
            ? try container.decode(String.self, forKey: handleKey)
            : ""
        secret = try container.decodeIfPresent(String.self, forKey: .init("secret"))
        machineID = try container.decodeIfPresent(String.self, forKey: .init("machine_id"))
        pits = container.contains(pitsKey)
            ? try container.decode([String].self, forKey: pitsKey)
            : []
        relationships = container.contains(relationshipsKey)
            ? try container.decode([String].self, forKey: relationshipsKey)
            : []
        backfilledPits = container.contains(backfilledPitsKey)
            ? try container.decode([String].self, forKey: backfilledPitsKey)
            : []
        extraFields = [:]
        for key in container.allKeys where !Self.knownKeys.contains(key.stringValue) {
            extraFields[key.stringValue] = try container.decode(JSONValue.self, forKey: key)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: DynamicCodingKey.self)
        for (key, value) in extraFields where !Self.knownKeys.contains(key) {
            try container.encode(value, forKey: .init(key))
        }
        try container.encode(hubURL, forKey: .init("hub_url"))
        try container.encode(handle, forKey: .init("handle"))
        try container.encodeIfPresent(secret, forKey: .init("secret"))
        try container.encodeIfPresent(machineID, forKey: .init("machine_id"))
        try container.encode(pits, forKey: .init("pits"))
        try container.encode(relationships, forKey: .init("relationships"))
        try container.encode(backfilledPits, forKey: .init("backfilled_pits"))
    }

    public static func load(from data: Data) throws -> BrrrnConfig {
        try JSONDecoder().decode(BrrrnConfig.self, from: data)
    }

    /// Default location: ~/.config/brrrn/config.json. BRRRN_CONFIG is a
    /// development/testing override and mirrors BRRRN_BIN.
    public static func defaultURL(
        homeDirectory: String = NSHomeDirectory(),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let override = environment["BRRRN_CONFIG"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return URL(fileURLWithPath: homeDirectory)
            .appendingPathComponent(".config/brrrn/config.json")
    }

    /// Loads the default config file. Returns nil when the file is missing
    /// or malformed. Mutating code must use BrrrnConfigStore instead.
    public static func loadDefault(homeDirectory: String = NSHomeDirectory()) -> BrrrnConfig? {
        let url = defaultURL(homeDirectory: homeDirectory)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? load(from: data)
    }

    public var hasPits: Bool { !pits.isEmpty }
    public var hasSocialTargets: Bool { !pits.isEmpty || !relationships.isEmpty }
}

private struct DynamicCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil

    init(_ stringValue: String) {
        self.stringValue = stringValue
    }

    init?(stringValue: String) {
        self.init(stringValue)
    }

    init?(intValue: Int) {
        return nil
    }
}
