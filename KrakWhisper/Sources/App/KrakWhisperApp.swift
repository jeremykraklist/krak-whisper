import SwiftUI

/// App entry point for KrakWhisper.
/// In the Xcode project, this is the @main entry.
/// When building as a SPM library, @main is excluded.
#if !SWIFT_PACKAGE
@main
#endif
struct KrakWhisperApp: App {
    var body: some Scene {
        WindowGroup {
            RecordingView()
                .preferredColorScheme(.dark)
        }
    }
}
