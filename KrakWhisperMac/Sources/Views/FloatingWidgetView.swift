import SwiftUI
import AppKit

/// A small always-on-top floating mic button that can be dragged around the screen.
///
/// Click to toggle dictation (same as the ⌘⇧W hotkey).
/// Right-click for a context menu with Settings and Quit options.
/// Shows a pulse animation when recording.
struct FloatingWidgetView: View {
    @EnvironmentObject var viewModel: DictationViewModel
    @State private var isHovering = false

    var body: some View {
        ZStack {
            // Pulse ring when recording
            if case .recording = viewModel.state {
                Circle()
                    .stroke(Color.red.opacity(0.4), lineWidth: 3)
                    .frame(width: 52, height: 52)
                    .scaleEffect(pulseScale)
                    .opacity(pulseOpacity)
                    .animation(
                        .easeInOut(duration: 1.0).repeatForever(autoreverses: true),
                        value: viewModel.state
                    )
            }

            // Main button
            Circle()
                .fill(buttonColor)
                .frame(width: 44, height: 44)
                .shadow(color: .black.opacity(0.3), radius: isHovering ? 6 : 3, y: 2)
                .overlay {
                    Image(systemName: buttonIcon)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white)
                        .symbolEffect(.pulse, isActive: viewModel.state == .recording)
                }
                .scaleEffect(isHovering ? 1.1 : 1.0)
                .animation(.easeInOut(duration: 0.15), value: isHovering)
        }
        .onHover { hovering in
            isHovering = hovering
        }
        .onTapGesture {
            viewModel.toggleDictation()
        }
        .contextMenu {
            Button("Settings…") {
                AppDelegate.shared?.openSettingsWindow()
            }
            Divider()
            Button("Quit KrakWhisper") {
                NSApp.terminate(nil)
            }
        }
        .frame(width: 56, height: 56)
    }

    // MARK: - Computed Properties

    private var buttonColor: Color {
        switch viewModel.state {
        case .idle: return .blue
        case .recording: return .red
        case .transcribing: return .orange
        case .completed: return .green
        case .error: return .gray
        }
    }

    private var buttonIcon: String {
        switch viewModel.state {
        case .idle: return "mic.fill"
        case .recording: return "stop.fill"
        case .transcribing: return "waveform"
        case .completed: return "checkmark"
        case .error: return "exclamationmark.triangle.fill"
        }
    }

    private var pulseScale: CGFloat {
        viewModel.state == .recording ? 1.3 : 1.0
    }

    private var pulseOpacity: Double {
        viewModel.state == .recording ? 0.0 : 0.6
    }
}
