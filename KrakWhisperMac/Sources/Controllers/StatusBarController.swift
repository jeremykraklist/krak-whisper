import AppKit
import SwiftUI
import KrakWhisper

/// Manages the NSStatusBar item and its popover.
///
/// Displays a microphone icon in the macOS menu bar. Clicking toggles
/// a popover with dictation controls and recent transcription.
@MainActor
final class StatusBarController {

    // MARK: - Properties

    private var statusBarItem: NSStatusItem!
    private var popover: NSPopover!
    private var eventMonitor: Any?

    // MARK: - Init

    init(dictationViewModel: DictationViewModel) {
        setupStatusBar(dictationViewModel: dictationViewModel)
        setupEventMonitor()
    }

    // MARK: - Setup

    private func setupStatusBar(dictationViewModel: DictationViewModel) {
        statusBarItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusBarItem.button {
            button.image = NSImage(
                systemSymbolName: "mic.fill",
                accessibilityDescription: "KrakWhisper"
            )
            button.action = #selector(togglePopover)
            button.target = self
        }

        // Create the popover
        popover = NSPopover()
        popover.contentSize = NSSize(width: 340, height: 440)
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = NSHostingController(
            rootView: MenuBarPopoverView()
                .environmentObject(dictationViewModel)
                .environmentObject(ModelDownloadManager.shared)
        )
    }

    /// Monitor for clicks outside the popover to dismiss it.
    private func setupEventMonitor() {
        eventMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            guard let self, self.popover.isShown else { return }
            self.popover.performClose(nil)
        }
    }

    // MARK: - Actions

    @objc private func togglePopover() {
        guard let button = statusBarItem.button else { return }

        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            // Bring popover to front
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    // MARK: - Icon Updates

    /// Update the menu bar icon based on the current dictation state.
    func updateIcon(for state: DictationState) {
        guard let button = statusBarItem.button else { return }

        let symbolName: String
        let tintColor: NSColor

        switch state {
        case .idle:
            symbolName = "mic.fill"
            tintColor = .controlTextColor
        case .recording:
            symbolName = "mic.circle.fill"
            tintColor = .systemRed
        case .transcribing:
            symbolName = "waveform"
            tintColor = .systemOrange
        case .completed:
            symbolName = "mic.fill"
            tintColor = .systemGreen
        case .error:
            symbolName = "mic.slash.fill"
            tintColor = .systemRed
        }

        let config = NSImage.SymbolConfiguration(pointSize: 16, weight: .medium)
        button.image = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: "KrakWhisper — \(state.statusText)"
        )?.withSymbolConfiguration(config)
        button.contentTintColor = tintColor
    }

    deinit {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
        }
    }
}
