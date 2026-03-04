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
            syncSelectedModelToSharedDefaults()
        }
    }

    // MARK: - Qwen Model State

    /// Download state for the Qwen 3.5 2B cleanup model.
    @Published public private(set) var qwenDownloadState: ModelDownloadState = .notDownloaded

    /// Whether AI cleanup is enabled (requires Qwen model to be downloaded).
    @Published public var aiCleanupEnabled: Bool {
        didSet {
            UserDefaults.standard.set(aiCleanupEnabled, forKey: Self.aiCleanupKey)
        }
    }

    // MARK: - Private Properties

    private static let selectedModelKey = "krakwhisper.selectedModel"
    private static let aiCleanupKey = "krakwhisper.aiCleanupEnabled"
    private static let backgroundSessionID = "com.krakwhisper.model-download"
    private let logger = Logger(subsystem: "com.krakwhisper", category: "ModelDownloadManager")

    /// Active Qwen download task (separate from Whisper downloads).
    private var qwenDownloadTask: URLSessionDownloadTask?

    /// The directory where models are stored
    private let modelsDirectory: URL

    /// Background URL session for downloads
    private lazy var backgroundSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.allowsExpensiveNetworkAccess = true
        config.allowsConstrainedNetworkAccess = true
        config.timeoutIntervalForRequest = 300
        config.timeoutIntervalForResource = 3600
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    /// Map of active download tasks keyed by model
    private var activeDownloads: [WhisperModelSize: URLSessionDownloadTask] = [:]

    /// Background completion handler provided by the system
    public var backgroundCompletionHandler: (() -> Void)?

    // MARK: - App Group

    /// App Group identifier shared between the main app and keyboard extension.
    private static let appGroupIdentifier = "group.com.krakwhisper.shared"

    /// Shared App Group container models directory (for keyboard extension access).
    private var sharedModelsDirectory: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: Self.appGroupIdentifier)?
            .appendingPathComponent("Models", isDirectory: true)
    }

    /// Shared UserDefaults for communicating with the keyboard extension.
    private var sharedDefaults: UserDefaults? {
        UserDefaults(suiteName: Self.appGroupIdentifier)
    }

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

        // Restore AI cleanup preference
        self.aiCleanupEnabled = UserDefaults.standard.object(forKey: Self.aiCleanupKey) as? Bool ?? false

        super.init()

        // Create models directory if needed
        try? FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)

        // Create shared models directory if needed
        if let sharedDir = sharedModelsDirectory {
            try? FileManager.default.createDirectory(at: sharedDir, withIntermediateDirectories: true)
        }

        // Initialize states for all models
        refreshDownloadStates()

        // Initialize Qwen model state
        refreshQwenDownloadState()

        // Auto-enable AI cleanup if model is already downloaded and user hasn't explicitly set preference
        if UserDefaults.standard.object(forKey: Self.aiCleanupKey) == nil && qwenDownloadState == .downloaded {
            aiCleanupEnabled = true
        }

        // Sync selected model to shared defaults for the keyboard extension
        syncSelectedModelToSharedDefaults()

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

    /// Delete a downloaded model file (from both local and shared container).
    public func deleteModel(_ model: WhisperModelSize) {
        let fileURL = localURL(for: model)
        do {
            try FileManager.default.removeItem(at: fileURL)
            logger.info("Deleted model \(model.rawValue)")
            downloadStates[model] = .notDownloaded

            // Also remove from shared container
            removeModelFromSharedContainer(model)

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

    // MARK: - Qwen Model Management

    /// URL to the Qwen GGUF model file.
    public var qwenModelURL: URL {
        modelsDirectory.appendingPathComponent(QwenCleanupService.modelFileName)
    }

    /// Whether the Qwen model is downloaded and ready.
    public var isQwenModelAvailable: Bool {
        qwenDownloadState == .downloaded
    }

    /// Start downloading the Qwen 3.5 2B model from CDN.
    public func downloadQwenModel() {
        guard qwenDownloadState != .downloaded else {
            logger.info("Qwen model already downloaded, skipping.")
            return
        }
        if case .downloading = qwenDownloadState {
            logger.info("Qwen model already downloading, skipping.")
            return
        }

        logger.info("Starting Qwen model download from \(QwenCleanupService.downloadURL)")
        qwenDownloadState = .downloading(progress: 0.0)

        let task = backgroundSession.downloadTask(with: QwenCleanupService.downloadURL)
        task.taskDescription = "qwen-cleanup"
        qwenDownloadTask = task
        task.resume()
    }

    /// Cancel the in-progress Qwen model download.
    public func cancelQwenDownload() {
        guard let task = qwenDownloadTask else { return }
        logger.info("Cancelling Qwen model download")
        task.cancel()
        qwenDownloadTask = nil
        qwenDownloadState = .notDownloaded
    }

    /// Delete the downloaded Qwen model file.
    public func deleteQwenModel() {
        // Unload from memory first
        QwenCleanupService.shared.unloadModel()

        let fileURL = qwenModelURL
        do {
            if FileManager.default.fileExists(atPath: fileURL.path) {
                try FileManager.default.removeItem(at: fileURL)
            }
            logger.info("Deleted Qwen model")
            qwenDownloadState = .notDownloaded
            aiCleanupEnabled = false
        } catch {
            logger.error("Failed to delete Qwen model: \(error.localizedDescription)")
        }
    }

    /// Refresh the Qwen model download state by checking the local file.
    public func refreshQwenDownloadState() {
        // Don't overwrite active download
        if case .downloading = qwenDownloadState { return }

        let fileURL = qwenModelURL
        if FileManager.default.fileExists(atPath: fileURL.path) {
            if validateQwenModelFile() {
                qwenDownloadState = .downloaded
            } else {
                qwenDownloadState = .failed(message: "File corrupted")
                try? FileManager.default.removeItem(at: fileURL)
            }
        } else {
            qwenDownloadState = .notDownloaded
        }
    }

    /// Validate the downloaded Qwen model file size.
    private func validateQwenModelFile() -> Bool {
        let fileURL = qwenModelURL
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let fileSize = attrs[.size] as? Int64 else {
            return false
        }

        let expected = QwenCleanupService.expectedFileSize
        let tolerance = Int64(Double(expected) * 0.05)
        let valid = fileSize >= (expected - tolerance) && fileSize <= (expected + tolerance)

        if !valid {
            logger.warning("Qwen model size \(fileSize) outside expected range \(expected - tolerance)-\(expected + tolerance)")
        }
        return valid
    }

    /// Formatted Qwen model file size for display.
    public var qwenModelSizeDescription: String {
        ByteCountFormatter.string(fromByteCount: QwenCleanupService.expectedFileSize, countStyle: .file)
    }

    /// Total disk space used by downloaded models (Whisper + Qwen).
    public var totalDiskUsage: Int64 {
        var total: Int64 = WhisperModelSize.allCases.reduce(0) { sum, model in
            let url = localURL(for: model)
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let size = attrs[.size] as? Int64 else { return sum }
            return sum + size
        }

        // Include Qwen model if downloaded
        if let attrs = try? FileManager.default.attributesOfItem(atPath: qwenModelURL.path),
           let size = attrs[.size] as? Int64 {
            total += size
        }

        return total
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

    /// Move a completed download temp file to the models directory,
    /// and copy it to the shared App Group container for the keyboard extension.
    private func moveDownloadedFile(from tempURL: URL, for model: WhisperModelSize) throws {
        let destinationURL = localURL(for: model)

        // Remove any existing file first
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }

        try FileManager.default.moveItem(at: tempURL, to: destinationURL)

        // Copy to shared App Group container so the keyboard extension can access it
        copyModelToSharedContainer(model)
    }

    // MARK: - Shared Container Sync

    /// Copy a downloaded model to the shared App Group container.
    /// Called after successful download so the keyboard extension can access it.
    /// Performs I/O on a background queue to avoid blocking the main thread.
    private func copyModelToSharedContainer(_ model: WhisperModelSize) {
        guard let sharedDir = sharedModelsDirectory else {
            logger.warning("Shared App Group container not available — keyboard extension won't have model access")
            return
        }

        let sourceURL = localURL(for: model)
        let destinationURL = sharedDir.appendingPathComponent(model.fileName)

        Task.detached(priority: .utility) { [logger] in
            do {
                // Remove existing copy if present
                if FileManager.default.fileExists(atPath: destinationURL.path) {
                    try FileManager.default.removeItem(at: destinationURL)
                }
                try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
                logger.info("Copied \(model.rawValue) to shared container for keyboard extension")
            } catch {
                logger.error("Failed to copy \(model.rawValue) to shared container: \(error.localizedDescription)")
            }
        }
    }

    /// Sync the selected model to shared UserDefaults so the keyboard extension knows which to load.
    private func syncSelectedModelToSharedDefaults() {
        sharedDefaults?.set(selectedModel.rawValue, forKey: Self.selectedModelKey)
    }

    /// Sync all downloaded models to the shared container.
    /// Call this on app launch to ensure the keyboard extension has access.
    /// Runs file copies on a background queue to avoid blocking the main thread.
    public func syncModelsToSharedContainer() {
        syncSelectedModelToSharedDefaults()
        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            await MainActor.run {
                for model in WhisperModelSize.allCases {
                    guard self.downloadStates[model] == .downloaded else { continue }
                    self.copyModelToSharedContainer(model)
                }
                self.logger.info("Queued sync of all downloaded models to shared container")
            }
        }
    }

    /// Remove a model from the shared container (when deleted from main app).
    private func removeModelFromSharedContainer(_ model: WhisperModelSize) {
        guard let sharedDir = sharedModelsDirectory else { return }
        let url = sharedDir.appendingPathComponent(model.fileName)
        Task.detached(priority: .utility) {
            try? FileManager.default.removeItem(at: url)
        }
    }
}

