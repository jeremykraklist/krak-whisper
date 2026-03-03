#if os(iOS)
import UIKit
import AVFoundation
import SwiftWhisper

/// Pure UIKit keyboard controller — no SwiftUI dependency.
/// Fallback for when UIHostingController causes crashes in keyboard extensions.
final class KeyboardViewController: UIInputViewController {

    // MARK: - Properties

    private var keyboardView: UIKitKeyboardView!
    private var heightConstraint: NSLayoutConstraint?

    private var mode: UIKitKeyboardView.Mode = .voice {
        didSet {
            keyboardView.mode = mode
            heightConstraint?.constant = mode == .text ? 260 : 200
            view.setNeedsLayout()
        }
    }

    // Audio engine
    private var audioEngine: AVAudioEngine?
    private var recordedFrames: [Float] = []
    private let sampleRate: Double = 16_000
    private let maxRecordingDuration: TimeInterval = 60

    // Recording timer
    private var durationTimer: Timer?

    // Transcription
    private let transcriptionService = WhisperTranscriptionService()
    private var isModelLoaded = false

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()

        guard let inputView = self.inputView else { return }
        inputView.allowsSelfSizing = true

        setupKeyboardView()
        loadModelIfAvailable()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if !isModelLoaded { loadModelIfAvailable() }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if keyboardView.state == .recording { cancelRecording() }
    }

    // MARK: - Setup

    private func setupKeyboardView() {
        keyboardView = UIKitKeyboardView()
        keyboardView.translatesAutoresizingMaskIntoConstraints = false
        keyboardView.modelName = SharedModelManager.keyboardModelSize.rawValue

        // Wire up callbacks
        keyboardView.onMicTap = { [weak self] in self?.handleMicTap() }
        keyboardView.onInsert = { [weak self] in self?.insertText() }
        keyboardView.onBackspace = { [weak self] in self?.textDocumentProxy.deleteBackward() }
        keyboardView.onSpace = { [weak self] in self?.textDocumentProxy.insertText(" ") }
        keyboardView.onReturn = { [weak self] in self?.textDocumentProxy.insertText("\n") }
        keyboardView.onGlobe = { [weak self] in self?.advanceToNextInputMode() }
        keyboardView.onClear = { [weak self] in self?.clearTranscription() }
        keyboardView.onToggleMode = { [weak self] in self?.toggleMode() }
        keyboardView.onTypeChar = { [weak self] char in self?.textDocumentProxy.insertText(char) }

        view.addSubview(keyboardView)

        let height = keyboardView.heightAnchor.constraint(equalToConstant: 200)
        heightConstraint = height

        NSLayoutConstraint.activate([
            keyboardView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            keyboardView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            keyboardView.topAnchor.constraint(equalTo: view.topAnchor),
            height,
        ])
    }

    // MARK: - Model Loading

    private func loadModelIfAvailable() {
        guard SharedModelManager.hasAnyModel else {
            keyboardView.state = .noModel
            return
        }

        let modelSize = SharedModelManager.keyboardModelSize
        guard let modelURL = SharedModelManager.modelURL(for: modelSize) else {
            keyboardView.state = .noModel
            return
        }

        Task {
            do {
                try await transcriptionService.loadModel(from: modelURL, size: modelSize)
                isModelLoaded = true
                if keyboardView.state == .noModel {
                    keyboardView.state = .idle
                }
            } catch {
                keyboardView.state = .error("Model load failed")
            }
        }
    }

    // MARK: - Recording

    private func handleMicTap() {
        switch keyboardView.state {
        case .recording: stopRecordingAndTranscribe()
        case .idle, .completed, .error: startRecording()
        default: break
        }
    }

    private func startRecording() {
        guard isModelLoaded else {
            keyboardView.state = .error("No model loaded")
            return
        }

        Task {
            let granted = await AVAudioApplication.requestRecordPermission()
            await MainActor.run {
                if granted {
                    self.beginAudioCapture()
                } else {
                    self.keyboardView.state = .error("Mic access denied")
                }
            }
        }
    }

    private func beginAudioCapture() {
        recordedFrames = []
        keyboardView.recordingDuration = 0
        keyboardView.transcribedText = ""

        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.record, mode: .measurement, options: [])
            try session.setPreferredSampleRate(sampleRate)
            try session.setActive(true, options: [])
        } catch {
            keyboardView.state = .error("Audio session error")
            return
        }

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        guard let desiredFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            keyboardView.state = .error("Audio format error")
            return
        }

        let converter = AVAudioConverter(from: inputFormat, to: desiredFormat)

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            guard let self, let converter else { return }

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
                DispatchQueue.main.async {
                    self.recordedFrames.append(contentsOf: frames)
                }
            }
        }

        do {
            try engine.start()
            audioEngine = engine
            keyboardView.state = .recording

            durationTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                DispatchQueue.main.async {
                    guard let self, self.keyboardView.state == .recording else { return }
                    self.keyboardView.recordingDuration += 0.1
                    if self.keyboardView.recordingDuration >= self.maxRecordingDuration {
                        self.stopRecordingAndTranscribe()
                    }
                }
            }
        } catch {
            keyboardView.state = .error("Mic start failed")
        }
    }

    private func stopRecordingAndTranscribe() {
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        durationTimer?.invalidate()
        durationTimer = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)

        let frames = recordedFrames
        guard !frames.isEmpty else {
            keyboardView.state = .error("No audio captured")
            return
        }

        keyboardView.state = .transcribing
        Task {
            do {
                let result = try await transcriptionService.transcribe(audioFrames: frames)
                keyboardView.transcribedText = result.text
                keyboardView.state = .completed(result.text)
            } catch {
                keyboardView.state = .error("Transcription failed")
            }
        }
    }

    private func cancelRecording() {
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        durationTimer?.invalidate()
        durationTimer = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        recordedFrames = []
        keyboardView.state = .idle
    }

    // MARK: - Actions

    private func toggleMode() {
        guard keyboardView.state != .recording && keyboardView.state != .transcribing else { return }
        mode = (mode == .voice) ? .text : .voice
    }

    private func insertText() {
        guard !keyboardView.transcribedText.isEmpty else { return }
        textDocumentProxy.insertText(keyboardView.transcribedText)
        clearTranscription()
    }

    private func clearTranscription() {
        keyboardView.transcribedText = ""
        recordedFrames = []
        keyboardView.recordingDuration = 0
        keyboardView.state = .idle
    }
}
#endif
