#if os(iOS)
import SwiftUI

/// Main entry point for KrakWhisper iOS app.
@main
struct KrakWhisperApp: App {
    @StateObject private var downloadManager = ModelDownloadManager.shared
    @AppStorage("krakwhisper.onboardingComplete") private var onboardingComplete = false

    var body: some Scene {
        WindowGroup {
            if onboardingComplete {
                MainTabView(downloadManager: downloadManager)
            } else {
                OnboardingView(
                    downloadManager: downloadManager,
                    isOnboardingComplete: $onboardingComplete
                )
            }
        }
    }
}
#endif
