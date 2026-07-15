import SwiftUI
import BrrrnCore

struct DailyHeatmap: View {
    let title: String
    let grid: UTCActivityGrid
    var showsTable = true
    /// Analytics-tab styling: the tab itself already says "Calendar", so the
    /// title row goes away and the grid tightens up.
    var compact = false

    @Environment(\.colorScheme) private var colorScheme
    @State private var selectedDateKey: String?
    @FocusState private var isFocused: Bool

    private var cellSize: CGFloat { compact ? 12 : 14 }
    private var cellGap: CGFloat { compact ? 2 : 3 }

    private var selectedCell: DailyActivityCell {
        grid.cells.first(where: { $0.dateKey == selectedDateKey })
            ?? grid.cells.first(where: { $0.isToday })
            ?? grid.cells.last(where: { !$0.isFuture })!
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            calendar
            if showsTable {
                dailyTable
            }
        }
        .onAppear { selectToday() }
        .onChange(of: grid.endDateKey) { _, _ in selectToday() }
    }

    private var calendar: some View {
        VStack(alignment: .leading, spacing: compact ? 6 : 8) {
            if compact {
                // The grid only needs ~200pt, so the selected/hovered day's
                // detail lives beside it instead of in a full-width strip
                // that duplicated the ME header whenever today was selected.
                HStack(alignment: .top, spacing: 14) {
                    VStack(alignment: .leading, spacing: 6) {
                        monthLabels
                        HStack(alignment: .top, spacing: 7) {
                            weekdayLabels
                            heatmapGrid
                        }
                    }
                    detailPanel
                }
            } else {
                header
                detailStrip
                monthLabels
                HStack(alignment: .top, spacing: 7) {
                    weekdayLabels
                    heatmapGrid
                }
            }
            legend
        }
        .focusable()
        .focused($isFocused)
        .focusEffectDisabled()
        .onKeyPress(.leftArrow) { moveSelection(.left) }
        .onKeyPress(.rightArrow) { moveSelection(.right) }
        .onKeyPress(.upArrow) { moveSelection(.up) }
        .onKeyPress(.downArrow) { moveSelection(.down) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint("Use arrow keys to explore UTC days")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: _ = moveSelection(.nextDay)
            case .decrement: _ = moveSelection(.previousDay)
            @unknown default: break
            }
        }
    }

    private var header: some View {
        HStack {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .tracking(1.1)
            Spacer()
            Label("\(grid.currentStreakDays)d", systemImage: "flame.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.orange)
        }
    }

    private var detailStrip: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(Format.utcDate(selectedCell.date))
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                Text(statusText(selectedCell))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text(Format.money(selectedCell.costUSD))
                    .font(.callout.weight(.semibold))
                Text(Format.tokens(selectedCell.tokens))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .monospacedDigit()
        }
        .frame(minHeight: compact ? 30 : 36)
    }

    private var detailPanel: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(Format.utcShortDate(selectedCell.date) + (selectedCell.isToday ? " (today)" : ""))
                .font(.caption.weight(.semibold))
                .lineLimit(1)
            Text(Format.money(selectedCell.costUSD))
                .font(.callout.weight(.bold))
                .monospacedDigit()
            Text("\(Format.tokens(selectedCell.tokens)) tokens")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Text(statusText(selectedCell))
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 2)
            Label("\(grid.currentStreakDays)d streak", systemImage: "flame.fill")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.orange)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var monthLabels: some View {
        HStack(spacing: cellGap) {
            Color.clear.frame(width: 17, height: 1)
            ForEach(0..<grid.weeks, id: \.self) { week in
                Color.clear
                    .frame(width: cellSize, height: 11)
                    .overlay(alignment: .leading) {
                        Text(monthLabel(for: week))
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                            .fixedSize()
                    }
            }
        }
        .frame(height: 11)
    }

    private var weekdayLabels: some View {
        VStack(spacing: cellGap) {
            ForEach(0..<7, id: \.self) { weekday in
                Text(weekday == 0 ? "M" : weekday == 2 ? "W" : weekday == 4 ? "F" : "")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .frame(width: 17, height: cellSize, alignment: .trailing)
            }
        }
    }

    private var heatmapGrid: some View {
        HStack(spacing: cellGap) {
            ForEach(0..<grid.weeks, id: \.self) { week in
                VStack(spacing: cellGap) {
                    ForEach(0..<7, id: \.self) { weekday in
                        let cell = cell(week: week, weekday: weekday)
                        HeatmapCell(
                            cell: cell,
                            color: BrrrnPalette.heatmap(cell.level, colorScheme),
                            isSelected: cell.dateKey == selectedCell.dateKey,
                            size: cellSize
                        ) {
                            selectedDateKey = cell.dateKey
                        } focus: {
                            selectedDateKey = cell.dateKey
                            isFocused = true
                        }
                    }
                }
            }
        }
    }

    private var legend: some View {
        HStack(spacing: 6) {
            Text("Less")
            ForEach(DailyCostLevel.allCases.dropFirst(), id: \.rawValue) { level in
                RoundedRectangle(cornerRadius: 2)
                    .fill(BrrrnPalette.heatmap(level, colorScheme))
                    .frame(width: 10, height: 10)
            }
            Text("More")
            Spacer()
            Circle()
                .fill(.primary)
                .frame(width: 5, height: 5)
            Text("\(Format.money(grid.thresholdUSD))+ streak")
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }

    private var dailyTable: some View {
        DisclosureGroup("Daily table") {
            LazyVStack(spacing: 5) {
                ForEach(grid.cells.filter { !$0.isFuture }.reversed()) { cell in
                    HStack {
                        Text(Format.utcMonthDay(cell.date))
                            .foregroundStyle(.secondary)
                        Text(statusText(cell))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                        Spacer()
                        Text(Format.tokens(cell.tokens))
                            .foregroundStyle(.secondary)
                        Text(Format.money(cell.costUSD))
                            .frame(width: 72, alignment: .trailing)
                    }
                    .font(.caption2)
                    .monospacedDigit()
                }
            }
            .padding(.top, 6)
        }
        .font(.caption)
    }

    private var accessibilityLabel: String {
        "\(title). \(Format.utcDate(selectedCell.date)). \(Format.money(selectedCell.costUSD)). \(statusText(selectedCell)). \(Format.tokens(selectedCell.tokens)) tokens."
    }

    private func cell(week: Int, weekday: Int) -> DailyActivityCell {
        grid.cells[week * 7 + weekday]
    }

    private func monthLabel(for week: Int) -> String {
        let first = cell(week: week, weekday: 0)
        let calendar = BurnReport.DailyEntry.utcCalendar
        if week == 0 {
            guard grid.weeks > 1 else { return Format.utcMonth(first.date) }
            let next = cell(week: 1, weekday: 0)
            return calendar.component(.month, from: first.date) == calendar.component(.month, from: next.date)
                ? Format.utcMonth(first.date)
                : ""
        }
        let prior = cell(week: week - 1, weekday: 0)
        return calendar.component(.month, from: first.date) == calendar.component(.month, from: prior.date)
            ? ""
            : Format.utcMonth(first.date)
    }

    private func statusText(_ cell: DailyActivityCell) -> String {
        switch cell.status {
        case .future: "Future UTC day"
        case .noUsage: "No usage recorded"
        case .unpriced: "Tokens recorded; no priced cost"
        case .belowThreshold: "Below the \(Format.money(grid.thresholdUSD)) streak threshold"
        case .thresholdMet: "Met the \(Format.money(grid.thresholdUSD)) streak threshold"
        case .currentStreak: "Current streak"
        }
    }

    private func selectToday() {
        selectedDateKey = grid.cells.first(where: { $0.isToday })?.dateKey
    }

    private func moveSelection(_ direction: HeatmapNavigation.Direction) -> KeyPress.Result {
        guard
            let index = grid.cells.firstIndex(where: { $0.dateKey == selectedCell.dateKey }),
            let next = HeatmapNavigation.targetIndex(from: index, direction: direction, cells: grid.cells)
        else {
            return .ignored
        }
        selectedDateKey = grid.cells[next].dateKey
        return .handled
    }
}

