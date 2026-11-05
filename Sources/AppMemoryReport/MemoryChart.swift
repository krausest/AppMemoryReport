import Charts
import MemoryCore
import SwiftUI

private let blue = Color(red: 0.15, green: 0.35, blue: 0.95)

/// History of one row (or of system RAM): a deep blue line on a light grey background with
/// black text, in light and dark mode alike. Hovering shows the nearest sample in the header.
struct MemoryChart: View {
    let title: String
    let value: String
    let samples: [MemorySample]
    /// Position of the pointer over the plot, nil when it is outside.
    @Binding var hoverDate: Date?

    private var hovered: MemorySample? { Self.nearest(to: hoverDate, in: samples) }

    /// The sample closest to `date`.
    static func nearest(to date: Date?, in samples: [MemorySample]) -> MemorySample? {
        guard let date else { return nil }
        return samples.min { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .lineLimit(1)
                Spacer()
                if let hovered {
                    Text(hovered.date.formatted(date: .omitted, time: .standard))
                        .opacity(0.6)
                    Text(formatBytes(hovered.bytes))
                        .monospacedDigit()
                } else {
                    Text(value)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .animation(.snappy, value: value)
                }
            }
            .font(.callout)
            if samples.count < 2 {
                ContentUnavailableView(localized("Collecting data…"), systemImage: "chart.xyaxis.line")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                chart
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundStyle(.black)
        .background(Color(red: 244 / 255, green: 245 / 255, blue: 245 / 255))
        .environment(\.colorScheme, .light)
    }

    private var chart: some View {
        let (domain, ticks) = Self.scale(samples.map { Double($0.bytes) })
        let segments = Self.segments(samples)
        let segmentSizes = Dictionary(segments.map { ($0, 1) }, uniquingKeysWith: +)
        return Chart {
            ForEach(Array(zip(samples, segments)), id: \.0.id) { sample, segment in
                AreaMark(x: .value("Time", sample.date),
                         yStart: .value("Memory", domain.lowerBound),
                         yEnd: .value("Memory", Double(sample.bytes)),
                         series: .value("Segment", segment))
                    .foregroundStyle(LinearGradient(colors: [blue.opacity(0.45), blue.opacity(0.02)],
                                                    startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.monotone)
                LineMark(x: .value("Time", sample.date), y: .value("Memory", Double(sample.bytes)),
                         series: .value("Segment", segment))
                    .foregroundStyle(blue)
                    .lineStyle(StrokeStyle(lineWidth: 2))
                    .interpolationMethod(.monotone)
                // A lone sample between two pauses has no line to show it.
                if segmentSizes[segment] == 1 {
                    PointMark(x: .value("Time", sample.date), y: .value("Memory", Double(sample.bytes)))
                        .foregroundStyle(blue)
                        .symbolSize(20)
                }
            }
            if let hovered {
                RuleMark(x: .value("Time", hovered.date))
                    .foregroundStyle(.black.opacity(0.35))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                PointMark(x: .value("Time", hovered.date), y: .value("Memory", Double(hovered.bytes)))
                    .foregroundStyle(blue)
                    .symbolSize(50)
            }
        }
        .chartXSelection(value: $hoverDate)
        .chartYScale(domain: domain)
        .chartYAxis {
            AxisMarks(values: ticks) { value in
                AxisGridLine()
                    .foregroundStyle(.black.opacity(0.2))
                AxisValueLabel {
                    if let bytes = value.as(Double.self) {
                        Text((bytes / 1_048_576).formatted(.number.grouping(.never)) + " MB")
                            .foregroundStyle(.black)
                    }
                }
            }
        }
        .chartXAxis {
            // Aligned keeps the outer labels inside the plot; seconds while the history is short.
            AxisMarks(preset: .aligned, values: .automatic(desiredCount: 4)) { _ in
                AxisGridLine()
                    .foregroundStyle(.black.opacity(0.2))
                AxisValueLabel(format: samples.last!.date.timeIntervalSince(samples[0].date) < 300
                    ? .dateTime.hour().minute().second() : .dateTime.hour().minute())
                    .foregroundStyle(.black)
            }
        }
        .padding(.top, 6)  // keeps the top y label clear of the header
    }

    /// Line segment of each sample. A pause in the measurements (window hidden, Mac asleep,
    /// manual refresh) starts a new one, so the line doesn't bridge it with a made-up slope.
    /// A pause is a gap of more than three times the usual spacing, and at least a minute.
    static func segments(_ samples: [MemorySample]) -> [Int] {
        let gaps = zip(samples, samples.dropFirst()).map { $1.date.timeIntervalSince($0.date) }
        guard !gaps.isEmpty else { return samples.map { _ in 0 } }
        let limit = max(3 * gaps.sorted()[gaps.count / 2], 60)
        var segment = 0
        return [0] + gaps.map { gap in
            if gap > limit { segment += 1 }
            return segment
        }
    }

    /// Y range and gridlines at round MB steps (1, 2 or 5 × 10ⁿ). Not from zero: changes of
    /// a few MB in a 3 GB browser should be visible.
    private static func scale(_ values: [Double]) -> (ClosedRange<Double>, [Double]) {
        let mb = 1_048_576.0
        let low = values.min()! / mb, high = values.max()! / mb
        let rough = max((high - low) / 3, high * 0.002, 1)
        let magnitude = pow(10, floor(log10(rough)))
        let step = [1.0, 2, 5, 10].map { $0 * magnitude }.first { $0 >= rough }!
        // A quarter step of headroom, so the line never runs along the edge.
        let lower = max(0, floor((low - step / 4) / step) * step)
        let upper = ceil((high + step / 4) / step) * step
        let ticks = stride(from: lower, through: upper, by: step).map { $0 * mb }
        return (lower * mb...upper * mb, ticks)
    }
}
