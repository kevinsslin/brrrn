import SwiftUI
import BrrrnCore

struct BrrrnMenuView: View {
    @ObservedObject var model: AppModel
    /// ImageRenderer does not lay out ScrollView content; the screenshot
    /// generator flips this to render the sections in a plain stack.
    var snapshotMode = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Group {
            if let selection = model.selection {
                MemberDetailView(
                    selection: selection,
                    isLoading: model.isLoadingMember,
                    snapshotMode: snapshotMode
                ) {
                    model.closeMember()
                }
            } else if showPitSetup {
                // Inline page, not a sheet: presenting a sheet steals key
                // status from the MenuBarExtra window and closes the menu.
                PitSetupView(model: model) { showPitSetup = false }
            } else {
                mainContent
            }
        }
        .background(.background)
    }

    @State private var showPitSetup = false

    private var mainContent: some View {
        VStack(spacing: 0) {
            if snapshotMode {
                sections
            } else {
                ScrollView { sections }
            }
            Footer(model: model) { showPitSetup = true }
        }
        .overlay {
            if model.report == nil && model.isRefreshing {
                ProgressView("Reading local burn...")
                    .padding(20)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    private var sections: some View {
        VStack(alignment: .leading, spacing: 18) {
            MeHeader(report: model.report)
            if let report = model.report {
                if let daily = report.daily {
                    AnalyticsSection(
                        daily: daily,
                        thresholdUSD: report.streak?.thresholdUSD ?? StreakPolicy.defaultThresholdUSD
                    )
                } else {
                    BurnCalendarUnavailable()
                }
            }
            Divider()
            ModelSection(model: model)
            Divider()
            PitSections(model: model) { showPitSetup = true }
        }
        .padding(18)
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

private struct MeHeader: View {
    let report: BurnReport?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("ME")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .tracking(1.2)
            if let report {
                Text(Format.money(report.windows.today.costUSD))
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .contentTransition(.numericText())
                HStack(spacing: 14) {
                    Label("Week \(Format.money(report.windows.week.costUSD))", systemImage: "calendar")
                    Label("Month \(Format.money(report.windows.month.costUSD))", systemImage: "calendar.badge.clock")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()

                if let sources = report.bySource {
                    HStack(spacing: 12) {
                        SourceValue(name: "Claude", value: sources["claude"]?.weekUSD ?? 0, source: "claude")
                        SourceValue(name: "Codex", value: sources["codex"]?.weekUSD ?? 0, source: "codex")
                        Spacer()
                        if let streak = report.streak, streak.days > 0 {
                            Label("\(streak.days)d", systemImage: "flame.fill")
                                .foregroundStyle(.orange)
                        }
                    }
                    .font(.caption.weight(.medium))
                    .monospacedDigit()
                }
            } else {
                Text("Waiting for brrrn...")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct AnalyticsSection: View {
    let daily: [BurnReport.DailyEntry]
    let thresholdUSD: Double

    @AppStorage("analyticsTab") private var tabRaw = AnalyticsTab.calendar.rawValue
    @AppStorage("rhythmUsesUTC") private var rhythmUsesUTC = false
    @AppStorage("trendDays") private var trendDays = 30
    @AppStorage("rhythmLookback") private var rhythmLookback = 30

    private enum AnalyticsTab: String, CaseIterable {
        case calendar
        case trend
        case rhythm
        case records

        var label: String {
            switch self {
            case .calendar: "Calendar"
            case .trend: "Trend"
            case .rhythm: "Rhythm"
            case .records: "Records"
            }
        }
    }

    private var tab: AnalyticsTab {
        AnalyticsTab(rawValue: tabRaw) ?? .calendar
    }

    /// Personal rhythm reads in the viewer's clock; anything compared with
    /// friends stays UTC. The toggle exists for people who think in UTC.
    private var rhythmTimeZone: TimeZone {
        rhythmUsesUTC ? (TimeZone(identifier: "UTC") ?? .gmt) : .current
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // The tab strip must stay identical across tabs: per-tab controls
            // live inside each chart's caption line, so nothing here resizes
            // or shifts when switching.
            TabStrip(
                selection: $tabRaw,
                options: AnalyticsTab.allCases.map { ($0.rawValue, $0.label) }
            )

            // Every tab renders inside the same fixed-minimum box so
            // switching never reflows the sections below.
            Group {
                switch tab {
                case .calendar:
                    DailyHeatmap(
                        title: "BURN CALENDAR",
                        grid: UTCActivityGrid(
                            entries: daily,
                            weeks: 12,
                            thresholdUSD: thresholdUSD
                        ),
                        showsTable: false,
                        compact: true
                    )
                case .trend:
                    BurnTrendChart(
                        points: BurnAnalytics.trend(entries: daily, days: trendDays),
                        streakThresholdUSD: thresholdUSD,
                        days: $trendDays
                    )
                case .rhythm:
                    let rhythm = BurnAnalytics.rhythm(
                        entries: daily,
                        lookbackDays: rhythmLookback,
                        timeZone: rhythmTimeZone
                    )
                    if rhythm.hasData {
                        BurnRhythmChart(
                            rhythm: rhythm,
                            timeZone: rhythmTimeZone,
                            lookbackDays: $rhythmLookback,
                            usesUTC: $rhythmUsesUTC
                        )
                    } else {
                        RhythmUnavailable()
                    }
                case .records:
                    RecordsView(records: BurnAnalytics.records(entries: daily, thresholdUSD: thresholdUSD))
                }
            }
            .frame(minHeight: 169, alignment: .topLeading)
        }
    }
}

private struct RecordsView: View {
    let records: BurnRecords

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("PERSONAL RECORDS")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .tracking(1.2)

            if records.bestHour == nil && records.bestDay == nil && records.longestStreakDays == 0 {
                Text("Burn something first")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(minHeight: 96)
            } else {
                if let hour = records.bestHour {
                    RecordRow(
                        icon: "bolt.fill",
                        title: "Biggest hour",
                        value: Format.money(hour.costUSD),
                        detail: Format.monthDayHour(hour.date, in: .current)
                            + " \(Format.timeZoneLabel(.current))",
                        isCurrent: hour.isCurrent
                    )
                }
                if let day = records.bestDay {
                    RecordRow(
                        icon: "sun.max.fill",
                        title: "Biggest day",
                        value: Format.money(day.costUSD),
                        detail: Format.utcMonthDay(day.date) + " UTC",
                        isCurrent: day.isCurrent
                    )
                }
                if records.longestStreakDays > 0 {
                    RecordRow(
                        icon: "flame.fill",
                        title: "Longest streak",
                        value: "\(records.longestStreakDays)d",
                        detail: records.longestStreakEnd.map {
                            records.longestStreakIsCurrent
                                ? "still going"
                                : "ended \(Format.utcMonthDay($0)) UTC"
                        } ?? "",
                        isCurrent: records.longestStreakIsCurrent
                    )
                }
                Text("Day and streak records use UTC days, the same clock the pit board ranks on.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

private struct RecordRow: View {
    let icon: String
    let title: String
    let value: String
    let detail: String
    let isCurrent: Bool

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: icon)
                .font(.callout)
                .foregroundStyle(.orange)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout)
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if isCurrent {
                Text("PR NOW")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.orange.opacity(0.15), in: Capsule())
            }
            Text(value)
                .font(.callout.weight(.semibold))
                .monospacedDigit()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title), \(value), \(detail)\(isCurrent ? ", record in progress" : "")")
    }
}

private struct RhythmUnavailable: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("No hourly data yet", systemImage: "clock.badge.questionmark")
                .font(.callout.weight(.medium))
            Text("Hour-of-day rhythm appears after the engine's next scan with hourly tracking.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(minHeight: 96)
    }
}

private struct BurnCalendarUnavailable: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("BURN CALENDAR")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .tracking(1.1)
            Label("Daily history unavailable", systemImage: "calendar.badge.exclamationmark")
                .font(.callout.weight(.medium))
            Text("The selected brrrn engine does not provide daily history.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct SourceValue: View {
    let name: String
    let value: Double
    let source: String

    var body: some View {
        HStack(spacing: 6) {
            ProviderMark(provider: ModelPresentation(source: source, speed: nil).provider)
            Text("\(name) \(Format.money(value))")
        }
        .accessibilityElement(children: .combine)
    }
}

private struct ModelSection: View {
    @ObservedObject var model: AppModel

    @AppStorage("modelsExpanded") private var isExpanded = false
    @AppStorage("modelsPeriod") private var periodRaw = AppModel.ModelPeriod.week.rawValue

    private static let collapsedCount = 3

    private var period: AppModel.ModelPeriod {
        AppModel.ModelPeriod(rawValue: periodRaw) ?? .week
    }

    private var models: [BurnReport.ModelUsage] { model.models(for: period) }

    private var hidden: Int { max(0, models.count - Self.collapsedCount) }

    private var visibleModels: ArraySlice<BurnReport.ModelUsage> {
        isExpanded ? models[...] : models.prefix(Self.collapsedCount)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("BY MODEL")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .tracking(1.2)
                Spacer()
                TabStrip(
                    selection: $periodRaw,
                    options: AppModel.ModelPeriod.allCases.map { ($0.rawValue, $0.label) }
                )
                .fixedSize()
            }
            if models.isEmpty {
                Text("No model usage \(period == .today ? "today" : "this \(period.rawValue)")")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(visibleModels) { model in
                    ModelRow(model: model)
                }
                if hidden > 0 {
                    Button {
                        withAnimation(.easeOut(duration: 0.15)) { isExpanded.toggle() }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                                .font(.caption2)
                            Text(isExpanded ? "Show less" : "\(hidden) more model\(hidden == 1 ? "" : "s")")
                                .font(.caption)
                        }
                        .foregroundStyle(.secondary)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

private struct ModelRow: View {
    @State private var isHovered = false
    @State private var isPinned = false
    let model: BurnReport.ModelUsage

    private var presentation: ModelPresentation { model.presentation }

    private var detailPresented: Binding<Bool> {
        Binding(
            get: { isHovered || isPinned },
            set: { value in
                if !value {
                    isHovered = false
                    isPinned = false
                }
            }
        )
    }

    var body: some View {
        Button { isPinned.toggle() } label: {
            HStack(spacing: 9) {
                ProviderMark(provider: presentation.provider, size: 13)
                (Text(model.model)
                    + Text(presentation.variantSuffix.map { " (\($0))" } ?? "")
                        .foregroundStyle(.secondary))
                    .font(.callout)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(model.costUSD.map(Format.money) ?? "n/a")
                    .font(.callout.weight(.semibold))
                    .monospacedDigit()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .delayedHover($isHovered)
        .onExitCommand { isPinned = false }
        .accessibilityLabel("\(presentation.provider.accessibilityName), \(model.displayTitle), \(model.costUSD.map(Format.money) ?? "cost unavailable")")
        .accessibilityHint("Shows token details")
        .popover(isPresented: detailPresented, arrowEdge: .trailing) {
            TokenDetail(
                title: model.displayTitle,
                input: model.inputTokens,
                cacheRead: model.cacheReadTokens,
                cacheWrite: model.cacheWriteTokens,
                output: model.outputTokens,
                reasoning: model.reasoningTokens,
                total: model.totalTokens,
                cost: model.costUSD,
                subtitle: presentation.provider.displayName
            )
        }
    }
}

private struct TokenDetail: View {
    let title: String
    let input: Int
    var cacheRead: Int? = nil
    var cacheWrite: Int? = nil
    let output: Int
    var reasoning: Int? = nil
    var total: Int? = nil
    let cost: Double?
    let subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
            LabeledContent("Cost", value: cost.map(Format.money) ?? "n/a")
                .font(.callout.weight(.semibold))
            Divider()
            LabeledContent("Input", value: Format.tokens(input))
            if let cacheRead, cacheRead > 0 {
                LabeledContent("Cache read", value: Format.tokens(cacheRead))
            }
            if let cacheWrite, cacheWrite > 0 {
                LabeledContent("Cache write", value: Format.tokens(cacheWrite))
            }
            LabeledContent("Output", value: Format.tokens(output))
            if let reasoning, reasoning > 0 {
                LabeledContent("Reasoning", value: Format.tokens(reasoning))
                Text("Reasoning is included in output totals.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if let total {
                LabeledContent("Total", value: Format.tokens(total))
            }
        }
        .monospacedDigit()
        .padding(14)
        .frame(minWidth: 230)
    }
}

private struct PitSections: View {
    @ObservedObject var model: AppModel
    let openSetup: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let config = model.config, config.hasPits {
                ForEach(model.boards, id: \.code) { board in
                    PitBoardView(board: board, model: model)
                }
                if model.boards.isEmpty {
                    HStack { ProgressView(); Text("Loading your pits...") }
                        .foregroundStyle(.secondary)
                }
            } else {
                FriendsEmptyState(openSetup: openSetup)
            }
        }
    }
}

private struct FriendsEmptyState: View {
    let openSetup: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("FRIENDS")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .tracking(1.2)
            Text("Your crew isn't here yet")
                .font(.callout.weight(.medium))
            Text("One of you starts a pit, everyone else joins with its code.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(action: openSetup) {
                Label("Start or join a pit", systemImage: "person.2.fill")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
        }
    }
}

private struct PitBoardView: View {
    let board: PitBoard
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text((board.name?.isEmpty == false ? board.name : nil) ?? board.code)
                    .font(.headline)
                Spacer()
                Text("UTC")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(.quaternary, in: Capsule())
            }
            ForEach(Array(board.rankedMembers.enumerated()), id: \.element.id) { rank, member in
                MemberRow(rank: rank + 1, member: member) {
                    Task { await model.openMember(pitCode: board.code, member: member) }
                }
            }
        }
    }
}

private struct MemberRow: View {
    @State private var showDetail = false
    let rank: Int
    let member: PitBoard.Member
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Text("\(rank)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 14, alignment: .trailing)
                Text(MemberAvatar.emoji(for: member.handle))
                    .font(.system(size: 13))
                    .frame(width: 22, height: 22)
                    .background(.quaternary.opacity(0.6), in: Circle())
                Text(member.handle)
                    .font(.callout.weight(.medium))
                Spacer()
                VStack(alignment: .trailing, spacing: 1) {
                    Text(Format.money(member.todayUSD))
                        .font(.callout.weight(.semibold))
                    Text("wk \(Format.money(member.weekUSD))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .monospacedDigit()
                if member.streakDays > 0 {
                    Label("\(member.streakDays)", systemImage: "flame.fill")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.orange)
                        .labelStyle(.titleAndIcon)
                }
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .delayedHover($showDetail)
        .popover(isPresented: $showDetail, arrowEdge: .trailing) {
            VStack(alignment: .leading, spacing: 10) {
                Text(member.handle).font(.headline)
                if member.modelsWeek?.isEmpty != false {
                    Text("No model detail this week").foregroundStyle(.secondary)
                } else {
                    ForEach(member.modelsWeek ?? []) { model in
                        TokenDetail(
                            title: model.model,
                            input: model.inputTokens,
                            output: model.outputTokens,
                            cost: model.costUSD,
                            subtitle: nil
                        )
                    }
                }
            }
            .padding(14)
            .frame(minWidth: 240)
        }
    }
}

private struct Footer: View {
    @ObservedObject var model: AppModel
    let openSetup: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 12) {
                if let error = model.errorMessage {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .help(error)
                }
                Text(model.lastUpdated.map { "Updated \(Format.relativeTime(from: $0))" } ?? "Not updated")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if model.isRefreshing { ProgressView().controlSize(.small) }
                Button(action: openSetup) {
                    Image(systemName: "person.badge.plus")
                }
                .buttonStyle(.plain)
                .help("Start or join a pit")
                Button { Task { await model.refresh(forcePit: true) } } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .help("Refresh")
                Button { NSApplication.shared.terminate(nil) } label: {
                    Image(systemName: "power")
                }
                .buttonStyle(.plain)
                .help("Quit brrrn")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
    }
}

private struct MemberDetailView: View {
    let selection: AppModel.Selection
    let isLoading: Bool
    var snapshotMode = false
    let back: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button(action: back) {
                    Label("Back", systemImage: "chevron.left")
                }
                .buttonStyle(.plain)
                Spacer()
                HStack(spacing: 6) {
                    Text(MemberAvatar.emoji(for: selection.member.handle))
                        .font(.system(size: 15))
                    Text(selection.member.handle).font(.headline)
                }
                Spacer()
                Color.clear.frame(width: 45)
            }
            .padding(14)
            Divider()

            detailScroll
        }
        .overlay { if isLoading { ProgressView() } }
    }

    @ViewBuilder
    private var detailScroll: some View {
        if snapshotMode {
            detailContent.frame(maxHeight: .infinity, alignment: .top)
        } else {
            ScrollView { detailContent }
        }
    }

    private var detailContent: some View {
        VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 22) {
                        Stat(label: "TODAY", value: selection.member.todayUSD)
                        Stat(label: "THIS WEEK", value: selection.member.weekUSD)
                        Stat(label: "THIS MONTH", value: selection.member.monthUSD)
                    }

                    DailyHeatmap(
                        title: "16-WEEK BURN CALENDAR",
                        grid: UTCActivityGrid(
                            entries: selection.detail.days,
                            weeks: 16,
                            thresholdUSD: selection.detail.effectiveStreakThresholdUSD
                        )
                    )

            if let top = selection.member.topModel {
                LabeledContent("Top model this week", value: top)
                    .font(.callout)
            }
        }
        .padding(18)
    }
}

private struct Stat: View {
    let label: String
    let value: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(Format.money(value))
                .font(.title3.weight(.bold))
                .monospacedDigit()
        }
    }
}
