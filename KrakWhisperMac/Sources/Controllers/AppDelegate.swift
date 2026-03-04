import AppKit
import Combine
import SwiftUI
import KrakWhisper

/// Application delegate managing the status bar item, popover, and global hotkey.
///
/// This is the nerve center of the macOS app. It:
/// - Creates and manages the menu bar icon
/// - Shows/hides the popover on click
/// - Registers the global hotkey for dictation
/// - Coordinates the DictationViewModel lifecycle
/// - Manages the floating widget window
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {

    // MARK: - Properties

    let dictationViewModel = DictationViewModel()
    private let hotkeyManager = HotkeyManager()
    private var statusBarController: StatusBarController!
    private var floatingWidgetController: FloatingWidgetController!
    private var widgetObserver: Any?

    // MARK: - NSApplicationDelegate

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Run as menu bar–only app (no dock icon, no main window)
        NSApp.setActivationPolicy(.accessory)

        // Set up status bar icon and popover
        statusBarController = StatusBarController(dictationViewModel: dictationViewModel)

        // Set up floating widget
        floatingWidgetController = FloatingWidgetController(dictationViewModel: dictationViewModel)
        if UserDefaults.standard.object(forKey: "krakwhisper.mac.showFloatingWidget") == nil {
            // Default to showing the widget on first launch
            UserDefaults.standard.set(true, forKey: "krakwhisper.mac.showFloatingWidget")
        }
        if UserDefaults.standard.bool(forKey: "krakwhisper.mac.showFloatingWidget") {
            floatingWidgetController.show()
        }

        // Watch for widget preference changes
        widgetObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            let shouldShow = UserDefaults.standard.bool(forKey: "krakwhisper.mac.showFloatingWidget")
            if shouldShow && !self.floatingWidgetController.isVisible {
                self.floatingWidgetController.show()
            } else if !shouldShow && self.floatingWidgetController.isVisible {
                self.floatingWidgetController.hide()
            }
        }

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

        // Check accessibility permissions (needed for paste-to-app)
        PasteService.requestAccessibilityIfNeeded()
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotkeyManager.unregister()
        if let widgetObserver {
            NotificationCenter.default.removeObserver(widgetObserver)
        }
    }
}
