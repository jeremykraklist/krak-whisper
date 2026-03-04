import AppKit
import SwiftUI
import KrakWhisper

/// Application delegate managing the status bar item, popover, and global hotkey.
///
/// This is the nerve center of the macOS app. It:
/// - Creates and manages the menu bar icon
/// - Shows/hides the popover on click
/// - Registers the global hotkey for dictation
/// - Coordinates the DictationViewModel lifecycle
/// - Auto-starts llama-server for Qwen text cleanup
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {

    // MARK: - Properties

    let dictationViewModel = DictationViewModel()
    private let hotkeyManager = HotkeyManager()
    private let llamaServerManager = LlamaServerManager()
    private var statusBarController: StatusBarController!

    // MARK: - NSApplicationDelegate

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Run as menu bar–only app (no dock icon, no main window)
        NSApp.setActivationPolicy(.accessory)

        // Set up status bar icon and popover
        statusBarController = StatusBarController(dictationViewModel: dictationViewModel)

        // Register global hotkey (Cmd+Shift+W)
        hotkeyManager.onHotkeyPressed = { [weak self] in
            guard let self else { return }
            self.dictationViewModel.toggleDictation()
        }
        hotkeyManager.register()

        // Observe dictation state to update status bar icon
        dictationViewModel.onStateChanged = { [weak self] state in
            self?.statusBarController.updateIcon(for: state)
        }

        // Load the selected model on launch
        Task {
            await dictationViewModel.loadSelectedModel()
        }

        // Auto-start llama-server for Qwen text cleanup
        llamaServerManager.startIfNeeded()

        // Check accessibility permissions (needed for paste-to-app)
        PasteService.requestAccessibilityIfNeeded()
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotkeyManager.unregister()

        // Graceful shutdown: kill llama-server if we started it
        llamaServerManager.stop()
    }
}
