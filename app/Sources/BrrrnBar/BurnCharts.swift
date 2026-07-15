import Charts
import SwiftUI
import BrrrnCore

/// 30-day burn trend: one series, area + line, hover crosshair with a
/// date/cost readout in the strip above the plot.
struct BurnTrendChart: View {
    let points: [BurnTrendPoint]
    let streakThresholdUSD: Double
    var days: Binding<Int>?

    @Environment(\.colorScheme) private var colorScheme
    @State private var selectedDateKey: String?

    private var selected: BurnTrendPoint? {
        points.first(where: { $0.dateKey == selectedDateKey })
    }

    private var latest: BurnTrendPoint? { points.last }

    private var average: Double {
        guard !points.isEmpty else { return 0 }
        return points.reduce(0) { $0 + $1.costUSD } / Double(points.count)
    }

    private var peak: BurnTrendPoint? {
        points.max(by: { $0.costUSD < $1.costUSD })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            readout
            chart
            caption
        }
    }

    private var readout: some View {
        let shown = selected ?? latest
        return HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(shown.map { Format.utcDate($0.date) } ?? "No data")
                    .font(.caption.weight(.medium))
                Text(selected == nil ? "Latest day" : "Hovered day")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text(Format.money(shown?.costUSD ?? 0))
                    .font(.callout.weight(.semibold))
                Text("avg \(Format.money(average))/day")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .monospacedDigit()
        }
        .frame(minHeight: 36)
    }

    private var chart: some View {
        let accent = BrrrnPalette.heatmap(.high, colorScheme)
        return Chart(points) { point in
            AreaMark(
                x: .value("Day", point.date, unit: .day),
                y: .value("Burn", point.costUSD)
            )
            .foregroundStyle(accent.opacity(0.16))

            LineMark(
                x: .value("Day", point.date, unit: .day),
                y: .value("Burn", point.costUSD)
            )
            .foregroundStyle(accent)
            .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))

            if point.dateKey == selectedDateKey {
                RuleMark(x: .value("Day", point.date, unit: .day))
                    .foregroundStyle(.tertiary)
                    .lineStyle(StrokeStyle(lineWidth: 1))
                PointMark(
                    x: .value("Day", point.date, unit: .day),
                    y: .value("Burn", point.costUSD)
                )
                .symbolSize(45)
                .foregroundStyle(accent)
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { value in
                AxisGridLine().foregroundStyle(.quaternary)
                AxisValueLabel {
                    if let cost = value.as(Double.self) {
                        Text(Format.money(cost))
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { value in
                AxisValueLabel {
                    if let date = value.as(Date.self) {
                        Text(Format.utcMonthDay(date))
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                }
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
                            let plot = geometry[proxy.plotFrame!]
                            guard plot.contains(location),
                                  let date: Date = proxy.value(atX: location.x - plot.origin.x)
                            else {
                                selectedDateKey = nil
                                return
                            }
                            selectedDateKey = BurnAnalytics.dateKey(date)
                        case .ended:
                            selectedDateKey = nil
                        }
                    }
            }
        }
        .frame(height: 96)
        .accessibilityLabel(accessibilitySummary)
    }

    private var caption: some View {
        HStack(spacing: 6) {
            if let peak, peak.costUSD > 0 {
                Text("Peak \(Format.money(peak.costUSD)) on \(Format.utcMonthDay(peak.date))")
            } else {
                Text("No burn in this window")
            }
            Spacer()
            if let days {
                Text("last")
                RangePicker(selection: days, options: [14, 30, 90])
                Text("UTC")
            } else {
                Text("last \(points.count)d, UTC")
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }

    private var accessibilitySummary: String {
        let total = points.reduce(0) { $0 + $1.costUSD }
        var parts = [
            "Burn trend, last \(points.count) days.",
            "Total \(Format.money(total)), average \(Format.money(average)) per day.",
        ]
        if let peak, peak.costUSD > 0 {
            parts.append("Peak \(Format.money(peak.costUSD)) on \(Format.utcDate(peak.date)).")
        }
        return parts.joined(separator: " ")
    }
}

/// Hour-of-day rhythm: today's burn per UTC hour against the typical recent
/// day. Two series, so both are named in the inline legend.
struct BurnRhythmChart: View {
    let rhythm: BurnRhythm
    let timeZone: TimeZone
    var lookbackDays: Binding<Int>?
    var usesUTC: Binding<Bool>?

    @Environment(\.colorScheme) private var colorScheme
    @State private var selectedHour: Int?

    private var zoneLabel: String { Format.timeZoneLabel(timeZone) }

    private var accent: Color { BrrrnPalette.heatmap(.high, colorScheme) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            readout
            chart
            legend
        }
    }

    private var shownHour: Int? {
        if let selectedHour { return selectedHour }
        return rhythm.peakTypicalHour
    }

    private var readout: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(shownHour.map { String(format: "%02d:00-%02d:59 \(zoneLabel)", $0, $0) } ?? "No data")
                    .font(.caption.weight(.medium))
                Text(selectedHour == nil ? "Typical peak hour" : "Hovered hour")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text("today \(Format.money(shownHour.map { rhythm.todayByHour[$0] } ?? 0))")
                    .font(.callout.weight(.semibold))
                Text("typical \(Format.money(shownHour.map { rhythm.typicalByHour[$0] } ?? 0))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .monospacedDigit()
        }
        .frame(minHeight: 36)
    }

    private var maxValue: Double {
        max(rhythm.todayByHour.max() ?? 0, rhythm.typicalByHour.max() ?? 0)
    }

    private var chart: some View {
        Chart {
            // Today is the filled series; the typical profile is a step
            // line, so neither can bury the other regardless of which is
            // larger at a given hour.
            ForEach(0..<24, id: \.self) { hour in
                BarMark(
                    x: .value("Hour", hour),
                    y: .value("Today", rhythm.todayByHour[hour]),
                    width: .fixed(7)
                )
                .foregroundStyle(accent.opacity(hour == selectedHour ? 1 : 0.82))
                .cornerRadius(2)
            }
            ForEach(0..<24, id: \.self) { hour in
                LineMark(
                    x: .value("Hour", hour),
                    y: .value("Typical", rhythm.typicalByHour[hour])
                )
                .interpolationMethod(.stepCenter)
                .foregroundStyle(Color.secondary.opacity(0.7))
                .lineStyle(StrokeStyle(lineWidth: 1.5))
            }
        }
        .chartXScale(domain: -0.5...23.5)
        // Square-root scale, fitted to the data: burn is spiky, and on a
        // linear axis one $1,000 hour flattens every normal hour into
        // unreadable slivers.
        .chartYScale(domain: 0...max(1, maxValue * 1.05), type: .squareRoot)
        .chartYAxis {
            AxisMarks(position: .trailing, values: yAxisValues) { value in
                AxisGridLine().foregroundStyle(.quaternary)
                AxisValueLabel {
                    if let cost = value.as(Double.self) {
                        Text(Format.money(cost))
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: [0, 6, 12, 18]) { value in
                AxisValueLabel {
                    if let hour = value.as(Int.self) {
                        Text(String(format: "%02d", hour))
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                }
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
                            let plot = geometry[proxy.plotFrame!]
                            guard plot.contains(location),
                                  let hour: Double = proxy.value(atX: location.x - plot.origin.x)
                            else {
                                selectedHour = nil
                                return
                            }
                            selectedHour = min(23, max(0, Int(hour.rounded())))
                        case .ended:
                            selectedHour = nil
                        }
                    }
            }
        }
        .frame(height: 96)
        .accessibilityLabel(accessibilitySummary)
    }

    /// Hand-picked marks that stay legible on the square-root scale: zero,
    /// a low reference near the typical range, and the peak.
    private var yAxisValues: [Double] {
        let top = max(1, maxValue * 1.05)
        return [0, top / 16, top / 4, top]
    }

    private var legend: some View {
        HStack(spacing: 12) {
            HStack(spacing: 4) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(accent)
                    .frame(width: 8, height: 8)
                Text("Today")
            }
            HStack(spacing: 4) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.secondary.opacity(0.7))
                    .frame(width: 10, height: 2)
                Text("Typical avg")
                if let lookbackDays {
                    RangePicker(selection: lookbackDays, options: [7, 30, 90])
                        .help("Averaged over the \(rhythm.activeDays) active days in this window")
                }
            }
            Spacer()
            if let usesUTC {
                Button {
                    usesUTC.wrappedValue.toggle()
                } label: {
                    Text("\(zoneLabel) hours")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(.quaternary, in: Capsule())
                }
                .buttonStyle(.plain)
                .help("Switch the rhythm clock between your timezone and UTC")
            } else {
                Text("\(zoneLabel) hours")
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }

    private var accessibilitySummary: String {
        guard let peak = rhythm.peakTypicalHour else {
            return "Burn rhythm by hour. No recent hourly data."
        }
        return "Burn rhythm by hour. Typical peak at \(peak):00 \(zoneLabel), "
            + "\(Format.money(rhythm.typicalByHour[peak])) on an average day."
    }
}

/// Compact window cycler shown inside chart captions: click to advance
/// through the options.
struct RangePicker: View {
    @Binding var selection: Int
    let options: [Int]

    var body: some View {
        Button {
            let index = options.firstIndex(of: selection) ?? 0
            selection = options[(index + 1) % options.count]
        } label: {
            Text("\(selection)d")
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(.quaternary, in: Capsule())
        }
        .buttonStyle(.plain)
        .help("Cycle the window: \(options.map { "\($0)d" }.joined(separator: " / "))")
    }
}
