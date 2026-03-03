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

// Preview requires Xcode — #Preview macro not available in SPM CLI builds
