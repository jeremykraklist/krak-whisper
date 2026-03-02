import Foundation
import SwiftWhisper

// MARK: - Errors

/// Errors that can occur during transcription.
public enum TranscriptionError: LocalizedError, Sendable {
    case modelNotLoaded
    case modelFileNotFound(WhisperModelSize)
    case modelLoadFailed(underlying: Error)
    case transcriptionFailed(underlying: Error)
    case emptyAudioData
    case alreadyTranscribing

    public var errorDescription: String? {
        switch self {
        case .modelNotLoaded:
            return "No Whisper model is loaded. Please load a model first."
        case .modelFileNotFound(let size):
            return "Model file not found for '\(size.rawValue)'. Download the model first."
        case .modelLoadFailed(let error):
            return "Failed to load Whisper model: \(error.localizedDescription)"
        case .transcriptionFailed(let error):
            return "Transcription failed: \(error.localizedDescription)"
        case .emptyAudioData:
            return "Cannot transcribe empty audio data."
        case .alreadyTranscribing:
            return "A transcription is already in progress."
        }
    }
}

// MARK: - Transcription Result

/// The result of a transcription operation.
public struct TranscriptionResult: Sendable {
    public let text: String
    public let segments: [TranscriptionSegment]
    public let duration: TimeInterval

    public init(text: String, segments: [TranscriptionSegment], duration: TimeInterval) {
        self.text = text
        self.segments = segments
        self.duration = duration
    }
}

/// A single segment of transcribed text with timing.
public struct TranscriptionSegment: Sendable {
    public let text: String
    public let startTime: TimeInterval
    public let endTime: TimeInterval

    public init(text: String, startTime: TimeInterval, endTime: TimeInterval) {
        self.text = text
        self.startTime = startTime
        self.endTime = endTime
    }
}

// MARK: - Service Protocol

/// Protocol for transcription services, enabling testability.
public protocol TranscriptionServiceProtocol: AnyObject, Sendable {
    var isModelLoaded: Bool { get }
    var currentModelSize: WhisperModelSize? { get }
    var isTranscribing: Bool { get }

    func loadModel(_ size: WhisperModelSize) async throws
    func loadModel(from url: URL, size: WhisperModelSize) async throws
    func unloadModel()
    func transcribe(audioFrames: [Float]) async throws -> TranscriptionResult
}

// MARK: - WhisperTranscriptionService

/// Main transcription service wrapping SwiftWhisper (whisper.cpp).
/// Thread-safe. Loads a model, accepts 16kHz mono Float32 PCM, returns text.
public final class WhisperTranscriptionService: TranscriptionServiceProtocol, @unchecked Sendable {

    // MARK: - Properties

    private var whisper: Whisper?
    private var _currentModelSize: WhisperModelSize?
    private var _isTranscribing: Bool = false
    private let lock = NSLock()

    public var isModelLoaded: Bool {
        lock.withLock { whisper != nil }
    }

    public var currentModelSize: WhisperModelSize? {
        lock.withLock { _currentModelSize }
    }

    public var isTranscribing: Bool {
        lock.withLock { _isTranscribing }
    }

    // MARK: - Init

    public init() {}

    // MARK: - Model Lifecycle

    /// Load a Whisper model from the standard Documents/Models directory.
    public func loadModel(_ size: WhisperModelSize) async throws {
        let url = try WhisperModelLocator.modelFileURL(for: size)
        try await loadModel(from: url, size: size)
    }

    /// Load a Whisper model from an arbitrary file URL.
    /// Validates file existence before unloading the previous model.
    public func loadModel(from url: URL, size: WhisperModelSize) async throws {
        // Validate BEFORE unloading — preserve current model on failure
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw TranscriptionError.modelFileNotFound(size)
        }

        // Create the new whisper instance before swapping
        let newWhisper = Whisper(fromFileURL: url)

        // Atomic swap — only unload after successful creation
        lock.withLock {
            self.whisper = newWhisper
            self._currentModelSize = size
        }
    }

    /// Unload the current model to free memory.
    public func unloadModel() {
        lock.withLock {
            whisper = nil
            _currentModelSize = nil
        }
    }

    // MARK: - Transcription

    /// Transcribe PCM audio frames.
    /// - Parameter audioFrames: 16kHz mono Float32 PCM audio samples.
    /// - Returns: TranscriptionResult with text, segments, and timing.
    public func transcribe(audioFrames: [Float]) async throws -> TranscriptionResult {
        guard !audioFrames.isEmpty else {
            throw TranscriptionError.emptyAudioData
        }

        let currentWhisper: Whisper = try lock.withLock {
            guard let w = self.whisper else {
                throw TranscriptionError.modelNotLoaded
            }
            guard !self._isTranscribing else {
                throw TranscriptionError.alreadyTranscribing
            }
            self._isTranscribing = true
            return w
        }

        defer {
            lock.withLock { self._isTranscribing = false }
        }

        let startTime = Date()

        do {
            let whisperSegments = try await currentWhisper.transcribe(audioFrames: audioFrames)
            let elapsed = Date().timeIntervalSince(startTime)

            let segments = whisperSegments.map { segment in
                TranscriptionSegment(
                    text: segment.text,
                    startTime: TimeInterval(segment.startTime) / 1000.0,
                    endTime: TimeInterval(segment.endTime) / 1000.0
                )
            }

            let fullText = segments
                .map { $0.text.trimmingCharacters(in: .whitespaces) }
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespaces)

            return TranscriptionResult(
                text: fullText,
                segments: segments,
                duration: elapsed
            )
        } catch {
            throw TranscriptionError.transcriptionFailed(underlying: error)
        }
    }
}
