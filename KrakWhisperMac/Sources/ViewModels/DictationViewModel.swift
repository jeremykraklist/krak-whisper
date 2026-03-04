import Foundation
import AVFoundation
import AppKit
import KrakWhisper

// MARK: - Dictation State

/// Current state of the dictation flow.
enum DictationState: Equatable {
    case idle
    case recording
    case transcribing
    case completed(String)
    case error(String)

    /// Status text for display.
    var statusText: String {
        switch self {
        case .idle: return "Ready"
        case .recording: return "Recording…"
        case .transcribing: return "Transcribing…"
        case .completed: return "Done"
        case .error(let msg): return "Error: \(msg)"
        }
    }

    /// Whether dictation can be started from this state.
    var canStartDictation: Bool {
        switch self {
        case .idle, .completed, .error: return true
        case .recording, .transcribing: return false
        }
    }

    static func == (lhs: DictationState, rhs: DictationState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle), (.recording, .recording), (.transcribing, .transcribing):
            return true
        case (.completed(let a), .completed(let b)):
            return a == b
        case (.error(let a), .error(let b)):
            return a == b
        default:
            return false
        }
    }
}

// MARK: - DictationViewModel

/// Orchestrates the record → transcribe → clipboard flow for the macOS app.
///
/// Uses WhisperTranscriptionService from the shared KrakWhisper library
/// for on-device speech recognition. Manages its own AVAudioEngine for
/// macOS-specific audio capture.
@MainActor
final class DictationViewModel: ObservableObject {

    // MARK: - Published State

    @Published private(set) var state: DictationState = .idle
    @Published private(set) var recordingDuration: TimeInterval = 0
    @Published private(set) var currentAudioLevel: Float = 0
    @Published private(set) var audioLevels: [Float] = []
    @Published private(set) var lastTranscription: String = ""
    @Published private(set) var transcriptionDuration: TimeInterval = 0
    @Published private(set) var isModelLoaded: Bool = false

    /// User preferences
    @Published var autoPaste: Bool {
        didSet { UserDefaults.standard.set(autoPaste, forKey: "krakwhisper.mac.autoPaste") }
    }

    @Published var selectedModel: WhisperModelSize {
        didSet {
            UserDefaults.standard.set(selectedModel.rawValue, forKey: "krakwhisper.mac.selectedModel")
            // Reload model when selection changes
            Task { await loadSelectedModel() }
        }
    }

    /// Callback for state changes (used by AppDelegate to update status bar icon).
    var onStateChanged: ((DictationState) -> Void)?

    // MARK: - Private Properties

    private let transcriptionService = WhisperTranscriptionService()
    private var audioEngine: AVAudioEngine?
    private var recordedFrames: [Float] = []
    private var durationTimer: Timer?
    private var recordingStartTime: Date?
    private let sampleRate: Double = 16_000
    private let maxAudioLevels = 60
    private var modelLoadTask: Task<Void, Never>?

    // MARK: - Init

    init() {
        // Default to true — UserDefaults.bool returns false for missing keys
        if UserDefaults.standard.object(forKey: "krakwhisper.mac.autoPaste") != nil {
            self.autoPaste = UserDefaults.standard.bool(forKey: "krakwhisper.mac.autoPaste")
        } else {
            self.autoPaste = true
        }

        if let savedModel = UserDefaults.standard.string(forKey: "krakwhisper.mac.selectedModel"),
           let model = WhisperModelSize(rawValue: savedModel) {
            self.selectedModel = model
        } else {
            self.selectedModel = .small
        }
    }

    // MARK: - Model Management

    /// Load the currently selected Whisper model.
    /// Cancels any in-flight model load to prevent stale results.
    func loadSelectedModel() async {
        // Cancel any prior load to avoid race conditions
        modelLoadTask?.cancel()

        let targetModel = selectedModel

        guard WhisperModelLocator.isModelDownloaded(targetModel) else {
            isModelLoaded = false
            return
        }

        let task = Task {
            do {
                try await transcriptionService.loadModel(targetModel)
                // Only apply result if the selection hasn't changed
                guard !Task.isCancelled, selectedModel == targetModel else { return }
                isModelLoaded = true
            } catch {
                guard !Task.isCancelled, selectedModel == targetModel else { return }
                isModelLoaded = false
                updateState(.error("Failed to load model: \(error.localizedDescription)"))
            }
        }
        modelLoadTask = task
        await task.value
    }

    // MARK: - Dictation Control

    /// Toggle dictation on/off (called by hotkey or UI button).
    func toggleDictation() {
        switch state {
        case .idle, .completed, .error:
            startRecording()
        case .recording:
            stopRecordingAndTranscribe()
        case .transcribing:
            break // Can't interrupt
        }
    }

    // MARK: - Recording

    private func startRecording() {
        guard isModelLoaded else {
            updateState(.error("No model loaded. Download one in Settings."))
            return
        }

        // Reset state
        recordedFrames = []
        audioLevels = []
        recordingDuration = 0
        currentAudioLevel = 0

        // Create and configure audio engine
        audioEngine = AVAudioEngine()
        guard let audioEngine else {
            updateState(.error("Failed to create audio engine"))
            return
        }

        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            updateState(.error("No microphone detected"))
            return
        }

