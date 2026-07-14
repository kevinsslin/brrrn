import Foundation

public enum ModelProvider: String, Sendable, Equatable {
    case claude
    case codex
    case unknown

    public var displayName: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        case .unknown: "Other"
        }
    }

    public var accessibilityName: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "OpenAI Codex"
        case .unknown: "Other provider"
        }
    }
}

public struct ModelPresentation: Sendable, Equatable {
    public var provider: ModelProvider
    public var variantLabel: String

    public init(source: String, speed: String?) {
        provider = Self.provider(for: source)
        variantLabel = Self.variant(for: provider, speed: speed)
    }

    private static func provider(for source: String) -> ModelProvider {
        switch source.lowercased() {
        case "claude", "claude-code", "anthropic": .claude
        case "codex", "openai", "openai-codex": .codex
        default: .unknown
        }
    }

    private static func variant(for provider: ModelProvider, speed: String?) -> String {
        let normalized = speed?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        switch provider {
        case .claude:
            return switch normalized {
            case "", "default", "standard": "Standard"
            case "fast": "Fast"
            default: readable(normalized)
            }
        case .codex:
            let level = switch normalized {
            case "", "default", "standard": "Default"
            case "xhigh", "x-high": "X-High"
            default: readable(normalized)
            }
            return "Reasoning: \(level)"
        case .unknown:
            return normalized.isEmpty ? "Default" : readable(normalized)
        }
    }

    private static func readable(_ value: String) -> String {
        value
            .split(whereSeparator: { $0 == "_" || $0 == "-" })
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }
}

extension BurnReport.ModelUsage {
    public var presentation: ModelPresentation {
        ModelPresentation(source: source, speed: speed)
    }
}
