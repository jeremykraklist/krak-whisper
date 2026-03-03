import AppKit
import Carbon.HIToolbox

/// Manages the global keyboard shortcut for starting/stopping dictation.
///
/// Uses `NSEvent.addGlobalMonitorForEvents` for when the app is NOT focused,
/// and `NSEvent.addLocalMonitorForEvents` for when it IS focused.
/// Default hotkey: ⌘⇧W (Cmd+Shift+W).
@MainActor
final class HotkeyManager {

    // MARK: - Configuration

    /// The key code for the hotkey (default: W = 13).
    var keyCode: UInt16 {
        get {
            let defaults = UserDefaults.standard
            guard defaults.object(forKey: "hotkeyKeyCode") != nil else { return 13 } // 13 = W
            return UInt16(defaults.integer(forKey: "hotkeyKeyCode"))
        }
        set {
            UserDefaults.standard.set(Int(newValue), forKey: "hotkeyKeyCode")
        }
    }

    /// The modifier flags for the hotkey (default: Cmd+Shift).
    var modifierFlags: NSEvent.ModifierFlags {
        get {
            let defaults = UserDefaults.standard
            guard defaults.object(forKey: "hotkeyModifiers") != nil else {
                return [.command, .shift]
            }
            return NSEvent.ModifierFlags(rawValue: UInt(defaults.integer(forKey: "hotkeyModifiers")))
        }
        set {
            UserDefaults.standard.set(Int(newValue.rawValue), forKey: "hotkeyModifiers")
        }
    }

    /// Called when the hotkey is pressed. Set by the AppDelegate.
    var onHotkeyPressed: (() -> Void)?

    // MARK: - Monitors

    private var globalMonitor: Any?
    private var localMonitor: Any?

    // MARK: - Registration

    /// Register global and local event monitors for the hotkey.
    func register() {
        // Monitor for hotkey when app is NOT focused
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKeyEvent(event)
        }

        // Monitor for hotkey when app IS focused
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if self?.isHotkeyEvent(event) == true {
                self?.handleKeyEvent(event)
                return nil // Consume the event
            }
            return event
        }
    }

    /// Unregister all event monitors.
    func unregister() {
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
            self.globalMonitor = nil
        }
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }
    }

    // MARK: - Event Handling

    private func handleKeyEvent(_ event: NSEvent) {
        guard isHotkeyEvent(event) else { return }
        onHotkeyPressed?()
    }

    private func isHotkeyEvent(_ event: NSEvent) -> Bool {
        // Check key code
        guard event.keyCode == keyCode else { return false }

        // Check modifiers (mask out irrelevant flags like caps lock, fn, etc.)
        let relevantFlags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        return relevantFlags == modifierFlags
    }

    // MARK: - Display

    /// Human-readable string for the current hotkey (e.g., "⌘⇧W").
    var hotkeyDisplayString: String {
        var parts: [String] = []
        if modifierFlags.contains(.control) { parts.append("⌃") }
        if modifierFlags.contains(.option) { parts.append("⌥") }
        if modifierFlags.contains(.shift) { parts.append("⇧") }
        if modifierFlags.contains(.command) { parts.append("⌘") }

        let keyName = keyCodeName(keyCode)
        parts.append(keyName)

        return parts.joined()
    }

    /// Map common key codes to display names.
    private func keyCodeName(_ code: UInt16) -> String {
        switch code {
        case 49: return "Space"
        case 36: return "Return"
        case 48: return "Tab"
        case 51: return "Delete"
        case 53: return "Escape"
        default:
            // Try to get the character from the key code
            if let char = keyCodeToCharacter(code) {
                return char.uppercased()
            }
            return "Key(\(code))"
        }
    }

    /// Convert a key code to its character representation.
    private func keyCodeToCharacter(_ keyCode: UInt16) -> String? {
        // TISCopyCurrentKeyboardInputSource may return NULL for some input configurations
        guard let sourceRef = TISCopyCurrentKeyboardInputSource() else { return nil }
        let source = sourceRef.takeRetainedValue()

        // kTISPropertyUnicodeKeyLayoutData can be NULL for certain IMEs;
        // fall back to TISCopyCurrentKeyboardLayoutInputSource in that case
        var layoutData = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        if layoutData == nil {
            guard let fallbackRef = TISCopyCurrentKeyboardLayoutInputSource() else { return nil }
            let fallback = fallbackRef.takeRetainedValue()
            layoutData = TISGetInputSourceProperty(fallback, kTISPropertyUnicodeKeyLayoutData)
        }
        guard let layoutData else { return nil }

        let dataRef = unsafeBitCast(layoutData, to: CFData.self)
        let keyLayoutPtr = unsafeBitCast(
            CFDataGetBytePtr(dataRef),
            to: UnsafePointer<UCKeyboardLayout>.self
        )

        var deadKeyState: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var length: Int = 0

        let status = UCKeyTranslate(
            keyLayoutPtr,
            keyCode,
            UInt16(kUCKeyActionDisplay),
            0,
            UInt32(LMGetKbdType()),
            UInt32(kUCKeyTranslateNoDeadKeysBit),
            &deadKeyState,
            chars.count,
            &length,
            &chars
        )

        guard status == noErr, length > 0 else { return nil }
        return String(utf16CodeUnits: chars, count: length)
    }

    deinit {
        // Inline cleanup to avoid MainActor-isolated call from non-isolated deinit
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
        }
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
        }
    }
}
