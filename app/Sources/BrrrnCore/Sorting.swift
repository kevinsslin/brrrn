import Foundation

/// Cost-primary ordering for the "this week by model" list.
public enum ModelSort {
    /// Sorts by cost descending. Unpriced models (nil cost) always sort last.
    /// Ties break on total tokens descending, then model name.
    public static func byCostDescending(_ models: [BurnReport.ModelUsage]) -> [BurnReport.ModelUsage] {
        models.sorted { a, b in
            switch (a.costUSD, b.costUSD) {
            case let (x?, y?) where x != y:
                return x > y
            case (.some, .none):
                return true
            case (.none, .some):
                return false
            default:
                if a.totalTokens != b.totalTokens { return a.totalTokens > b.totalTokens }
                return a.model.localizedCaseInsensitiveCompare(b.model) == .orderedAscending
            }
        }
    }
}
