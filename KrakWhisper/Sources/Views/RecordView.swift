import SwiftUI

/// Placeholder recording view — will be fully implemented in the AudioCapture issue.
struct RecordView: View {
    @ObservedObject var downloadManager: ModelDownloadManager

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()

                if !downloadManager.isSelectedModelReady {
                    // No model available — prompt user
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 48))
                            .foregroundStyle(.orange)
                        Text("No Model Loaded")
                            .font(.title2.weight(.semibold))
                        Text("Download a Whisper model in Settings to start transcribing.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                    }
                } else {
                    // Model ready — show record button placeholder
                    VStack(spacing: 16) {
                        Image(systemName: "mic.circle.fill")
                            .font(.system(size: 80))
                            .foregroundStyle(.blue)
                            .symbolEffect(.pulse, options: .repeating)

                        Text("Tap to Record")
                            .font(.title2.weight(.semibold))

                        Text("Using \(downloadManager.selectedModel.displayName)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()
            }
            .navigationTitle("Record")
        }
    }
}

// Preview requires Xcode — use #Preview in .xcodeproj target only
