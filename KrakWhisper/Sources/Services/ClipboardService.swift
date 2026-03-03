#if os(iOS)
import UIKit

/// Centralized clipboard and haptic feedback service.
///
/// Provides a single entry point for copying text to the system clipboard
/// with optional haptic feedback. Used by RecordingViewModel, HistoryView,
/// and TranscriptionDetailView to ensure consistent copy behavior.
@MainActor
enum ClipboardService {

    /// Copy text to the system clipboard with haptic feedback.
    ///
    /// - Parameters:
    ///   - text: The string to copy to the clipboard.
    ///   - haptic: Whether to trigger haptic feedback (default: true).
    static func copy(_ text: String, haptic: Bool = true) {
        guard !text.isEmpty else { return }
        UIPasteboard.general.string = text
        if haptic {
            triggerHaptic()
        }
    }

    /// Trigger a medium impact haptic feedback.
    static func triggerHaptic() {
        let generator = UIImpactFeedbackGenerator(style: .medium)
        generator.prepare()
        generator.impactOccurred()
    }
}
#endif
