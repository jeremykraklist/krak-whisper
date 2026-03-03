import Foundation

/// Available Whisper model sizes with their expected file names.
public enum WhisperModelSize: String, CaseIterable, Identifiable, Sendable {
    case tiny = "tiny.en"
    case base = "base.en"
    case small = "small.en"
    case medium = "medium.en"

    public var id: String { rawValue }

    /// Human-readable display name.
    public var displayName: String {
        switch self {
        case .tiny: return "Tiny (75 MB)"
        case .base: return "Base (142 MB)"
        case .small: return "Small (466 MB)"
        case .medium: return "Medium (1.5 GB)"
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
        case .medium: return 1_533_774_781
        }
    }

    /// Direct download URL hosted on our CDN (no redirects).
    public var downloadURL: URL {
        URL(string: "https://new.jeremiahkrakowski.com/models/\(fileName)")!
    }

    /// Alias for compatibility with ModelDownloadManager.
    public var expectedFileSize: Int64 { approximateSize }

    /// 5% tolerance for file size validation after download.
    public var fileSizeTolerance: Int64 { Int64(Double(approximateSize) * 0.05) }

    /// Human-readable file size string.
    public var fileSizeDescription: String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: approximateSize)
    }

    public var subtitle: String {
        switch self {
        case .tiny: return "Fastest · Lower accuracy"
        case .base: return "Balanced · Recommended"
        case .small: return "Accurate · Good for most use"
        case .medium: return "Best accuracy · Uses more storage"
        }
    }

    /// The default recommended model.
    public static let defaultModel: WhisperModelSize = .base
}

/// Utility for locating model files in the app's Documents directory.
public enum WhisperModelLocator {
    /// Returns the models directory URL (does not create it).
    public static var modelsDirectory: URL {
        let documentsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return documentsDir.appendingPathComponent("Models", isDirectory: true)
    }

    /// Returns the URL where a model file should be stored.
    /// Creates the models directory if needed. Throws on filesystem errors.
    public static func modelFileURL(for size: WhisperModelSize) throws -> URL {
        let dir = modelsDirectory
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(size.fileName)
    }

    /// Check if a model file exists on disk (side-effect free — does not create directories).
    public static func isModelDownloaded(_ size: WhisperModelSize) -> Bool {
        let fileURL = modelsDirectory.appendingPathComponent(size.fileName)
        return FileManager.default.fileExists(atPath: fileURL.path)
    }

    /// Returns all downloaded model sizes.
    public static func downloadedModels() -> [WhisperModelSize] {
        WhisperModelSize.allCases.filter { isModelDownloaded($0) }
    }
}
