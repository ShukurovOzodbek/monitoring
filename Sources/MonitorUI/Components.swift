import AppKit
import SwiftUI
import Charts
import MonitorCore

struct Panel<Content: View>: View {
    let title: String
    let symbol: String
    let tint: Color
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(title, systemImage: symbol)
                .font(.headline)
                .foregroundStyle(tint)
            content
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(.primary.opacity(0.08)) }
    }
}

struct MetricChart: View {
    struct Series {
        let name: String
        let points: [MetricPoint]
        let color: Color
    }

    var series: [Series]
    var compact = false
    var stacked = false
    var range: ClosedRange<Double>? = nil
    var format: (Double) -> String = Format.decimal

    var body: some View {
        if series.allSatisfy({ $0.points.isEmpty }) {
            Text("No history yet")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: compact ? 40 : 128)
        } else if compact && !stacked {
            Canvas { context, size in
                let points = series.flatMap(\.points)
                guard let first = points.map(\.date).min(), let last = points.map(\.date).max() else { return }
                let duration = last.timeIntervalSince(first)
                let bounds = range ?? 0...max(0, points.map(\.value).max() ?? 0)
                let span = bounds.upperBound - bounds.lowerBound
                for line in series {
                    let positions = line.points.map { point in
                        CGPoint(x: duration > 0 ? point.date.timeIntervalSince(first) / duration * size.width : size.width / 2,
                                y: span > 0 ? (bounds.upperBound - point.value) / span * size.height : size.height)
                    }
                    guard let start = positions.first else { continue }
                    var path = Path()
                    path.move(to: start)
                    path.addLines(Array(positions.dropFirst()))
                    context.stroke(path, with: .color(line.color),
                                   style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                }
            }
            .padding(.vertical, 1)
            .frame(height: 40)
        } else {
            let chart = Chart {
                ForEach(series, id: \.name) { line in
                    ForEach(line.points) { point in
                        if stacked {
                            AreaMark(x: .value("Time", point.date), y: .value("Value", point.value), stacking: .standard)
                                .foregroundStyle(by: .value("Metric", line.name))
                        } else {
                            LineMark(x: .value("Time", point.date), y: .value("Value", point.value),
                                     series: .value("Metric", line.name))
                                .foregroundStyle(by: .value("Metric", line.name))
                                .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                        }
                    }
                }
            }
            .chartForegroundStyleScale(domain: series.map(\.name), range: series.map(\.color))
            .chartLegend(compact || series.count < 2 ? .hidden : .visible)
            .chartXAxis(compact ? .hidden : .visible)
            .chartYAxis {
                if !compact {
                    AxisMarks(values: .automatic(desiredCount: 4)) { value in
                        AxisGridLine()
                        AxisValueLabel {
                            if let number = value.as(Double.self) { Text(format(number)) }
                        }
                    }
                }
            }
            .frame(height: compact ? 40 : 156)
            if let range {
                chart.chartYScale(domain: range)
            } else {
                chart
            }
        }
    }
}

struct TopProcesses: View {
    @Environment(MonitorStore.self) private var store
    let sort: MonitorStore.ProcessSort
    var limit = 5

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Top processes").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            let processes = store.topProcesses(by: sort, limit: limit)
            if processes.isEmpty { Text("No processes available").foregroundStyle(.secondary) }
            ForEach(processes) { process in
                HStack {
                    Image(nsImage: ProcessIcons.image(bundle: process.appBundlePath, executable: process.executablePath))
                        .resizable().frame(width: 16, height: 16)
                        .accessibilityHidden(true)
                    Text(process.name).lineLimit(1)
                    Spacer()
                    Text(value(process)).monospacedDigit().foregroundStyle(.secondary)
                }
            }
        }
        .font(.callout)
    }

    private func value(_ process: ProcessSample) -> String {
        switch sort {
        case .cpu: Format.percent(process.cpuPercent)
        case .memory: Format.bytes(process.memory)
        case .network: Format.rate(process.networkInRate + process.networkOutRate)
        case .disk:
            if let read = process.diskReadRate, let write = process.diskWriteRate { Format.rate(read + write) }
            else { "—" }
        case .name, .pid: String(process.pid)
        }
    }
}

@MainActor
enum ProcessIcons {
    private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 512
        return cache
    }()
    private static let colorSpace = NSScreen.main?.colorSpace?.cgColorSpace
        ?? CGColorSpace(name: CGColorSpace.sRGB)!
    private static let generic = NSWorkspace.shared.icon(for: .unixExecutable)

    static func image(bundle: String?, executable: String?, size: Int = 16) -> NSImage {
        let path = bundle ?? executable
        let key = "\(size):\(path ?? "")" as NSString
        if let icon = cache.object(forKey: key) { return icon }

        let source = if let path, FileManager.default.fileExists(atPath: path) {
            NSWorkspace.shared.icon(forFile: path)
        } else {
            generic
        }
        let pixels = size * 2
        let bitmap = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8,
                               bytesPerRow: 0, space: colorSpace,
                               bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        guard let bitmap else { return source }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: bitmap, flipped: false)
        NSGraphicsContext.current?.imageInterpolation = .high
        source.draw(in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
        NSGraphicsContext.restoreGraphicsState()

        guard let raster = bitmap.makeImage() else { return source }
        let icon = NSImage(cgImage: raster, size: NSSize(width: size, height: size))
        cache.setObject(icon, forKey: key)
        return icon
    }
}

struct Breakdown: View {
    struct Part: Identifiable {
        let name: String
        let bytes: UInt64
        let color: Color
        var id: String { name }
    }

    let parts: [Part]

    var body: some View {
        let total = parts.reduce(0.0) { $0 + Double($1.bytes) }
        GeometryReader { geometry in
            HStack(spacing: 0) {
                ForEach(parts) { part in
                    part.color.frame(width: total > 0 ? geometry.size.width * Double(part.bytes) / total : 0)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary)
            .clipShape(.capsule)
        }
        .frame(height: 14)
        .accessibilityHidden(true)
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), alignment: .leading)], alignment: .leading, spacing: 10) {
            ForEach(parts) { part in
                LabeledContent {
                    Text(Format.bytes(part.bytes)).monospacedDigit()
                } label: {
                    Label { Text(part.name) } icon: {
                        Circle().fill(part.color).frame(width: 8, height: 8)
                    }
                }
            }
        }
        .font(.callout)
    }
}

#if DEBUG && !MONITORING_SKIP_PREVIEWS
#Preview("Panel") {
    Panel(title: "CPU", symbol: "cpu", tint: .cyan) { TopProcesses(sort: .cpu) }
        .padding().frame(width: 360).environment(PreviewData.store)
}
#Preview("Chart") {
    MetricChart(series: [.init(name: "CPU", points: PreviewData.store.history.cpu, color: .cyan)])
        .padding().frame(width: 420).environment(PreviewData.store)
}
#Preview("Top processes") {
    TopProcesses(sort: .memory).padding().frame(width: 340).environment(PreviewData.store)
}
#Preview("Breakdown") {
    let memory = PreviewData.store.memory
    Breakdown(parts: [.init(name: "Used", bytes: memory.used, color: .purple),
                             .init(name: "Cached", bytes: memory.cachedFiles, color: .cyan),
                             .init(name: "Free", bytes: memory.free, color: .gray)])
        .padding().frame(width: 480).environment(PreviewData.store)
}
#endif
