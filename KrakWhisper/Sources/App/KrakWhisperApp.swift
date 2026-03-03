#if os(iOS)
import SwiftUI
import SwiftData

/// Main entry point for KrakWhisper iOS app.
@main
struct KrakWhisperApp: App {
    @StateObject private var downloadManager = ModelDownloadManager.shared
    @AppStorage("krakwhisper.onboardingComplete") private var onboardingComplete = false

    var body: some Scene {
        WindowGroup {
            Group {
                if onboardingComplete {
                    MainTabView(downloadManager: downloadManager)
                } else {
                    OnboardingView(
                        downloadManager: downloadManager,
                        isOnboardingComplete: $onboardingComplete
                    )
                }
            }
            .onAppear {
                // Sync all downloaded models to shared App Group container
                // so the keyboard extension can access them
                downloadManager.syncModelsToSharedContainer()
            }
        }
        .modelContainer(for: TranscriptionRecord.self)
    }
}
#endif
