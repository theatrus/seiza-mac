import SwiftUI

/// The stack-depth chart: measured relative SNR against the square-root
/// ideal, on log-log axes. The ideal is anchored at the shallowest measured
/// point so the curves coincide at the left edge.
struct StackSnrChartView: View {
    let points: [StackSnrPlotPoint]

    var body: some View {
        VStack(spacing: 6) {
            GeometryReader { proxy in
                let geometry = StackSnrPlotLayout.create(
                    points: points,
                    width: proxy.size.width,
                    height: proxy.size.height)
                if geometry.isEmpty {
                    Text("SNR measurements appear as the stack deepens.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(
                            width: proxy.size.width,
                            height: proxy.size.height)
                } else {
                    Canvas { context, _ in
                        if geometry.ideal.count > 1 {
                            var ideal = Path()
                            ideal.addLines(geometry.ideal)
                            context.stroke(
                                ideal,
                                with: .color(.secondary.opacity(0.8)),
                                style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                        }
                        if geometry.measured.count > 1 {
                            var measured = Path()
                            measured.addLines(geometry.measured)
                            context.stroke(
                                measured,
                                with: .color(.accentColor),
                                style: StrokeStyle(lineWidth: 2.5, lineJoin: .round))
                        }
                        for point in geometry.measured {
                            let marker = CGRect(
                                x: point.x - 3.5, y: point.y - 3.5,
                                width: 7, height: 7)
                            context.fill(
                                Path(ellipseIn: marker), with: .color(.accentColor))
                            context.stroke(
                                Path(ellipseIn: marker),
                                with: .color(.white),
                                lineWidth: 1)
                        }
                    }
                }
            }
            .frame(minHeight: 150)

            legend
        }
    }

    private var legend: some View {
        HStack(spacing: 16) {
            HStack(spacing: 5) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.accentColor)
                    .frame(width: 18, height: 3)
                Text("Measured")
            }
            HStack(spacing: 5) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(.secondary)
                    .frame(width: 18, height: 2)
                Text("Ideal square-root")
            }
            Spacer()
            if let range = frameRangeText {
                Text(range)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private var frameRangeText: String? {
        let usable = points.filter { $0.frames > 0 && $0.snr.isFinite && $0.snr > 0 }
        guard let minimum = usable.map(\.frames).min(),
            let maximum = usable.map(\.frames).max()
        else { return nil }
        return "\(minimum)–\(maximum) frames"
    }
}
