import SwiftUI

/// Compact waveform visualization for the keyboard extension.
///
/// Shows a row of animated bars that respond to audio levels. Designed to
/// fit within the constrained height of a keyboard extension (~216pt).
struct AudioLevelView: View {
    let levels: [Float]
    let isRecording: Bool

    private let barCount = 30
    private let barSpacing: CGFloat = 1.5

    var body: some View {
        GeometryReader { geometry in
            HStack(alignment: .center, spacing: barSpacing) {
                ForEach(0..<barCount, id: \.self) { index in
                    AudioBar(
                        level: levelForBar(at: index),
                        isRecording: isRecording,
                        maxHeight: geometry.size.height
                    )
                }
            }
        }
        .frame(height: 40)
    }

    private func levelForBar(at index: Int) -> Float {
        guard !levels.isEmpty else {
            return isRecording ? Float.random(in: 0.03...0.1) : 0.03
        }
        let total = levels.count
        let start = max(0, total - barCount)
        let levelIndex = start + index
        guard levelIndex < total else { return 0.03 }
        return max(0.03, levels[levelIndex])
    }
}

/// A single bar in the waveform visualization.
private struct AudioBar: View {
    let level: Float
    let isRecording: Bool
    let maxHeight: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: 1.5)
            .fill(barGradient)
            .frame(
                maxWidth: .infinity,
                minHeight: maxHeight * 0.06,
                idealHeight: maxHeight * CGFloat(level),
                maxHeight: maxHeight
            )
            .animation(.easeInOut(duration: 0.08), value: level)
    }

    private var barGradient: some ShapeStyle {
        if isRecording {
            return AnyShapeStyle(
                LinearGradient(
                    colors: [
                        Color(red: 1.0, green: 0.25, blue: 0.25).opacity(0.6),
                        Color(red: 1.0, green: 0.3, blue: 0.3)
                    ],
                    startPoint: .bottom,
                    endPoint: .top
                )
            )
        } else {
            return AnyShapeStyle(Color.white.opacity(0.15))
        }
    }
}

/// Pulsing dot animation shown while transcribing.
struct TranscribingIndicator: View {
    @State private var scale: CGFloat = 0.8
    @State private var opacity: Double = 0.4

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(Color.blue)
                    .frame(width: 8, height: 8)
                    .scaleEffect(scale)
                    .opacity(opacity)
                    .animation(
                        .easeInOut(duration: 0.6)
                            .repeatForever(autoreverses: true)
                            .delay(Double(index) * 0.2),
                        value: scale
                    )
            }
        }
        .onAppear {
            scale = 1.2
            opacity = 1.0
        }
    }
}
