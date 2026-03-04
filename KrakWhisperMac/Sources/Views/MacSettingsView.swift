import SwiftUI
import ServiceManagement
import KrakWhisper

/// Settings window for KrakWhisper macOS app.
///
/// Provides controls for model selection/download, hotkey configuration,
/// auto-paste behavior, and general app preferences.
struct MacSettingsView: View {
    @EnvironmentObject var viewModel: DictationViewModel
    @EnvironmentObject var downloadManager: ModelDownloadManager

    var body: some View {
        TabView {
            GeneralSettingsTab(viewModel: viewModel)
                .tabItem {
                    Label("General", systemImage: "gear")
                }

            ModelSettingsTab(viewModel: viewModel, downloadManager: downloadManager)
                .tabItem {
                    Label("Models", systemImage: "cpu")
                }

            AboutTab()
                .tabItem {
                    Label("About", systemImage: "info.circle")
                }
        }
        .frame(width: 480, height: 360)
    }
}

// MARK: - General Settings

struct GeneralSettingsTab: View {
    @ObservedObject var viewModel: DictationViewModel
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var isUpdatingLaunchAtLogin = false
    @State private var isLlamaServerRunning = false
    @AppStorage("krakwhisper.mac.showFloatingPanel") private var showFloatingPanel = true
    @AppStorage("krakwhisper.mac.autoDismissSeconds") private var autoDismissSeconds = 5.0

    var body: some View {
        Form {
            Section("Dictation") {
                Toggle("Auto-paste into frontmost app", isOn: $viewModel.autoPaste)
                    .help("After transcription, automatically paste the text into whichever app was active")

                if viewModel.autoPaste && !PasteService.isAccessibilityGranted {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.yellow)
                        Text("Accessibility permission required for auto-paste")
                            .font(.caption)
                        Button("Grant Access") {
                            PasteService.requestAccessibilityIfNeeded()
                        }
                        .font(.caption)
                    }
                }
            }

            Section("Hotkey") {
                HStack {
                    Text("Dictation shortcut:")
                    Spacer()
                    // TODO: Replace with a shortcut recorder control for full customization
                    Text(HotkeyManager().hotkeyDisplayString)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(.quaternary)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .font(.system(.body, design: .monospaced))
                }
                Text("Press the shortcut to start/stop dictation from any app. Customizable shortcut recorder coming in a future update.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Appearance") {
                Toggle("Show floating panel during dictation", isOn: $showFloatingPanel)

                if showFloatingPanel {
                    HStack {
                        Text("Auto-dismiss after")
                        TextField("", value: $autoDismissSeconds, format: .number)
                            .frame(width: 50)
                            .textFieldStyle(.roundedBorder)
                        Text("seconds")
                    }
                }
            }

            Section("System") {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .help("Start KrakWhisper automatically when you log in")
                    .onChange(of: launchAtLogin) { _, newValue in
                        guard !isUpdatingLaunchAtLogin else { return }
                        do {
                            if newValue {
                                try SMAppService.mainApp.register()
                            } else {
                                try SMAppService.mainApp.unregister()
                            }
                        } catch {
                            // Revert on failure without recursive side effects
                            isUpdatingLaunchAtLogin = true
                            launchAtLogin = !newValue
                            isUpdatingLaunchAtLogin = false
                            print("[LaunchAtLogin] Failed: \(error.localizedDescription)")
                        }
                    }

                // Llama-server / Qwen status
                HStack {
                    Text("Qwen AI Cleanup")
                    Spacer()
                    if isLlamaServerRunning {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(.green)
                                .frame(width: 8, height: 8)
                            Text("Running")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(.gray)
                                .frame(width: 8, height: 8)
                            Text("Stopped")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .onAppear { checkLlamaServerStatus() }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    /// Check if llama-server is running by probing its TCP port.
    private func checkLlamaServerStatus() {
        let port: UInt16 = 8179
        let socketFD = socket(AF_INET, SOCK_STREAM, 0)
        guard socketFD >= 0 else {
            isLlamaServerRunning = false
            return
        }
        defer { close(socketFD) }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                connect(socketFD, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        isLlamaServerRunning = (result == 0)
    }
}

// MARK: - Model Settings

struct ModelSettingsTab: View {
    @ObservedObject var viewModel: DictationViewModel
    @ObservedObject var downloadManager: ModelDownloadManager

    var body: some View {
        Form {
            Section("Selected Model") {
                Picker("Active model:", selection: $viewModel.selectedModel) {
                    ForEach(WhisperModelSize.allCases) { model in
                        HStack {
                            Text(model.displayName)
                            if downloadManager.isModelAvailable(model) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                                    .font(.caption)
                            }
                        }
                        .tag(model)
                    }
                }

                if viewModel.isModelLoaded {
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text("Model loaded and ready")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    HStack {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.red)
                        Text("Model not loaded — download it below")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("Available Models") {
                ForEach(WhisperModelSize.allCases) { model in
                    ModelRow(model: model, downloadManager: downloadManager)
                }

                HStack {
                    Text("Disk usage:")
                        .foregroundStyle(.secondary)
                    Text(downloadManager.formattedDiskUsage)
                }
                .font(.caption)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

/// A single row showing a model's download state with action buttons.
struct ModelRow: View {
    let model: WhisperModelSize
    @ObservedObject var downloadManager: ModelDownloadManager

    private var state: ModelDownloadState {
        downloadManager.downloadStates[model] ?? .notDownloaded
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.displayName)
                    .font(.body)
                Text(model.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            stateView
        }
    }

    @ViewBuilder
    private var stateView: some View {
        switch state {
        case .notDownloaded:
            Button("Download") {
                downloadManager.download(model)
            }
            .buttonStyle(.bordered)

        case .downloading(let progress):
            HStack(spacing: 8) {
                ProgressView(value: progress)
                    .frame(width: 80)
                Text("\(Int(progress * 100))%")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 35, alignment: .trailing)
                Button(action: { downloadManager.cancelDownload(model) }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

        case .validating:
            HStack(spacing: 4) {
                ProgressView()
                    .scaleEffect(0.6)
                Text("Validating…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

        case .downloaded:
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Button(role: .destructive) {
                    downloadManager.deleteModel(model)
                } label: {
                    Image(systemName: "trash")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }

        case .failed(let message):
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                    .font(.caption)
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Button("Retry") {
                    downloadManager.download(model)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }
}

// MARK: - About Tab

struct AboutTab: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "mic.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(.blue)

            Text("KrakWhisper")
                .font(.title)
                .fontWeight(.bold)

            Text("Local speech-to-text for macOS")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Divider()
                .frame(width: 200)

            VStack(spacing: 4) {
                Text("Powered by whisper.cpp")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("100% on-device • No cloud • No subscriptions")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            Text("© 2026 Krakowski Labs")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}
