#if os(iOS)
import SwiftUI
import AVFoundation

/// First-launch onboarding flow: Welcome → Mic Permission → Model Download → Ready
struct OnboardingView: View {
    @ObservedObject var downloadManager: ModelDownloadManager
    @Binding var isOnboardingComplete: Bool

    @State private var currentStep: OnboardingStep = .welcome
    @State private var micPermissionGranted = false

    enum OnboardingStep: Int, CaseIterable {
        case welcome
        case micPermission
        case modelDownload
        case ready
    }

    var body: some View {
        VStack(spacing: 0) {
            // Progress indicator
            progressBar
                .padding(.horizontal, 24)
                .padding(.top, 16)

            // Step content
            TabView(selection: $currentStep) {
                welcomeStep
                    .tag(OnboardingStep.welcome)
                micPermissionStep
                    .tag(OnboardingStep.micPermission)
                modelDownloadStep
                    .tag(OnboardingStep.modelDownload)
                readyStep
                    .tag(OnboardingStep.ready)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .animation(.easeInOut, value: currentStep)
        }
        .background(Color(Color(.systemBackground)))
    }

    // MARK: - Progress Bar

    private var progressBar: some View {
        HStack(spacing: 8) {
            ForEach(OnboardingStep.allCases, id: \.rawValue) { step in
                Capsule()
                    .fill(step.rawValue <= currentStep.rawValue ? Color.blue : Color.gray.opacity(0.3))
                    .frame(height: 4)
            }
        }
    }

    // MARK: - Welcome Step

    private var welcomeStep: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "waveform.circle.fill")
                .font(.system(size: 80))
                .foregroundStyle(.blue)
                .symbolEffect(.pulse, options: .repeating)

            VStack(spacing: 8) {
                Text("Welcome to KrakWhisper")
                    .font(.largeTitle.weight(.bold))
                Text("Private, on-device voice transcription.\nNo cloud. No subscriptions. Just your voice.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }

            Spacer()

            Button {
                withAnimation { currentStep = .micPermission }
            } label: {
                Text("Get Started")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
            .buttonStyle(.borderedProminent)
            .padding(.horizontal, 24)
            .padding(.bottom, 40)
        }
    }

    // MARK: - Mic Permission Step

    private var micPermissionStep: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "mic.badge.plus")
                .font(.system(size: 72))
                .foregroundStyle(.orange)

            VStack(spacing: 8) {
                Text("Microphone Access")
                    .font(.title.weight(.bold))
                Text("KrakWhisper needs microphone access to record your voice. Audio never leaves your device.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }

            if micPermissionGranted {
                Label("Permission Granted", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.headline)
            }

            Spacer()

            VStack(spacing: 12) {
                if !micPermissionGranted {
                    Button {
                        requestMicPermission()
                    } label: {
                        Text("Allow Microphone")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                    }
                    .buttonStyle(.borderedProminent)
                }

                Button {
                    withAnimation { currentStep = .modelDownload }
                } label: {
                    Text(micPermissionGranted ? "Continue" : "Skip for Now")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 40)
        }
    }

    // MARK: - Model Download Step

    private var modelDownloadStep: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "arrow.down.doc.fill")
                .font(.system(size: 72))
                .foregroundStyle(.purple)

            VStack(spacing: 8) {
                Text("Download a Model")
                    .font(.title.weight(.bold))
                Text("Choose a Whisper model to get started. You can change this later in Settings.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }

            // Model selection list
            VStack(spacing: 8) {
                ForEach(WhisperModelSize.allCases) { model in
                    let state = downloadManager.downloadStates[model] ?? .notDownloaded
                    onboardingModelRow(model: model, state: state)
                }
            }
            .padding(.horizontal, 24)

            Spacer()

            Button {
                withAnimation { currentStep = .ready }
            } label: {
                Text(downloadManager.isSelectedModelReady ? "Continue" : "Skip for Now")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
            .buttonStyle(.borderedProminent)
            .padding(.horizontal, 24)
            .padding(.bottom, 40)
        }
    }

    private func onboardingModelRow(model: WhisperModelSize, state: ModelDownloadState) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.displayName)
                    .font(.subheadline.weight(.semibold))
                HStack(spacing: 4) {
                    Text(model.fileSizeDescription)
                    Text("•")
                    Text(model.subtitle)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()

            switch state {
            case .notDownloaded:
                Button("Download") {
                    downloadManager.selectedModel = model
                    downloadManager.download(model)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

            case .downloading(let progress):
                HStack(spacing: 6) {
                    ProgressView(value: progress)
                        .frame(width: 60)
                    Text("\(Int(progress * 100))%")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }

            case .validating:
                ProgressView()
                    .controlSize(.small)

            case .downloaded:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)

            case .failed:
                Button("Retry") {
                    downloadManager.download(model)
                }
                .buttonStyle(.bordered)
                .tint(.orange)
                .controlSize(.small)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(downloadManager.selectedModel == model
                      ? Color.blue.opacity(0.1)
                      : Color(.secondarySystemBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(downloadManager.selectedModel == model
                        ? Color.blue.opacity(0.3)
                        : Color.clear, lineWidth: 1)
        )
    }

    // MARK: - Ready Step

    private var readyStep: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 80))
                .foregroundStyle(.green)

            VStack(spacing: 8) {
                Text("You're All Set!")
                    .font(.largeTitle.weight(.bold))

                if downloadManager.isSelectedModelReady {
                    Text("KrakWhisper is ready to transcribe. Tap the mic to start recording.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                } else {
                    Text("You can download a model anytime from Settings.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
            }

            Spacer()

            Button {
                isOnboardingComplete = true
            } label: {
                Text("Start Using KrakWhisper")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
            .buttonStyle(.borderedProminent)
            .padding(.horizontal, 24)
            .padding(.bottom, 40)
        }
    }

    // MARK: - Helpers

    private func requestMicPermission() {
        AVAudioApplication.requestRecordPermission { granted in
            Task { @MainActor in
                micPermissionGranted = granted
            }
        }
    }
}

#endif // os(iOS)