        guard let desiredFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            updateState(.error("Failed to create audio format"))
            return
        }

        let converter = AVAudioConverter(from: inputFormat, to: desiredFormat)

        // Install tap on input node — captures audio from default mic
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }
            let level = self.calculateAudioLevel(buffer: buffer)

            if let converter {
                let ratio = self.sampleRate / inputFormat.sampleRate
                let frameCount = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1
                guard let convertedBuffer = AVAudioPCMBuffer(
                    pcmFormat: desiredFormat,
                    frameCapacity: frameCount
                ) else { return }

                var error: NSError?
                var inputConsumed = false
                converter.convert(to: convertedBuffer, error: &error) { _, outStatus in
                    if inputConsumed {
                        outStatus.pointee = .noDataNow
                        return nil
                    }
                    inputConsumed = true
                    outStatus.pointee = .haveData
                    return buffer
                }

                if error != nil { return }

                if let channelData = convertedBuffer.floatChannelData {
                    let frames = Array(UnsafeBufferPointer(
                        start: channelData[0],
                        count: Int(convertedBuffer.frameLength)
                    ))
                    Task { @MainActor in
                        self.recordedFrames.append(contentsOf: frames)
                        self.currentAudioLevel = level
                        self.audioLevels.append(level)
                        if self.audioLevels.count > self.maxAudioLevels {
                            self.audioLevels.removeFirst(self.audioLevels.count - self.maxAudioLevels)
                        }
                    }
                }
            }
        }

        do {
            try audioEngine.start()
            recordingStartTime = Date()
            durationTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, let start = self.recordingStartTime else { return }
                    self.recordingDuration = Date().timeIntervalSince(start)
                }
            }
            updateState(.recording)

            // Play a subtle sound to indicate recording started
            NSSound.beep()
        } catch {
            audioEngine.inputNode.removeTap(onBus: 0)
            updateState(.error("Microphone access failed: \(error.localizedDescription)"))
        }
    }

    private func stopRecordingAndTranscribe() {
        // Stop audio capture
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        durationTimer?.invalidate()
        durationTimer = nil
        recordingStartTime = nil
        currentAudioLevel = 0

        updateState(.transcribing)

        // Yield to the MainActor run loop so any queued frame-append tasks
        // from the audio tap complete before we snapshot recordedFrames.
        Task { @MainActor in
            let frames = self.recordedFrames
            guard !frames.isEmpty else {
                self.updateState(.error("No audio was recorded"))
                return
            }
            await self.performTranscription(frames: frames)
        }
    }

    private func performTranscription(frames: [Float]) async {
        do {
            let result = try await transcriptionService.transcribe(audioFrames: frames)
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)

            guard !text.isEmpty else {
                updateState(.error("No speech detected"))
                return
            }

            lastTranscription = text
            transcriptionDuration = result.duration

            // Always copy to clipboard
            PasteService.copyToClipboard(text)

            // Auto-paste if enabled
            if autoPaste {
                // Small delay to let the clipboard update propagate
                try? await Task.sleep(for: .milliseconds(100))
                PasteService.pasteFromClipboard()
            }

            updateState(.completed(text))

            // Auto-reset to idle after a delay
            try? await Task.sleep(for: .seconds(5))
            if case .completed = state {
                updateState(.idle)
            }
        } catch {
            updateState(.error("Transcription failed: \(error.localizedDescription)"))
        }
    }

    // MARK: - Actions

    /// Copy the last transcription to clipboard.
    func copyLastTranscription() {
        guard !lastTranscription.isEmpty else { return }
        PasteService.copyToClipboard(lastTranscription)
    }

    /// Paste the last transcription into the frontmost app.
    func pasteLastTranscription() {
        guard !lastTranscription.isEmpty else { return }
        PasteService.copyAndPaste(lastTranscription)
    }

    /// Clear the current state and transcription.
    func clear() {
        lastTranscription = ""
        audioLevels = []
        recordingDuration = 0
        transcriptionDuration = 0
        updateState(.idle)
    }

    // MARK: - Helpers

    private func updateState(_ newState: DictationState) {
        state = newState
        onStateChanged?(newState)
    }

    private nonisolated func calculateAudioLevel(buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData else { return 0 }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return 0 }

        var sum: Float = 0
        for i in 0..<frames {
            let sample = channelData[0][i]
            sum += sample * sample
        }
        return min(1.0, sqrt(sum / Float(frames)) * 5.0)
    }

    /// Formatted recording duration string (e.g., "0:03.2").
    var formattedDuration: String {
        let minutes = Int(recordingDuration) / 60
        let seconds = Int(recordingDuration) % 60
        let tenths = Int((recordingDuration.truncatingRemainder(dividingBy: 1)) * 10)
        return String(format: "%d:%02d.%d", minutes, seconds, tenths)
    }

    /// Formatted transcription processing time.
    var formattedTranscriptionTime: String {
        String(format: "%.1fs", transcriptionDuration)
    }
}
