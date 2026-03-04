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
                    .stroke(Color.red.opacity(0.5), lineWidth: 2)
                    .frame(width: 28, height: 28)
                    .scaleEffect(pulseScale)
                    .opacity(pulseOpacity)
                    .animation(
                        .easeInOut(duration: 1.0).repeatForever(autoreverses: true),
                        value: viewModel.state
                    )
            }

            // Main button — very small, subtle
            Circle()
                .fill(buttonColor.opacity(isHovering ? 0.95 : 0.7))
                .frame(width: 22, height: 22)
                .shadow(color: .black.opacity(0.2), radius: isHovering ? 4 : 2, y: 1)
                .overlay {
                    Image(systemName: buttonIcon)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .scaleEffect(isHovering ? 1.15 : 1.0)
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
        .frame(width: 30, height: 30)
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
