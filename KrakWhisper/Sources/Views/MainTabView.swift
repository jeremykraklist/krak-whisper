#if os(iOS)
import SwiftUI
import SwiftData

/// Root TabView with Record / History / Settings tabs.
struct MainTabView: View {
    @ObservedObject var downloadManager: ModelDownloadManager
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        TabView {
            RecordingView()
                .tabItem {
                    Label("Record", systemImage: "mic.fill")
                }

            HistoryView()
                .tabItem {
                    Label("History", systemImage: "clock.fill")
                }

            SettingsView(downloadManager: downloadManager)
                .tabItem {
                    Label("Settings", systemImage: "gearshape.fill")
                }
        }
        .onReceive(NotificationCenter.default.publisher(for: .transcriptionCompleted)) { notification in
            guard let text = notification.userInfo?["text"] as? String,
                  let duration = notification.userInfo?["duration"] as? TimeInterval,
                  let modelSize = notification.userInfo?["modelSize"] as? String else { return }

            let record = TranscriptionRecord(
                text: text,
                duration: duration,
                modelUsed: modelSize
            )
            modelContext.insert(record)
            try? modelContext.save()
        }
    }
}

#Preview {
    MainTabView(downloadManager: .shared)
}
#endif
