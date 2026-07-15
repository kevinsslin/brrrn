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
    /// Short parenthetical variant ("x-high", "fast", "medium"). Nil for the
    /// provider's default mode: a default carries no information, so it is
    /// not displayed at all.
    public var variantSuffix: String?

    public init(source: String, speed: String?) {
        provider = Self.provider(for: source)
        variantSuffix = Self.suffix(for: speed)
    }

    /// "gpt-5.6-sol (x-high)", or just the model name when running default.
    public func title(for model: String) -> String {
        variantSuffix.map { "\(model) (\($0))" } ?? model
    }

    private static func provider(for source: String) -> ModelProvider {
        switch source.lowercased() {
        case "claude", "claude-code", "anthropic": .claude
        case "codex", "openai", "openai-codex": .codex
        default: .unknown
        }
    }

    private static func suffix(for speed: String?) -> String? {
        let normalized = speed?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        // Variants can stack ("xhigh priority"); normalize each word and
        // drop the ones that mean "nothing notable".
        let parts = normalized.split(separator: " ").compactMap { part -> String? in
            switch part {
            case "", "default", "standard", "none":
                nil
            case "xhigh", "x-high":
                "x-high"
            default:
                part.replacingOccurrences(of: "_", with: "-")
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }
}

extension BurnReport.ModelUsage {
    public var presentation: ModelPresentation {
        ModelPresentation(source: source, speed: speed)
    }

    /// Row title with the variant folded in: "claude-fable-5 (fast)".
    public var displayTitle: String {
        presentation.title(for: model)
    }
}
