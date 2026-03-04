#if os(iOS)
import SwiftUI
import SwiftData

/// Main entry point for KrakWhisper iOS app.
@main
struct KrakWhisperApp: App {
    @Environment(\.scenePhase) private var scenePhase
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
                BackgroundRecordingService.shared.startListening()
                checkKeyboardIntent()
            }
            .onOpenURL { url in
                // Handle krakwhisper://record from keyboard extension
                if url.host == "record" || url.path == "/record" {
                    // Dismiss any existing recorder first, then re-show
                    if showKeyboardRecorder {
                        showKeyboardRecorder = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            showKeyboardRecorder = true
                        }
                    } else {
                        showKeyboardRecorder = true
                    }
                }
            }
            .fullScreenCover(isPresented: $showKeyboardRecorder) {
                KeyboardRecordView()
            }
            .onChange(of: scenePhase) { _, newPhase in
                if newPhase == .active {
                    checkKeyboardIntent()
                }
            }
        }
        .modelContainer(for: TranscriptionRecord.self)
    }
    
    /// Check if keyboard extension left an intent file (user tapped mic then opened app manually).
    /// If found, auto-open the recorder and delete the intent.
    private func checkKeyboardIntent() {
        let appGroupID = "group.com.krakwhisper.shared"
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) else { return }
        let intentURL = container.appendingPathComponent("keyboard-intent.json")
        
        guard FileManager.default.fileExists(atPath: intentURL.path),
              let data = try? Data(contentsOf: intentURL),
              let intent = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let action = intent["action"] as? String,
              action == "record" else { return }
        
        // Check intent is recent (within last 60 seconds)
        if let timestamp = intent["timestamp"] as? TimeInterval {
            let age = Date().timeIntervalSince1970 - timestamp
            guard age < 60 else {
                // Stale intent — clean up
                try? FileManager.default.removeItem(at: intentURL)
                return
            }
        }
        
        // Delete the intent and open recorder
        try? FileManager.default.removeItem(at: intentURL)
        if showKeyboardRecorder {
            // Already showing — dismiss and re-show for fresh recording
            showKeyboardRecorder = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                self.showKeyboardRecorder = true
            }
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                self.showKeyboardRecorder = true
            }
        }
    }
}
#endif
