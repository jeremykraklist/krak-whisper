import SwiftUI

/// Animated waveform visualization for audio levels.
struct WaveformView: View {
    let audioLevels: [Float]
    let isRecording: Bool

    private let barCount = 50
    private let barSpacing: CGFloat = 2

    var body: some View {
        GeometryReader { geometry in
            HStack(alignment: .center, spacing: barSpacing) {
                ForEach(0..<barCount, id: \.self) { index in
                    WaveformBar(
                        level: levelForBar(at: index),
                        isRecording: isRecording,
                        maxHeight: geometry.size.height
                    )
                }
            }
        }
        .frame(height: 80)
    }

    private func levelForBar(at index: Int) -> Float {
        guard !audioLevels.isEmpty else {
            return isRecording ? Float.random(in: 0.02...0.08) : 0.02
        }
        let totalLevels = audioLevels.count
        let displayStart = max(0, totalLevels - barCount)
        let levelIndex = displayStart + index
        guard levelIndex < totalLevels else { return 0.02 }
        return max(0.02, audioLevels[levelIndex])
    }
}

/// Individual bar in the waveform.
struct WaveformBar: View {
    let level: Float
    let isRecording: Bool
    let maxHeight: CGFloat

    private let minHeightFraction: CGFloat = 0.05

    var body: some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(barColor)
            .frame(
                maxWidth: .infinity,
                minHeight: maxHeight * minHeightFraction,
                idealHeight: maxHeight * CGFloat(level),
                maxHeight: maxHeight
            )
            .animation(.easeInOut(duration: 0.1), value: level)
    }

    private var barColor: some ShapeStyle {
        if isRecording {
            return AnyShapeStyle(
                LinearGradient(
                    colors: [.red.opacity(0.6), .red],
                    startPoint: .bottom,
                    endPoint: .top
                )
            )
        } else {
            return AnyShapeStyle(Color.gray.opacity(0.3))
        }
    }
}

/// Pulsing waveform for the transcribing state.
struct PulsingWaveformView: View {
    let isActive: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            Canvas { context, size in
                let midY: CGFloat = size.height / 2
                let barWidth: CGFloat = 3
                let spacing: CGFloat = 2
                let totalBarWidth: CGFloat = barWidth + spacing
                let barCount: Int = Int(size.width / totalBarWidth)
                let time: Double = timeline.date.timeIntervalSinceReferenceDate

                for i in 0..<barCount {
                    let x: CGFloat = CGFloat(i) * totalBarWidth
                    let normalizedX: Double = Double(i) / Double(barCount)
                    let wave: Double = sin(normalizedX * Double.pi * 4.0 + time * 3.0) * 0.5 + 0.5
                    let amplitude: Double = isActive ? 0.8 : 0.15
                    let height: CGFloat = max(4, size.height * CGFloat(wave * amplitude))

                    let rect = CGRect(
                        x: x, y: midY - height / 2,
                        width: barWidth, height: height
                    )
                    let opacity: Double = isActive
                        ? 0.6 + wave * 0.4
                        : 0.2 + wave * 0.1
                    let color: Color = isActive ? .blue.opacity(opacity) : .gray.opacity(opacity)
                    context.fill(
                        Path(roundedRect: rect, cornerRadius: 1.5),
                        with: .color(color)
                    )
                }
            }
        }
        .frame(height: 80)
    }
}