// MARK: - URLSessionDownloadDelegate

extension ModelDownloadManager: URLSessionDownloadDelegate {

    nonisolated public func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        let taskDesc = downloadTask.taskDescription ?? ""

        // Handle Qwen model download
        if taskDesc == "qwen-cleanup" {
            handleQwenDownloadComplete(location: location)
            return
        }

        guard let model = WhisperModelSize(rawValue: taskDesc) else {
            return
        }

        // MUST move file synchronously before this method returns,
        // because URLSession deletes the temp file after the callback.
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let modelsDir = documentsURL.appendingPathComponent("Models", isDirectory: true)
        let destinationURL = modelsDir.appendingPathComponent(model.fileName)

        do {
            try FileManager.default.createDirectory(at: modelsDir, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                try FileManager.default.removeItem(at: destinationURL)
            }
            try FileManager.default.moveItem(at: location, to: destinationURL)
        } catch {
            Task { @MainActor in
                self.downloadStates[model] = .failed(message: error.localizedDescription)
            }
            return
        }

        Task { @MainActor in
            activeDownloads.removeValue(forKey: model)

            if validateModelFile(model) {
                downloadStates[model] = .downloaded
                logger.info("Successfully downloaded and validated \(model.rawValue)")
                // Copy to shared App Group container so keyboard extension can access it
                copyModelToSharedContainer(model)
                syncSelectedModelToSharedDefaults()
            } else {
                try? FileManager.default.removeItem(at: localURL(for: model))
                downloadStates[model] = .failed(message: "Validation failed — file size mismatch")
                logger.error("Validation failed for \(model.rawValue)")
            }
        }
    }

    /// Handle completed Qwen model download — moves file synchronously.
    nonisolated private func handleQwenDownloadComplete(location: URL) {
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let modelsDir = documentsURL.appendingPathComponent("Models", isDirectory: true)
        let destinationURL = modelsDir.appendingPathComponent(QwenCleanupService.modelFileName)

        do {
            try FileManager.default.createDirectory(at: modelsDir, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                try FileManager.default.removeItem(at: destinationURL)
            }
            try FileManager.default.moveItem(at: location, to: destinationURL)
        } catch {
            Task { @MainActor in
                self.qwenDownloadState = .failed(message: error.localizedDescription)
            }
            return
        }

        Task { @MainActor in
            self.qwenDownloadTask = nil
            if self.validateQwenModelFile() {
                self.qwenDownloadState = .downloaded
                self.aiCleanupEnabled = true
                self.logger.info("Successfully downloaded and validated Qwen model")
            } else {
                try? FileManager.default.removeItem(at: self.qwenModelURL)
                self.qwenDownloadState = .failed(message: "Validation failed — file size mismatch")
                self.logger.error("Validation failed for Qwen model")
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
        let taskDesc = downloadTask.taskDescription ?? ""

        // Handle Qwen download progress
        if taskDesc == "qwen-cleanup" {
            let progress: Double
            if totalBytesExpectedToWrite > 0 {
                progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
            } else {
                progress = Double(totalBytesWritten) / Double(QwenCleanupService.expectedFileSize)
            }
            Task { @MainActor in
                self.qwenDownloadState = .downloading(progress: min(progress, 1.0))
            }
            return
        }

        guard let model = WhisperModelSize(rawValue: taskDesc) else {
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
        guard let error = error else { return }

        let taskDesc = task.taskDescription ?? ""

        // Ignore cancellation errors
        if (error as NSError).code == NSURLErrorCancelled { return }

        // Handle Qwen download error
        if taskDesc == "qwen-cleanup" {
            Task { @MainActor in
                self.qwenDownloadTask = nil
                self.qwenDownloadState = .failed(message: error.localizedDescription)
                self.logger.error("Qwen download failed: \(error.localizedDescription)")
            }
            return
        }

        guard let model = WhisperModelSize(rawValue: taskDesc) else { return }

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
