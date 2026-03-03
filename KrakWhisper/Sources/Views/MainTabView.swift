#if os(iOS)
import SwiftUI

/// Root TabView with Record / History / Settings tabs.
struct MainTabView: View {
    @ObservedObject var downloadManager: ModelDownloadManager

    var body: some View {
        TabView {
            RecordView(downloadManager: downloadManager)
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
    }
}

#Preview {
    MainTabView(downloadManager: .shared)
}
#endif
