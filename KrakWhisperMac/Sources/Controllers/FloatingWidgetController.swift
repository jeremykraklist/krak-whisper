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
        hostingView.frame = NSRect(x: 0, y: 0, width: 56, height: 56)

        let panel = DraggablePanel(
            contentRect: NSRect(x: 0, y: 0, width: 56, height: 56),
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

        // Restore saved position or default to bottom-right
        let savedX = UserDefaults.standard.double(forKey: Self.positionXKey)
        let savedY = UserDefaults.standard.double(forKey: Self.positionYKey)

        if savedX != 0 || savedY != 0 {
            panel.setFrameOrigin(NSPoint(x: savedX, y: savedY))
        } else if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            let x = screenFrame.maxX - 76
            let y = screenFrame.minY + 80
            panel.setFrameOrigin(NSPoint(x: x, y: y))
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
