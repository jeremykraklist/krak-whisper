import SwiftUI
import KrakWhisper

/// Main content view shown in the menu bar popover.
///
/// Displays dictation controls, current status, waveform during recording,
/// and the most recent transcription result.
struct MenuBarPopoverView: View {
    @EnvironmentObject var viewModel: DictationViewModel
    @EnvironmentObject var downloadManager: ModelDownloadManager

    var body: some View {
        VStack(spacing: 0) {
            // Header
            headerView
            Divider()

            // Main content
            ScrollView {
                VStack(spacing: 16) {
                    statusSection
                    dictationButton
                    transcriptionSection
                }
                .padding()
            }

            Divider()

            // Footer
            footerView
        }
        .frame(width: 340, height: 440)
    }

    // MARK: - Header

    private var headerView: some View {
        HStack {
            Image(systemName: "mic.fill")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text("KrakWhisper")
                .font(.headline)
            Spacer()
            modelBadge
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
    }

    private var modelBadge: some View {
        Group {
            if viewModel.isModelLoaded {
                Text(viewModel.selectedModel.rawValue)
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.green.opacity(0.15))
                    .foregroundStyle(.green)
                    .clipShape(Capsule())
            } else {
                Text("No Model")
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.red.opacity(0.15))
                    .foregroundStyle(.red)
                    .clipShape(Capsule())
            }
        }
    }

    // MARK: - Status Section

    private var statusSection: some View {
        VStack(spacing: 8) {
            // Status indicator
            HStack {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                Text(viewModel.state.statusText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()

                if case .recording = viewModel.state {
                    Text(viewModel.formattedDuration)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }

            // Waveform during recording
            if case .recording = viewModel.state {
                WaveformBarView(levels: viewModel.audioLevels)
                    .frame(height: 40)
                    .animation(.easeInOut(duration: 0.1), value: viewModel.audioLevels.count)
            }

            // Spinner during transcription
            if case .transcribing = viewModel.state {
                HStack(spacing: 8) {
                    ProgressView()
                        .scaleEffect(0.7)
                    Text("Processing audio…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
        }
    }

    private var statusColor: Color {
        switch viewModel.state {
        case .idle: return .gray
        case .recording: return .red
        case .transcribing: return .orange
        case .completed: return .green
        case .error: return .red
        }
    }

    // MARK: - Dictation Button

    private var dictationButton: some View {
        Button(action: { viewModel.toggleDictation() }) {
            HStack(spacing: 8) {
                Image(systemName: dictationButtonIcon)
                    .font(.title3)
                Text(dictationButtonTitle)
                    .font(.body.weight(.medium))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
        }
        .buttonStyle(.borderedProminent)
        .tint(dictationButtonTint)
        .disabled(!canToggleDictation)
        .keyboardShortcut(.space, modifiers: [.command, .shift])
    }

    private var dictationButtonIcon: String {
        switch viewModel.state {
        case .recording: return "stop.fill"
        default: return "mic.fill"
        }
    }

    private var dictationButtonTitle: String {
        switch viewModel.state {
        case .recording: return "Stop Recording"
        case .transcribing: return "Transcribing…"
        default: return "Start Dictation"
        }
    }

    private var dictationButtonTint: Color {
        switch viewModel.state {
        case .recording: return .red
        default: return .accentColor
        }
    }

    private var canToggleDictation: Bool {
        viewModel.state.canStartDictation || viewModel.state == .recording
    }

    // MARK: - Transcription Section

    @ViewBuilder
    private var transcriptionSection: some View {
        if !viewModel.lastTranscription.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Last Transcription")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if viewModel.transcriptionDuration > 0 {
                        Text(viewModel.formattedTranscriptionTime)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }

                Text(viewModel.lastTranscription)
                    .font(.body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(.quaternary.opacity(0.5))
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                HStack(spacing: 8) {
                    Button(action: { viewModel.copyLastTranscription() }) {
                        Label("Copy", systemImage: "doc.on.doc")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)

                    if PasteService.isAccessibilityGranted {
                        Button(action: { viewModel.pasteLastTranscription() }) {
                            Label("Paste to App", systemImage: "arrow.right.doc.on.clipboard")
                                .font(.caption)
                        }
                        .buttonStyle(.bordered)
                    }

                    Spacer()

                    Button(action: { viewModel.clear() }) {
                        Label("Clear", systemImage: "xmark.circle")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .tint(.secondary)
                }
            }
        } else if case .error(let message) = viewModel.state {
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.title2)
                    .foregroundStyle(.yellow)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding()
        }
    }

    // MARK: - Footer

    private var footerView: some View {
        HStack {
            Text("⌘⇧Space to dictate")
                .font(.caption2)
                .foregroundStyle(.tertiary)

            Spacer()

            Button(action: openSettings) {
                Image(systemName: "gear")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)

            Button(action: quitApp) {
                Image(systemName: "power")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
    }

    // MARK: - Actions

    private func openSettings() {
        if #available(macOS 14, *) {
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        } else {
            NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
        }
    }

    private func quitApp() {
        NSApp.terminate(nil)
    }
}

// MARK: - Waveform Bar View

/// Simple waveform visualization showing audio levels as vertical bars.
struct WaveformBarView: View {
    let levels: [Float]

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 2) {
                ForEach(Array(levels.suffix(Int(geometry.size.width / 5)).enumerated()), id: \.offset) { _, level in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(barColor(for: level))
                        .frame(width: 3, height: max(2, CGFloat(level) * geometry.size.height))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
    }

    private func barColor(for level: Float) -> Color {
        if level > 0.7 {
            return .red
        } else if level > 0.4 {
            return .orange
        } else {
            return .green
        }
    }
}
