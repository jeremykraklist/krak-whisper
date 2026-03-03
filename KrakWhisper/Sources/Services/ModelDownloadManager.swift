import Foundation
import Combine
import OSLog

// MARK: - Download State

/// Represents the current state of a model download or local availability.
public enum ModelDownloadState: Equatable {
    case notDownloaded
    case downloading(progress: Double) // 0.0 ... 1.0
    case validating
    case downloaded
    case failed(message: String)

    public static func == (lhs: ModelDownloadState, rhs: ModelDownloadState) -> Bool {
        switch (lhs, rhs) {
        case (.notDownloaded, .notDownloaded): return true
        case (.downloading(let a), .downloading(let b)): return a == b
        case (.validating, .validating): return true
        case (.downloaded, .downloaded): return true
        case (.failed(let a), .failed(let b)): return a == b
        default: return false
        }
    }
}

// MARK: - ModelDownloadManager

/// Manages downloading, validating, and storing whisper.cpp GGML models.
///
/// Uses URLSession background configuration for large file downloads that
/// can survive app backgrounding on iOS.
@MainActor
public final class ModelDownloadManager: NSObject, ObservableObject {

    // MARK: - Published State

    /// Per-model download state, keyed by WhisperModelSize
    @Published public private(set) var downloadStates: [WhisperModelSize: ModelDownloadState] = [:]

    /// The currently selected/active model
    @Published public var selectedModel: WhisperModelSize {
        didSet {
            UserDefaults.standard.set(selectedModel.rawValue, forKey: Self.selectedModelKey)
        }
    }

    // MARK: - Private Properties

    private static let selectedModelKey = "krakwhisper.selectedModel"
    private static let backgroundSessionID = "com.krakwhisper.model-download"
    private let logger = Logger(subsystem: "com.krakwhisper", category: "ModelDownloadManager")

    /// The directory where models are stored
    private let modelsDirectory: URL

    /// Background URL session for downloads
    private lazy var backgroundSession: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: Self.backgroundSessionID)
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        config.allowsExpensiveNetworkAccess = true
        config.allowsConstrainedNetworkAccess = true
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    /// Map of active download tasks keyed by model
    private var activeDownloads: [WhisperModelSize: URLSessionDownloadTask] = [:]

    /// Background completion handler provided by the system
    public var backgroundCompletionHandler: (() -> Void)?

    // MARK: - Singleton

    public static let shared = ModelDownloadManager()

    // MARK: - Init

    public override init() {
        // Set up models directory
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        self.modelsDirectory = documentsURL.appendingPathComponent("Models", isDirectory: true)

        // Restore selected model from UserDefaults
        if let savedRawValue = UserDefaults.standard.string(forKey: Self.selectedModelKey),
           let savedModel = WhisperModelSize(rawValue: savedRawValue) {
            self.selectedModel = savedModel
        } else {
            self.selectedModel = WhisperModelSize.defaultModel
        }

        super.init()

        // Create models directory if needed
        try? FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)

        // Initialize states for all models
        refreshDownloadStates()

        logger.info("ModelDownloadManager initialized. Models directory: \(self.modelsDirectory.path)")
    }

    // MARK: - Public API

    /// Returns the local file URL for a model (whether or not it exists).
    public func localURL(for model: WhisperModelSize) -> URL {
        modelsDirectory.appendingPathComponent(model.fileName)
    }

    /// Whether the model file exists locally and passes validation.
    public func isModelAvailable(_ model: WhisperModelSize) -> Bool {
        downloadStates[model] == .downloaded
    }

    /// Whether the currently selected model is ready to use.
    public var isSelectedModelReady: Bool {
        isModelAvailable(selectedModel)
    }

    /// Start downloading a model. No-op if already downloaded or in progress.
    public func download(_ model: WhisperModelSize) {
        guard downloadStates[model] != .downloaded else {
            logger.info("Model \(model.rawValue) already downloaded, skipping.")
            return
        }

        if case .downloading = downloadStates[model] {
            logger.info("Model \(model.rawValue) already downloading, skipping.")
            return
        }

        logger.info("Starting download of \(model.rawValue) from \(model.downloadURL)")
        downloadStates[model] = .downloading(progress: 0.0)

        let task = backgroundSession.downloadTask(with: model.downloadURL)
        task.taskDescription = model.rawValue
        activeDownloads[model] = task
        task.resume()
    }

    /// Cancel an in-progress download.
    public func cancelDownload(_ model: WhisperModelSize) {
        guard let task = activeDownloads[model] else { return }
        logger.info("Cancelling download of \(model.rawValue)")
        task.cancel()
        activeDownloads.removeValue(forKey: model)
        downloadStates[model] = .notDownloaded
    }

    /// Delete a downloaded model file.
    public func deleteModel(_ model: WhisperModelSize) {
        let fileURL = localURL(for: model)
        do {
            try FileManager.default.removeItem(at: fileURL)
            logger.info("Deleted model \(model.rawValue)")
            downloadStates[model] = .notDownloaded

            // If the deleted model was selected, switch to default
            if selectedModel == model {
                selectedModel = WhisperModelSize.defaultModel
            }
        } catch {
            logger.error("Failed to delete model \(model.rawValue): \(error.localizedDescription)")
        }
    }

    /// Refresh the download state of all models by checking local files.
    public func refreshDownloadStates() {
        for model in WhisperModelSize.allCases {
            // Don't overwrite active downloads
            if case .downloading = downloadStates[model] { continue }

            let fileURL = localURL(for: model)
            if FileManager.default.fileExists(atPath: fileURL.path) {
                if validateModelFile(model) {
                    downloadStates[model] = .downloaded
                } else {
                    // File exists but failed validation — corrupted
                    downloadStates[model] = .failed(message: "File corrupted")
                    try? FileManager.default.removeItem(at: fileURL)
                }
            } else {
                downloadStates[model] = .notDownloaded
            }
        }
    }

    /// Total disk space used by downloaded models.
    public var totalDiskUsage: Int64 {
        WhisperModelSize.allCases.reduce(0) { total, model in
            let url = localURL(for: model)
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let size = attrs[.size] as? Int64 else { return total }
            return total + size
        }
    }

    /// Formatted total disk usage string.
    public var formattedDiskUsage: String {
        ByteCountFormatter.string(fromByteCount: totalDiskUsage, countStyle: .file)
    }

    // MARK: - Private Helpers

    /// Validate a downloaded model file by checking its size against expected range.
    private func validateModelFile(_ model: WhisperModelSize) -> Bool {
        let fileURL = localURL(for: model)
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let fileSize = attrs[.size] as? Int64 else {
            return false
        }

        let lowerBound = model.expectedFileSize - model.fileSizeTolerance
        let upperBound = model.expectedFileSize + model.fileSizeTolerance

        let valid = fileSize >= lowerBound && fileSize <= upperBound
        if !valid {
            logger.warning("Model \(model.rawValue) size \(fileSize) outside expected range \(lowerBound)-\(upperBound)")
        }
        return valid
    }

    /// Move a completed download temp file to the models directory.
    private func moveDownloadedFile(from tempURL: URL, for model: WhisperModelSize) throws {
        let destinationURL = localURL(for: model)

        // Remove any existing file first
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }

        try FileManager.default.moveItem(at: tempURL, to: destinationURL)
    }
}

