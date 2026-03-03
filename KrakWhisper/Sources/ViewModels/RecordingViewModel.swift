import Foundation
import AVFoundation
import Observation
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// Recording states for the UI.
public enum RecordingState: Equatable, Sendable {
    case idle
    case recording
    case transcribing
    case completed
    case error(String)
}

/// ViewModel for the main recording view.
@Observable
@MainActor
public final class RecordingViewModel {

    // MARK: - Published State

    public private(set) var state: RecordingState = .idle
    public private(set) var transcribedText: String = ""
    public private(set) var recordingDuration: TimeInterval = 0
    public private(set) var audioLevels: [Float] = []
    public private(set) var currentAudioLevel: Float = 0.0
    public private(set) var isModelLoaded: Bool = false
    public var selectedModelSize: WhisperModelSize = .base
    public private(set) var transcriptionDuration: TimeInterval = 0
    public private(set) var showCopyFeedback: Bool = false

    // MARK: - Private

    private let transcriptionService: any TranscriptionServiceProtocol
    private var audioEngine: AVAudioEngine?
    private var recordingTimer: Timer?
    private var recordedFrames: [Float] = []
    private let sampleRate: Double = 16_000

    /// Maximum audio level samples to keep (rolling window for waveform display).
    private let maxAudioLevels = 120

    // MARK: - Init

    public init(transcriptionService: any TranscriptionServiceProtocol = WhisperTranscriptionService()) {
        self.transcriptionService = transcriptionService
        // Read persisted model selection from UserDefaults
        if let savedRawValue = UserDefaults.standard.string(forKey: "krakwhisper.selectedModel"),
           let savedModel = WhisperModelSize(rawValue: savedRawValue) {
            self.selectedModelSize = savedModel
        }
    }

    // MARK: - Model Management

    public func loadModel() async {
        do {
            try await transcriptionService.loadModel(selectedModelSize)
            isModelLoaded = true
        } catch {
            state = .error("Failed to load model: \(error.localizedDescription)")
            isModelLoaded = false
        }
    }

    // MARK: - Recording Controls

    public func toggleRecording() {
        switch state {
        case .recording:
            stopRecording()
        case .idle, .completed, .error:
            startRecording()
        case .transcribing:
            break
        }
    }

    private func startRecording() {
        transcribedText = ""
        recordedFrames = []
        audioLevels = []
        recordingDuration = 0
        currentAudioLevel = 0

        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.record, mode: .measurement)
            try session.setActive(true)
        } catch {
            state = .error("Audio session error: \(error.localizedDescription)")
            return
        }
        #endif

        audioEngine = AVAudioEngine()
        guard let audioEngine else {
            state = .error("Failed to create audio engine")
            return
        }

        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        guard let desiredFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            state = .error("Failed to create audio format")
            return
        }

        let converter = AVAudioConverter(from: inputFormat, to: desiredFormat)

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }
            let level = self.calculateAudioLevel(buffer: buffer)

            if let converter {
                let frameCount = AVAudioFrameCount(
                    Double(buffer.frameLength) * self.sampleRate / inputFormat.sampleRate
                )
                guard let convertedBuffer = AVAudioPCMBuffer(
                    pcmFormat: desiredFormat,
                    frameCapacity: frameCount
                ) else { return }

                var error: NSError?
                let status = converter.convert(to: convertedBuffer, error: &error) { _, outStatus in
                    outStatus.pointee = .haveData
                    return buffer
                }

                if status == .haveData, let channelData = convertedBuffer.floatChannelData {
                    let frames = Array(UnsafeBufferPointer(
                        start: channelData[0],
                        count: Int(convertedBuffer.frameLength)
                    ))
                    Task { @MainActor in
                        self.recordedFrames.append(contentsOf: frames)
                        self.appendAudioLevel(level)
                    }
                }
            } else {
                if let channelData = buffer.floatChannelData {
                    let frames = Array(UnsafeBufferPointer(
                        start: channelData[0],
                        count: Int(buffer.frameLength)
                    ))
                    Task { @MainActor in
                        self.recordedFrames.append(contentsOf: frames)
                        self.appendAudioLevel(level)
                    }
                }
            }
        }

        do {
            try audioEngine.start()
            state = .recording
            recordingTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.state == .recording else { return }
                    self.recordingDuration += 0.1
                }
            }
        } catch {
            state = .error("Failed to start recording: \(error.localizedDescription)")
        }
    }

    /// Append audio level with rolling window cap.
    private func appendAudioLevel(_ level: Float) {
        currentAudioLevel = level
        audioLevels.append(level)
        if audioLevels.count > maxAudioLevels {
            audioLevels.removeFirst(audioLevels.count - maxAudioLevels)
        }
    }

    /// Stop recording and begin transcription.
    private func stopRecording() {
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        recordingTimer?.invalidate()
        recordingTimer = nil
        currentAudioLevel = 0

        // Yield to the main run loop so any queued frame-append tasks complete
        // before we snapshot recordedFrames for transcription.
        state = .transcribing

        Task { @MainActor in
            // By the time this executes, all prior MainActor tasks
            // (frame appends) will have completed.
            let frames = self.recordedFrames

            guard !frames.isEmpty else {
                self.state = .error("No audio was recorded")
                return
            }

            await self.transcribe(audioFrames: frames)
        }
    }

    private func transcribe(audioFrames: [Float]) async {
        do {
            let result = try await transcriptionService.transcribe(audioFrames: audioFrames)
            transcribedText = result.text
            transcriptionDuration = result.duration
            state = .completed

            // Auto-copy to clipboard if enabled in Settings
            let autoCopyEnabled = UserDefaults.standard.object(forKey: "krakwhisper.autoCopyToClipboard") as? Bool ?? true
            if autoCopyEnabled && !result.text.isEmpty {
                #if os(iOS)
                UIPasteboard.general.string = result.text
                #endif
                showCopyFeedback = true
                Task {
                    try? await Task.sleep(for: .seconds(2))
                    showCopyFeedback = false
                }
            }
        } catch {
            state = .error("Transcription failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Actions

    public func copyToClipboard() {
        guard !transcribedText.isEmpty else { return }

        #if os(iOS)
        UIPasteboard.general.string = transcribedText
        #elseif os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(transcribedText, forType: .string)
        #endif

        showCopyFeedback = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            showCopyFeedback = false
        }
    }

    public func clearTranscription() {
        transcribedText = ""
        recordedFrames = []
        audioLevels = []
        recordingDuration = 0
        transcriptionDuration = 0
        state = .idle
    }

    // MARK: - Helpers

    private nonisolated func calculateAudioLevel(buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData else { return 0 }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return 0 }

        var sum: Float = 0
        for i in 0..<frames {
            let sample = channelData[0][i]
            sum += sample * sample
        }
        let rms = sqrt(sum / Float(frames))
        return min(1.0, rms * 5.0)
    }

    public var formattedDuration: String {
        let minutes = Int(recordingDuration) / 60
        let seconds = Int(recordingDuration) % 60
        let tenths = Int((recordingDuration.truncatingRemainder(dividingBy: 1)) * 10)
        return String(format: "%d:%02d.%d", minutes, seconds, tenths)
    }
}