enum HeatmapNavigation {
    enum Direction {
        case left
        case right
        case up
        case down
        case previousDay
        case nextDay
    }

    static func targetIndex(
        from index: Int,
        direction: Direction,
        cells: [DailyActivityCell]
    ) -> Int? {
        guard cells.indices.contains(index) else { return nil }
        let current = cells[index]
        let candidate: Int
        switch direction {
        case .left:
            guard current.weekIndex > 0 else { return nil }
            candidate = index - 7
        case .right:
            candidate = index + 7
        case .up:
            guard current.weekdayIndex > 0 else { return nil }
            candidate = index - 1
        case .down:
            guard current.weekdayIndex < 6 else { return nil }
            candidate = index + 1
        case .previousDay:
            candidate = index - 1
        case .nextDay:
            candidate = index + 1
        }
        guard cells.indices.contains(candidate), !cells[candidate].isFuture else { return nil }
        return candidate
    }
}

private struct HeatmapCell: View {
    let cell: DailyActivityCell
    let color: Color
    let isSelected: Bool
    let size: CGFloat
    let hover: () -> Void
    let focus: () -> Void

    var body: some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(cell.isFuture ? Color.clear : color)
            .frame(width: size, height: size)
            .overlay {
                if isSelected && !cell.isFuture {
                    RoundedRectangle(cornerRadius: 3)
                        .stroke(.primary.opacity(0.8), lineWidth: 1.5)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if cell.status == .currentStreak {
                    Circle()
                        .fill(.primary)
                        .stroke(.background, lineWidth: 1)
                        .frame(width: 5, height: 5)
                        .padding(1)
                }
            }
            .contentShape(Rectangle())
            .onHover { active in
                if active && !cell.isFuture { hover() }
            }
            .onTapGesture {
                if !cell.isFuture { focus() }
            }
    }
}
