import SwiftUI
import KrakWhisper

/// Main entry point for KrakWhisper macOS menu bar app.
///
/// Runs as a menu bar–only app (no dock icon). The AppDelegate handles
/// status bar icon, popover, and global hotkey registration.
@main
struct KrakWhisperMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // Settings window (opened via menu bar → Settings)
        Settings {
            MacSettingsView()
                .environmentObject(appDelegate.dictationViewModel)
                .environmentObject(ModelDownloadManager.shared)
        }
    }
}
