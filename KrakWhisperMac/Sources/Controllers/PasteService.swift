import AppKit
import ApplicationServices

/// Handles clipboard operations and pasting into the frontmost application.
///
/// Uses NSPasteboard for clipboard and CGEvent for simulating Cmd+V
/// in the frontmost app. Requires Accessibility permission.
enum PasteService {

    // MARK: - Clipboard

    /// Copy text to the system clipboard.
    /// - Returns: `true` if the text was successfully written to the clipboard.
    @discardableResult
    static func copyToClipboard(_ text: String) -> Bool {
        NSPasteboard.general.clearContents()
        return NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: - Paste to Frontmost App

    /// Simulate Cmd+V to paste clipboard contents into the frontmost app.
    ///
    /// Requires Accessibility permission. The text should already be on
    /// the clipboard before calling this method.
    static func pasteFromClipboard() {
        guard AXIsProcessTrusted() else {
            requestAccessibilityIfNeeded()
            return
        }

        let source = CGEventSource(stateID: .hidSystemState)

        // Key code 0x09 = 'v'
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false) else {
            return
        }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand

        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }

    /// Copy text to clipboard and paste it into the frontmost app.
    /// No-op if clipboard write fails.
    static func copyAndPaste(_ text: String) {
        guard copyToClipboard(text) else { return }

        // Small delay to ensure clipboard is updated before paste
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            pasteFromClipboard()
        }
    }

    // MARK: - Accessibility

    /// Check if accessibility permission is granted.
    static var isAccessibilityGranted: Bool {
        AXIsProcessTrusted()
    }

    /// Request accessibility permission if not already granted.
    /// Shows the system prompt asking the user to enable it.
    static func requestAccessibilityIfNeeded() {
        guard !AXIsProcessTrusted() else { return }

        let options = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true
        ] as CFDictionary

        AXIsProcessTrustedWithOptions(options)
    }
}
