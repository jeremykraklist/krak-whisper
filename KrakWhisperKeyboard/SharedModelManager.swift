import Foundation

/// Manages access to Whisper models stored in the shared App Group container.
///
/// The main app downloads models to the shared container. The keyboard extension
/// reads them from there — it never downloads models itself (to stay within the
/// ~50MB memory limit for extensions).
final class SharedModelManager {

    // MARK: - Constants

    static let appGroupIdentifier = "group.com.krakwhisper.shared"
    private static let selectedModelKey = "krakwhisper.selectedModel"
    private static let keyboardModelKey = "krakwhisper.keyboardModel"

    // MARK: - Shared UserDefaults

    /// UserDefaults backed by the shared App Group container.
    static var sharedDefaults: UserDefaults? {
        UserDefaults(suiteName: appGroupIdentifier)
    }

    // MARK: - Container Paths

    /// Root URL of the shared App Group container.
    static var sharedContainerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)
    }

    /// Directory within the shared container where models are stored.
    static var sharedModelsDirectory: URL? {
        sharedContainerURL?.appendingPathComponent("Models", isDirectory: true)
    }

    // MARK: - Model Access

    /// Returns the file URL for a specific model in the shared container.
    static func modelURL(for size: WhisperModelSize) -> URL? {
        sharedModelsDirectory?.appendingPathComponent(size.fileName)
    }

    /// Checks if a model file exists and is valid in the shared container.
    static func isModelAvailable(_ size: WhisperModelSize) -> Bool {
        guard let url = modelURL(for: size) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    /// Returns all model sizes that are available in the shared container.
    static func availableModels() -> [WhisperModelSize] {
        WhisperModelSize.allCases.filter { isModelAvailable($0) }
    }

    /// Returns the model size to use in the keyboard extension.
    ///
    /// Priority:
    /// 1. Keyboard-specific override (if set by user in main app)
    /// 2. The selected model from the main app (if it's tiny or base)
    /// 3. Tiny model as fallback (lowest memory footprint)
    /// 4. Whatever is available
    static var keyboardModelSize: WhisperModelSize {
        // Check keyboard-specific override first
        if let keyboardRaw = sharedDefaults?.string(forKey: keyboardModelKey),
           let keyboardModel = WhisperModelSize(rawValue: keyboardRaw),
           isModelAvailable(keyboardModel) {
            return keyboardModel
        }

        // Check the main app's selected model (prefer tiny/base for extension memory limits)
        if let selectedRaw = sharedDefaults?.string(forKey: selectedModelKey),
           let selectedModel = WhisperModelSize(rawValue: selectedRaw),
           isModelAvailable(selectedModel),
           selectedModel == .tiny || selectedModel == .base {
            return selectedModel
        }

        // Prefer tiny for lowest memory footprint
        if isModelAvailable(.tiny) { return .tiny }
        if isModelAvailable(.base) { return .base }

        // Last resort — return tiny even if not available (will fail gracefully on load)
        return .tiny
    }

    /// Returns `true` if any usable model is available for the keyboard.
    /// Only checks tiny and base — small is too large for the extension's ~50MB memory limit.
    static var hasAnyModel: Bool {
        isModelAvailable(.tiny) || isModelAvailable(.base)
    }
}
