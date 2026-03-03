#if os(iOS)
import SwiftUI
import SwiftData

/// Main entry point for KrakWhisper iOS app.
@main
struct KrakWhisperApp: App {
    @StateObject private var downloadManager = ModelDownloadManager.shared
    @AppStorage("krakwhisper.onboardingComplete") private var onboardingComplete = false
    @State private var showKeyboardRecorder = false

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
                downloadManager.syncModelsToSharedContainer()
                KeyboardTranscriptionService.shared.startListening()
            }
            .onOpenURL { url in
                // Handle krakwhisper://record from keyboard extension
                if url.host == "record" || url.path == "/record" {
                    showKeyboardRecorder = true
                }
            }
            .fullScreenCover(isPresented: $showKeyboardRecorder) {
                KeyboardRecordView()
            }
        }
        .modelContainer(for: TranscriptionRecord.self)
    }
}
#endif
