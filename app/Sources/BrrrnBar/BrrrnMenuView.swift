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
    @AppStorage("rootTab") private var rootTabRaw = "me"

    private var mainContent: some View {
        VStack(spacing: 0) {
            TabStrip(selection: $rootTabRaw, options: [("me", "Me"), ("pits", "Pits")])
                .padding(.horizontal, 18)
                .padding(.top, 12)
                .padding(.bottom, 2)
            if rootTabRaw == "pits" && !snapshotMode {
                ScrollView { sections }
                    .onAppear { Task { await model.refreshPitsIfStale() } }
            } else {
                // The Me page fits the window: only the by-model list
                // scrolls, internally, so the menu never shows an outer bar.
                sections
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
            if rootTabRaw == "pits" {
                PitSections(model: model) { showPitSetup = true }
            } else {
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
                ModelSection(model: model, snapshotMode: snapshotMode)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct MeHeader: View {
    let report: BurnReport?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
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
                        badge: hour.isCurrent ? "SET TODAY" : nil
                    )
                }
                if let day = records.bestDay {
                    RecordRow(
                        icon: "sun.max.fill",
                        title: "Biggest day",
                        value: Format.money(day.costUSD),
                        detail: Format.utcMonthDay(day.date) + " UTC",
                        badge: day.isCurrent ? "SET TODAY" : nil
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
                        badge: records.longestStreakIsCurrent ? "ONGOING" : nil
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
    /// "SET TODAY" / "ONGOING" when the record is being made right now.
    var badge: String?

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
            if let badge {
                Text(badge)
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
        .accessibilityLabel("\(title), \(value), \(detail)\(badge.map { ", \($0.lowercased())" } ?? "")")
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
    var snapshotMode = false

    @AppStorage("modelsPeriod") private var periodRaw = AppModel.ModelPeriod.week.rawValue

    private var period: AppModel.ModelPeriod {
        AppModel.ModelPeriod(rawValue: periodRaw) ?? .week
    }

    private var models: [BurnReport.ModelUsage] { model.models(for: period) }

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
                Spacer(minLength: 0)
            } else if snapshotMode {
                ForEach(models) { model in
                    ModelRow(model: model)
                }
            } else {
                // The list scrolls inside its own box, so the Me page never
                // needs the window scrollbar.
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(models) { model in
                            ModelRow(model: model)
                        }
                    }
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .topLeading)
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
                subtitle: presentation.provider.displayName,
                fastCost: model.fastCostUSD,
                fastTokens: model.fastTotalTokens
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
    var fastCost: Double = 0
    var fastTokens: Int = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
            LabeledContent("Cost", value: cost.map(Format.money) ?? "n/a")
                .font(.callout.weight(.semibold))
            if fastCost > 0 || fastTokens > 0 {
                Text("standard \(Format.money(max(0, (cost ?? 0) - fastCost))) + fast \(Format.money(fastCost))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
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
                HStack {
                    Text("YOUR PITS")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .tracking(1.2)
                    if let synced = model.lastPitRefresh {
                        Text("synced \(Format.relativeTime(from: synced))")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                    RenameButton(model: model)
                    Button(action: openSetup) {
                        Label("New", systemImage: "plus")
                            .font(.caption.weight(.semibold))
                    }
                    .controlSize(.small)
                }
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

private struct PitTitleButton: View {
    let board: PitBoard
    @ObservedObject var model: AppModel
    @State private var isOpen = false
    @State private var name = ""
    @State private var isWorking = false
    @State private var errorText: String?

    var body: some View {
        Button {
            name = board.name ?? ""
            isOpen.toggle()
        } label: {
            Image(systemName: "pencil")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .buttonStyle(.plain)
        .help("Rename this pit for everyone")
        .popover(isPresented: $isOpen, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                Text("PIT NAME")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .tracking(1.1)
                TextField("night shift", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)
                    .onSubmit { Task { await save() } }
                if let errorText {
                    Text(errorText)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Text("Everyone in the pit sees the new name.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Spacer()
                    Button {
                        Task { await save() }
                    } label: {
                        if isWorking {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("Save")
                        }
                    }
                    .disabled(isWorking || name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(14)
            .frame(width: 260)
        }
    }

    private func save() async {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        isWorking = true
        errorText = nil
        defer { isWorking = false }
        do {
            try await model.renamePit(code: board.code, to: trimmed)
            isOpen = false
        } catch {
            errorText = error.localizedDescription
        }
    }
}

private struct RenameButton: View {
    @ObservedObject var model: AppModel
    @State private var isOpen = false
    @State private var name = ""
    @State private var isWorking = false
    @State private var errorText: String?

    var body: some View {
        Button {
            isOpen.toggle()
        } label: {
            Image(systemName: "pencil")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help("Change your display name (your handle never changes)")
        .popover(isPresented: $isOpen, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                Text("DISPLAY NAME")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .tracking(1.1)
                TextField("Kevin the Flame", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)
                    .onSubmit { Task { await save() } }
                if let errorText {
                    Text(errorText)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Text("Shown on every board; @\(model.config?.handle ?? "you") stays.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Spacer()
                    Button {
                        Task { await save() }
                    } label: {
                        if isWorking {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("Save")
                        }
                    }
                    .disabled(isWorking || name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(14)
            .frame(width: 250)
        }
    }

    private func save() async {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        isWorking = true
        errorText = nil
        defer { isWorking = false }
        do {
            try await model.renameDisplay(to: trimmed)
            isOpen = false
            name = ""
        } catch {
            errorText = error.localizedDescription
        }
    }
}

private struct PitBoardView: View {
    let board: PitBoard
    @ObservedObject var model: AppModel
    @State private var showInvite = false
    @State private var copiedInvite = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text((board.name?.isEmpty == false ? board.name : nil) ?? board.code)
                    .font(.headline)
                    .lineLimit(1)
                PitTitleButton(board: board, model: model)
                Spacer()
                Button {
                    showInvite.toggle()
                } label: {
                    Image(systemName: "person.crop.circle.badge.plus")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Show this pit's invite code")
                .popover(isPresented: $showInvite, arrowEdge: .bottom) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("INVITE CODE")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .tracking(1.1)
                        HStack(spacing: 10) {
                            Text(board.code)
                                .font(.title3.weight(.semibold).monospaced())
                                .textSelection(.enabled)
                            Button {
                                let invite = PitInvite.compose(
                                    code: board.code,
                                    hubURL: model.config?.hubURL
                                )
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(invite, forType: .string)
                                copiedInvite = true
                            } label: {
                                Label(copiedInvite ? "Copied" : "Copy invite",
                                      systemImage: copiedInvite ? "checkmark" : "doc.on.doc")
                            }
                        }
                        Text("The invite carries the code and your hub; pasting it in Join is all a friend needs.")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(14)
                    .onDisappear { copiedInvite = false }
                }
                Text("UTC")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(.quaternary, in: Capsule())
            }
            ForEach(Array(board.rankedMembers.enumerated()), id: \.element.id) { rank, member in
                MemberRow(
                    rank: rank + 1,
                    member: member,
                    isWeeklyKing: member.handle == board.weeklyKing
                ) {
                    Task { await model.openMember(pitCode: board.code, member: member) }
                }
            }
        }
    }
}

private struct MemberRow: View {
    let rank: Int
    let member: PitBoard.Member
    var isWeeklyKing = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Group {
                    if rank <= 3 && member.todayUSD > 0 {
                        Text(["🥇", "🥈", "🥉"][rank - 1])
                            .font(.system(size: 12))
                    } else {
                        Text("\(rank)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 16, alignment: .trailing)
                Text(MemberAvatar.emoji(for: member.handle))
                    .font(.system(size: 13))
                    .frame(width: 22, height: 22)
                    .background(.quaternary.opacity(0.6), in: Circle())
                Text(member.boardName)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                if isWeeklyKing {
                    Image(systemName: "crown.fill")
                        .font(.caption)
                        .foregroundStyle(.yellow)
                        .help("This week's top burner")
                }
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
        .accessibilityHint("Opens this member's history")
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
                    Text(selection.member.boardName).font(.headline)
                    if selection.member.boardName != selection.member.handle {
                        Text("@\(selection.member.handle)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Color.clear.frame(width: 45, height: 1)
            }
            .padding(14)
            Divider()

            detailScroll
        }
        // Pin to the top and fill the window; otherwise the stack floats
        // vertically centered with dead space above the Back header.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .overlay { if isLoading { ProgressView() } }
    }

    /// Most recent day this member actually burned, from their history.
    private var lastBurned: Date? {
        selection.detail.days
            .filter { $0.costUSD > 0 }
            .compactMap(\.dateValue)
            .max()
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

            if selection.member.modelsWeek?.isEmpty == false {
                VStack(alignment: .leading, spacing: 8) {
                    Text("THIS WEEK BY MODEL")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .tracking(1.2)
                    ForEach(selection.member.modelsWeek ?? []) { usage in
                        HStack {
                            Text(usage.model)
                                .font(.callout)
                                .lineLimit(1)
                            Spacer(minLength: 8)
                            Text(Format.tokens(usage.inputTokens + usage.outputTokens))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(usage.costUSD.map(Format.money) ?? "n/a")
                                .font(.callout.weight(.semibold))
                                .frame(minWidth: 64, alignment: .trailing)
                        }
                        .monospacedDigit()
                    }
                }
            } else if let top = selection.member.topModel {
                LabeledContent("Top model this week", value: top)
                    .font(.callout)
            }

            if let lastBurned {
                Label("Last burned \(Format.utcMonthDay(lastBurned)) UTC", systemImage: "clock")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
