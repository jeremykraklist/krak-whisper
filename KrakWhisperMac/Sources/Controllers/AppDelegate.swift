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
/// - Manages the settings window
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {

    // MARK: - Properties

    let dictationViewModel = DictationViewModel()
    private let hotkeyManager = HotkeyManager()
    private var statusBarController: StatusBarController!
    private var settingsWindow: NSWindow?

    /// Shared instance for access from views.
    static var shared: AppDelegate?

    // MARK: - NSApplicationDelegate

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self

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

        // Check accessibility permissions (needed for global hotkey + paste-to-app)
        PasteService.requestAccessibilityIfNeeded()
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotkeyManager.unregister()
    }

    // MARK: - Settings Window

    /// Open the settings window (creates it on first call).
    func openSettingsWindow() {
        if let settingsWindow, settingsWindow.isVisible {
            settingsWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let settingsView = MacSettingsView()
            .environmentObject(dictationViewModel)
            .environmentObject(ModelDownloadManager.shared)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 400),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "KrakWhisper Settings"
        window.contentViewController = NSHostingController(rootView: settingsView)
        window.center()
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)

        // Show the app temporarily in the dock so the window can be focused
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        // Hide from dock again when the window closes
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { _ in
            NSApp.setActivationPolicy(.accessory)
        }

        self.settingsWindow = window
    }
}
