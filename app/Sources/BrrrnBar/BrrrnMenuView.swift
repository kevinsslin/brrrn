import SwiftUI
import Charts
import BrrrnCore

struct BrrrnMenuView: View {
    @ObservedObject var model: AppModel
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Group {
            if let selection = model.selection {
                MemberDetailView(selection: selection, isLoading: model.isLoadingMember) {
                    model.closeMember()
                }
            } else {
                mainContent
            }
        }
        .background(.background)
    }

    private var mainContent: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    MeHeader(report: model.report)
                    Divider()
                    ModelSection(models: model.weekModels)
                    Divider()
                    PitSections(model: model)
                }
                .padding(18)
            }
            Footer(model: model)
        }
        .overlay {
            if model.report == nil && model.isRefreshing {
                ProgressView("Reading local burn...")
                    .padding(20)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
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

private struct SourceValue: View {
    @Environment(\.colorScheme) private var colorScheme
    let name: String
    let value: Double
    let source: String

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(source == "claude" ? BrrrnPalette.claude(colorScheme) : BrrrnPalette.codex(colorScheme))
                .frame(width: 7, height: 7)
            Text("\(name) \(Format.money(value))")
        }
    }
}

private struct ModelSection: View {
    let models: [BurnReport.ModelUsage]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("THIS WEEK BY MODEL")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .tracking(1.2)
            if models.isEmpty {
                Text("No model usage this week")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(models) { model in
                    ModelRow(model: model)
                }
            }
        }
    }
}

private struct ModelRow: View {
    @Environment(\.colorScheme) private var colorScheme
    @State private var showDetail = false
    let model: BurnReport.ModelUsage

    var sourceColor: Color {
        model.source == "claude-code" ? BrrrnPalette.claude(colorScheme) : BrrrnPalette.codex(colorScheme)
    }

    var body: some View {
        HStack(spacing: 9) {
            Circle().fill(sourceColor).frame(width: 7, height: 7)
            Text(model.model)
                .font(.callout)
                .lineLimit(1)
            Spacer()
            Text(model.costUSD.map(Format.money) ?? "n/a")
                .font(.callout.weight(.semibold))
                .monospacedDigit()
        }
        .contentShape(Rectangle())
        .onHover { showDetail = $0 }
        .popover(isPresented: $showDetail, arrowEdge: .trailing) {
            TokenDetail(
                title: model.model,
                input: model.inputTokens + (model.cacheReadTokens ?? 0) + (model.cacheWriteTokens ?? 0),
                output: model.outputTokens,
                cost: model.costUSD,
                subtitle: model.speed
            )
        }
    }
}

private struct TokenDetail: View {
    let title: String
    let input: Int
    let output: Int
    let cost: Double?
    let subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
            LabeledContent("Input", value: Format.tokens(input))
            LabeledContent("Output", value: Format.tokens(output))
            LabeledContent("Cost", value: cost.map(Format.money) ?? "n/a")
        }
        .monospacedDigit()
        .padding(14)
        .frame(minWidth: 220)
    }
}

private struct PitSections: View {
    @ObservedObject var model: AppModel

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
                VStack(alignment: .leading, spacing: 6) {
                    Text("FRIENDS")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .tracking(1.2)
                    Text("No pit configured")
                        .font(.callout.weight(.medium))
                    Text("Run `brrrn pit join <code> --as <you>`")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
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
                    .frame(width: 18, alignment: .trailing)
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
        .onHover { showDetail = $0 }
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
    let back: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @State private var hoveredDate: Date?

    private var series: [DailyPoint] { selection.detail.series(days: 14) }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button(action: back) {
                    Label("Back", systemImage: "chevron.left")
                }
                .buttonStyle(.plain)
                Spacer()
                Text(selection.member.handle).font(.headline)
                Spacer()
                Color.clear.frame(width: 45)
            }
            .padding(14)
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 22) {
                        Stat(label: "TODAY", value: selection.member.todayUSD)
                        Stat(label: "THIS WEEK", value: selection.member.weekUSD)
                        Stat(label: "THIS MONTH", value: selection.member.monthUSD)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("LAST 14 UTC DAYS")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .tracking(1.1)
                            Spacer()
                            if let hoveredDate,
                               let point = series.min(by: { abs($0.date.timeIntervalSince(hoveredDate)) < abs($1.date.timeIntervalSince(hoveredDate)) }) {
                                Text("\(point.date.formatted(.dateTime.month(.abbreviated).day()))  \(Format.money(point.costUSD))")
                                    .font(.caption.weight(.semibold))
                                    .monospacedDigit()
                            }
                        }
                        Chart(series) { point in
                            BarMark(
                                x: .value("Day", point.date, unit: .day),
                                y: .value("Cost", point.costUSD),
                                width: .ratio(0.72)
                            )
                            .foregroundStyle(BrrrnPalette.chart(colorScheme))
                            .cornerRadius(4)
                            if let hoveredDate,
                               BurnReport.DailyEntry.utcCalendar.isDate(point.date, inSameDayAs: hoveredDate) {
                                RuleMark(x: .value("Selected", point.date, unit: .day))
                                    .foregroundStyle(.secondary.opacity(0.45))
                            }
                        }
                        .chartYAxis {
                            AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                                AxisGridLine().foregroundStyle(.quaternary)
                                AxisValueLabel {
                                    if let amount = value.as(Double.self) {
                                        Text(Format.money(amount)).font(.caption2)
                                    }
                                }
                            }
                        }
                        .chartXAxis {
                            AxisMarks(values: .stride(by: .day, count: 4)) { value in
                                AxisValueLabel(format: .dateTime.day())
                            }
                        }
                        .chartOverlay { proxy in
                            GeometryReader { geometry in
                                Rectangle()
                                    .fill(.clear)
                                    .contentShape(Rectangle())
                                    .onContinuousHover { phase in
                                        switch phase {
                                        case .active(let location):
                                            if let plotFrame = proxy.plotFrame {
                                                let plotX = location.x - geometry[plotFrame].origin.x
                                                hoveredDate = proxy.value(atX: plotX, as: Date.self)
                                            }
                                        case .ended:
                                            hoveredDate = nil
                                        }
                                    }
                            }
                        }
                        .frame(height: 210)
                    }

                    if let top = selection.member.topModel {
                        LabeledContent("Top model this week", value: top)
                            .font(.callout)
                    }
                    LabeledContent("Streak", value: "\(selection.member.streakDays) days ≥ $5")
                        .font(.callout)

                    VStack(alignment: .leading, spacing: 6) {
                        Text("DAILY TABLE")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .tracking(1.1)
                        ForEach(selection.detail.days.suffix(14), id: \.date) { day in
                            HStack {
                                Text(day.date).foregroundStyle(.secondary)
                                Spacer()
                                Text(Format.tokens(day.tokens)).foregroundStyle(.secondary)
                                Text(Format.money(day.costUSD)).frame(width: 82, alignment: .trailing)
                            }
                            .font(.caption)
                            .monospacedDigit()
                        }
                    }
                }
                .padding(18)
            }
        }
        .overlay { if isLoading { ProgressView() } }
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
