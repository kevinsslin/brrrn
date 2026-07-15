import Foundation

/// Folds fast-mode rows into their base variant. Claude logs fast mode as
/// `speed: "fast"`; Codex logs the priority service tier as a "priority"
/// word in the variant. Both are the same product idea (pay more per token
/// for lower latency) and neither has published tier pricing, so a separate
/// row would just split one model's number in two. The fold keeps the
/// fast-mode share on the merged row for hover detail.
public enum ModelMerge {
    public static func foldFastMode(_ rows: [BurnReport.ModelUsage]) -> [BurnReport.ModelUsage] {
        var merged: [String: BurnReport.ModelUsage] = [:]
        var order: [String] = []

        for row in rows {
            let words = (row.speed ?? "")
                .lowercased()
                .split(separator: " ")
                .map(String.init)
            let isFast = words.contains("fast") || words.contains("priority")
            // "standard"/"default" mean the same as no variant at all, so
            // they normalize away; otherwise a "standard" and a "fast" row
            // of the same model would land in different buckets.
            let dropped: Set<String> = ["fast", "priority", "standard", "default", "none"]
            let base = words.filter { !dropped.contains($0) }.joined(separator: " ")
            let key = "\(row.source)|\(row.model)|\(base)"

            var target = merged[key] ?? {
                order.append(key)
                var empty = row
                empty.speed = base.isEmpty ? nil : base
                empty.inputTokens = 0
                empty.outputTokens = 0
                empty.cacheReadTokens = nil
                empty.cacheWriteTokens = nil
                empty.reasoningTokens = nil
                empty.totalTokens = 0
                empty.costUSD = nil
                empty.fastCostUSD = 0
                empty.fastTotalTokens = 0
                return empty
            }()

            target.inputTokens += row.inputTokens
            target.outputTokens += row.outputTokens
            target.totalTokens += row.totalTokens
            target.cacheReadTokens = addOptional(target.cacheReadTokens, row.cacheReadTokens)
            target.cacheWriteTokens = addOptional(target.cacheWriteTokens, row.cacheWriteTokens)
            target.reasoningTokens = addOptional(target.reasoningTokens, row.reasoningTokens)
            target.costUSD = addOptional(target.costUSD, row.costUSD)
            if isFast {
                target.fastCostUSD += row.costUSD ?? 0
                target.fastTotalTokens += row.totalTokens
            }
            merged[key] = target
        }

        return order.compactMap { merged[$0] }
    }

    private static func addOptional(_ a: Int?, _ b: Int?) -> Int? {
        if a == nil && b == nil { return nil }
        return (a ?? 0) + (b ?? 0)
    }

    private static func addOptional(_ a: Double?, _ b: Double?) -> Double? {
        if a == nil && b == nil { return nil }
        return (a ?? 0) + (b ?? 0)
    }
}
