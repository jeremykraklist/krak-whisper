import Foundation

/// Available Whisper model sizes with their expected file names.
/// Compatible with ModelDownloadManager's WhisperModel enum for merge.
public enum WhisperModelSize: String, CaseIterable, Identifiable, Sendable {
    case tiny = "tiny.en"
    case base = "base.en"
    case small = "small.en"

    public var id: String { rawValue }

    /// Human-readable display name.
    public var displayName: String {
        switch self {
        case .tiny: return "Tiny (75 MB)"
        case .base: return "Base (142 MB)"
        case .small: return "Small (466 MB)"
        }
    }

    /// Expected filename for the GGML model binary.
    public var fileName: String {
        "ggml-\(rawValue).bin"
    }

    /// Approximate download size in bytes.
    public var approximateSize: Int64 {
        switch self {
        case .tiny: return 77_691_713
        case .base: return 147_951_465
        case .small: return 487_601_967
        }
    }

    /// Hugging Face download URL for this model.
    public var downloadURL: URL {
        URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(fileName)")!
    }

    /// The default recommended model.
    public static let defaultModel: WhisperModelSize = .base
}

/// Utility for locating model files in the app's Documents directory.
public enum WhisperModelLocator {
    /// Returns the models directory URL.
    public static var modelsDirectory: URL {
        let documentsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return documentsDir.appendingPathComponent("Models", isDirectory: true)
    }

    /// Returns the URL where a model file should be stored.
    public static func modelFileURL(for size: WhisperModelSize) -> URL {
        let dir = modelsDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(size.fileName)
    }

    /// Check if a model file exists on disk.
    public static func isModelDownloaded(_ size: WhisperModelSize) -> Bool {
        FileManager.default.fileExists(atPath: modelFileURL(for: size).path)
    }

    /// Returns all downloaded model sizes.
    public static func downloadedModels() -> [WhisperModelSize] {
        WhisperModelSize.allCases.filter { isModelDownloaded($0) }
    }
}