// MARK: - URLSessionDownloadDelegate

extension ModelDownloadManager: URLSessionDownloadDelegate {

    nonisolated public func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let modelRaw = downloadTask.taskDescription,
              let model = WhisperModelSize(rawValue: modelRaw) else {
            return
        }

        Task { @MainActor in
            downloadStates[model] = .validating
            activeDownloads.removeValue(forKey: model)

            do {
                try moveDownloadedFile(from: location, for: model)

                if validateModelFile(model) {
                    downloadStates[model] = .downloaded
                    logger.info("Successfully downloaded and validated \(model.rawValue)")
                } else {
                    try? FileManager.default.removeItem(at: localURL(for: model))
                    downloadStates[model] = .failed(message: "Validation failed — file size mismatch")
                    logger.error("Validation failed for \(model.rawValue)")
                }
            } catch {
                downloadStates[model] = .failed(message: error.localizedDescription)
                logger.error("Failed to save \(model.rawValue): \(error.localizedDescription)")
            }
        }
    }

    nonisolated public func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard let modelRaw = downloadTask.taskDescription,
              let model = WhisperModelSize(rawValue: modelRaw) else {
            return
        }

        let progress: Double
        if totalBytesExpectedToWrite > 0 {
            progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        } else {
            // Fallback: use our known expected size
            progress = Double(totalBytesWritten) / Double(model.expectedFileSize)
        }

        Task { @MainActor in
            downloadStates[model] = .downloading(progress: min(progress, 1.0))
        }
    }

    nonisolated public func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: (any Error)?
    ) {
        guard let error = error,
              let modelRaw = task.taskDescription,
              let model = WhisperModelSize(rawValue: modelRaw) else {
            return
        }

        // Ignore cancellation errors
        if (error as NSError).code == NSURLErrorCancelled { return }

        Task { @MainActor in
            activeDownloads.removeValue(forKey: model)
            downloadStates[model] = .failed(message: error.localizedDescription)
            logger.error("Download failed for \(model.rawValue): \(error.localizedDescription)")
        }
    }

    nonisolated public func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor in
            backgroundCompletionHandler?()
            backgroundCompletionHandler = nil
        }
    }
}
