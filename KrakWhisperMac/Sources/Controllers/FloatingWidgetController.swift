import AppKit
import SwiftUI

/// Manages the always-on-top floating widget window.
///
/// Creates a borderless, transparent, draggable NSWindow that floats
/// above all other windows. Contains the FloatingWidgetView SwiftUI content.
@MainActor
final class FloatingWidgetController {

    // MARK: - Properties

    private var window: NSWindow?
    private let dictationViewModel: DictationViewModel

    /// UserDefaults key for persisting the widget position.
    private static let positionXKey = "krakwhisper.mac.widgetPositionX"
    private static let positionYKey = "krakwhisper.mac.widgetPositionY"

    // MARK: - Init

    init(dictationViewModel: DictationViewModel) {
        self.dictationViewModel = dictationViewModel
    }

    // MARK: - Show / Hide

    /// Show the floating widget window.
    func show() {
        guard window == nil else {
            window?.orderFront(nil)
            return
        }

        let widgetView = FloatingWidgetView()
            .environmentObject(dictationViewModel)

        let hostingView = NSHostingView(rootView: widgetView)
        hostingView.frame = NSRect(x: 0, y: 0, width: 30, height: 30)

        let panel = DraggablePanel(
            contentRect: NSRect(x: 0, y: 0, width: 30, height: 30),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.hasShadow = false
        panel.isMovableByWindowBackground = true
        panel.contentView = hostingView
        panel.hidesOnDeactivate = false

        // Restore saved position or default to bottom-right.
        // Use object(forKey:) to distinguish "never saved" from a real (0,0) position.
        let hasSavedX = UserDefaults.standard.object(forKey: Self.positionXKey) != nil
        let hasSavedY = UserDefaults.standard.object(forKey: Self.positionYKey) != nil

        if hasSavedX && hasSavedY {
            let savedPoint = NSPoint(
                x: UserDefaults.standard.double(forKey: Self.positionXKey),
                y: UserDefaults.standard.double(forKey: Self.positionYKey)
            )
            // Validate the saved position is on a visible screen
            let panelRect = NSRect(origin: savedPoint, size: panel.frame.size)
            let isOnScreen = NSScreen.screens.contains { screen in
                screen.visibleFrame.intersects(panelRect)
            }
            if isOnScreen {
                panel.setFrameOrigin(savedPoint)
            } else {
                // Saved position is off-screen (display layout changed); reset to default
                applyDefaultPosition(to: panel)
            }
        } else {
            applyDefaultPosition(to: panel)
        }

        // Save position when the window moves
        panel.onMoved = { origin in
            UserDefaults.standard.set(origin.x, forKey: FloatingWidgetController.positionXKey)
            UserDefaults.standard.set(origin.y, forKey: FloatingWidgetController.positionYKey)
        }

        panel.orderFront(nil)
        window = panel
    }

    /// Hide the floating widget window.
    func hide() {
        window?.orderOut(nil)
        window = nil
    }

    /// Whether the widget is currently visible.
    var isVisible: Bool {
        window?.isVisible ?? false
    }

    // MARK: - Helpers

    /// Place the panel at the very bottom-center of the screen, barely visible.
    private func applyDefaultPosition(to panel: NSPanel) {
        if let screen = NSScreen.main {
            let screenFrame = screen.frame // Use full frame, not visibleFrame, to sit below dock
            let x = screenFrame.midX - panel.frame.width / 2
            let y = screenFrame.minY + 4 // Just 4px from the very bottom
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }
    }

    /// Toggle widget visibility.
    func toggle() {
        if isVisible {
            hide()
        } else {
            show()
        }
    }
}

// MARK: - DraggablePanel

/// A custom NSPanel that tracks position changes for persistence.
private class DraggablePanel: NSPanel {
    var onMoved: ((NSPoint) -> Void)?

    override func mouseDragged(with event: NSEvent) {
        super.mouseDragged(with: event)
        onMoved?(frame.origin)
    }
}
