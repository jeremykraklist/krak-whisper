import SwiftUI

/// Settings screen — model management, preferences, and app info.
struct SettingsView: View {
    @ObservedObject var downloadManager: ModelDownloadManager
    @AppStorage("krakwhisper.autoCopyToClipboard") private var autoCopyToClipboard = true
    @AppStorage("krakwhisper.language") private var language = "en"

    var body: some View {
        NavigationStack {
            List {
                // MARK: - Model Selection
                Section {
                    ForEach(WhisperModelSize.allCases) { model in
                        let state = downloadManager.downloadStates[model] ?? .notDownloaded
                        ModelDownloadRow(
                            model: model,
                            state: state,
                            isSelected: downloadManager.selectedModel == model,
                            onDownload: { downloadManager.download(model) },
                            onCancel: { downloadManager.cancelDownload(model) },
                            onDelete: { downloadManager.deleteModel(model) },
                            onSelect: { downloadManager.selectedModel = model }
                        )
                    }
                } header: {
                    Text("Whisper Models")
                } footer: {
                    Text("Models run entirely on-device. Larger models are more accurate but use more memory and storage.")
                }

                // MARK: - Storage
                Section("Storage") {
                    HStack {
                        Text("Models on device")
                        Spacer()
                        Text(downloadManager.formattedDiskUsage)
                            .foregroundStyle(.secondary)
                    }
                }

                // MARK: - Transcription Settings
                Section("Transcription") {
                    Picker("Language", selection: $language) {
                        Text("English").tag("en")
                    }

                    Toggle("Auto-copy to clipboard", isOn: $autoCopyToClipboard)
                }

                // MARK: - AI Cleanup (Qwen)
                Section {
                    // Qwen model download row
                    QwenModelDownloadRow(downloadManager: downloadManager)

                    Toggle("Auto-clean after transcription", isOn: Binding(
                        get: { downloadManager.aiCleanupEnabled },
                        set: { downloadManager.aiCleanupEnabled = $0 }
                    ))
                    .disabled(!downloadManager.isQwenModelAvailable)
                } header: {
                    Text("AI Text Cleanup")
                } footer: {
                    Text("Qwen 3.5 2B runs entirely on-device to clean up transcriptions — fixing punctuation, grammar, and removing filler words. Requires \(downloadManager.qwenModelSizeDescription) of storage.")
                }

                // MARK: - Keyboard Extension
                #if os(iOS)
                Section {
                    KeyboardSetupInstructionsView()
                } header: {
                    Text("Keyboard Extension")
                } footer: {
                    Text("The KrakWhisper keyboard lets you dictate into any app. It uses the Tiny or Base model for fast, low-memory transcription.")
                }
                #endif

                // MARK: - About
                Section("About") {
                    HStack {
                        Text("Version")
                        Spacer()
                        Text("1.0.0 (1)")
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Engine")
                        Spacer()
                        Text("whisper.cpp")
                            .foregroundStyle(.secondary)
                    }
                    Link(destination: URL(string: "https://github.com/jeremykraklist/krak-whisper")!) {
                        HStack {
                            Text("Source Code")
                            Spacer()
                            Image(systemName: "arrow.up.right.square")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Settings")
        }
    }
}

// MARK: - QwenModelDownloadRow

/// Row for downloading/managing the Qwen 3.5 2B cleanup model.
struct QwenModelDownloadRow: View {
    @ObservedObject var downloadManager: ModelDownloadManager

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Qwen 3.5 2B")
                    .font(.body)

                switch downloadManager.qwenDownloadState {
                case .notDownloaded:
                    Text("AI cleanup model · \(downloadManager.qwenModelSizeDescription)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                case .downloading(let progress):
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                    Text("\(Int(progress * 100))% — Downloading…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                case .validating:
                    Text("Validating…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                case .downloaded:
                    Text("Downloaded ✓")
                        .font(.caption)
                        .foregroundStyle(.green)
                case .failed(let message):
                    Text("Failed: \(message)")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Spacer()

            switch downloadManager.qwenDownloadState {
            case .notDownloaded, .failed:
                Button {
                    downloadManager.downloadQwenModel()
                } label: {
                    Image(systemName: "arrow.down.circle")
                        .font(.title2)
                        .foregroundStyle(.blue)
                }
                .buttonStyle(.plain)

            case .downloading:
                Button {
                    downloadManager.cancelQwenDownload()
                } label: {
                    Image(systemName: "xmark.circle")
                        .font(.title2)
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)

            case .validating:
                ProgressView()

            case .downloaded:
                Button(role: .destructive) {
                    downloadManager.deleteQwenModel()
                } label: {
                    Image(systemName: "trash")
                        .font(.title3)
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 4)
    }
}

// Preview requires Xcode — #Preview macro not available in SPM CLI builds
