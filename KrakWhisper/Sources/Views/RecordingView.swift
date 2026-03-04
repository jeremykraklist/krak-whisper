import SwiftUI

/// Main recording and transcription view.
public struct RecordingView: View {
    @State private var viewModel = RecordingViewModel()

    public init() {}

    public var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                headerSection.padding(.top, 20)
                Spacer()
                waveformSection.padding(.horizontal, 24)
                Spacer()
                transcriptionSection.padding(.horizontal, 24)
                Spacer()
                controlsSection.padding(.bottom, 40)
            }
        }
        .task {
            await viewModel.loadModel()
        }
        .onAppear {
            // Reload model if user changed selection in Settings
            Task {
                await viewModel.reloadModelIfNeeded()
            }
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(spacing: 8) {
            Text(statusText)
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundStyle(statusColor)
                .animation(.easeInOut, value: viewModel.state)

            if viewModel.state == .recording || viewModel.recordingDuration > 0 {
                Text(viewModel.formattedDuration)
                    .font(.system(size: 48, weight: .light, design: .monospaced))
                    .foregroundStyle(.white)
                    .contentTransition(.numericText())
                    .animation(.linear(duration: 0.1), value: viewModel.formattedDuration)
            }
        }
    }

    private var statusText: String {
        if viewModel.isCleaningUp {
            return "Cleaning up text…"
        }
        switch viewModel.state {
        case .idle:
            return viewModel.isModelLoaded ? "Ready to record" : "Loading model…"
        case .recording:
            return "Recording"
        case .transcribing:
            return "Transcribing…"
        case .completed:
            return "Transcribed in \(String(format: "%.1fs", viewModel.transcriptionDuration))"
        case .error(let message):
            return message
        }
    }

    private var statusColor: Color {
        switch viewModel.state {
        case .idle: return viewModel.isModelLoaded ? .gray : .orange
        case .recording: return .red
        case .transcribing: return .blue
        case .completed: return .green
        case .error: return .red
        }
    }

    // MARK: - Waveform

    private var waveformSection: some View {
        Group {
            switch viewModel.state {
            case .recording:
                WaveformView(audioLevels: viewModel.audioLevels, isRecording: true)
            case .transcribing:
                PulsingWaveformView(isActive: true)
            default:
                WaveformView(audioLevels: viewModel.audioLevels, isRecording: false)
            }
        }
        .frame(height: 80)
    }

    // MARK: - Transcription

    private var transcriptionSection: some View {
        VStack(spacing: 12) {
            if !viewModel.transcribedText.isEmpty {
                ScrollView {
                    Text(viewModel.transcribedText)
                        .font(.body)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                }
                .frame(maxHeight: 200)
                .background(
                    RoundedRectangle(cornerRadius: 16)
                        .fill(Color.white.opacity(0.06))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(Color.white.opacity(0.1), lineWidth: 1)
                )

                // Action buttons
                HStack(spacing: 16) {
                    Button {
                        viewModel.copyToClipboard()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: viewModel.showCopyFeedback ? "checkmark" : "doc.on.doc")
                                .font(.system(size: 14))
                            Text(viewModel.showCopyFeedback ? "Copied!" : "Copy")
                                .font(.subheadline).fontWeight(.medium)
                        }
                        .foregroundStyle(viewModel.showCopyFeedback ? .green : .white)
                        .padding(.horizontal, 20).padding(.vertical, 10)
                        .background(Capsule().fill(Color.white.opacity(0.1)))
                    }
                    .animation(.easeInOut, value: viewModel.showCopyFeedback)

                    Button {
                        viewModel.clearTranscription()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "xmark").font(.system(size: 14))
                            Text("Clear").font(.subheadline).fontWeight(.medium)
                        }
                        .foregroundStyle(.gray)
                        .padding(.horizontal, 20).padding(.vertical, 10)
                        .background(Capsule().fill(Color.white.opacity(0.06)))
                    }
                }
            } else if viewModel.state == .transcribing {
                VStack(spacing: 12) {
                    ProgressView().tint(.blue).scaleEffect(1.2)
                    Text("Processing audio…")
                        .font(.subheadline).foregroundStyle(.gray)
                }
                .frame(height: 100)
            } else {
                Text("Tap the button below to start recording")
                    .font(.subheadline)
                    .foregroundStyle(.gray.opacity(0.6))
                    .frame(height: 100)
            }
        }
    }

    // MARK: - Controls

    private var controlsSection: some View {
        VStack(spacing: 24) {
            Button {
                viewModel.toggleRecording()
            } label: {
                RecordButton(
                    isRecording: viewModel.state == .recording,
                    isDisabled: viewModel.state == .transcribing || !viewModel.isModelLoaded
                )
            }
            .disabled(viewModel.state == .transcribing || !viewModel.isModelLoaded)

            HStack(spacing: 8) {
                Image(systemName: "cpu").font(.system(size: 12)).foregroundStyle(.gray)
                Text(viewModel.selectedModelSize.displayName)
                    .font(.caption).foregroundStyle(.gray)
            }
        }
    }
}

// MARK: - Record Button

struct RecordButton: View {
    let isRecording: Bool
    let isDisabled: Bool

    @State private var isPulsing = false

    var body: some View {
        ZStack {
            if isRecording {
                Circle()
                    .stroke(Color.red.opacity(0.3), lineWidth: 2)
                    .frame(width: 96, height: 96)
                    .scaleEffect(isPulsing ? 1.2 : 1.0)
                    .opacity(isPulsing ? 0 : 0.8)
                    .animation(
                        .easeInOut(duration: 1.0).repeatForever(autoreverses: false),
                        value: isPulsing
                    )
                    .onAppear { isPulsing = true }
                    .onDisappear { isPulsing = false }
            }

            Circle()
                .stroke(isRecording ? Color.red : Color.white.opacity(0.3), lineWidth: 3)
                .frame(width: 88, height: 88)

            if isRecording {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.red)
                    .frame(width: 32, height: 32)
            } else {
                Circle()
                    .fill(isDisabled ? Color.gray : Color.red)
                    .frame(width: 72, height: 72)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: isRecording)
    }
}
