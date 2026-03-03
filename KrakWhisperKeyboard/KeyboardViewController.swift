#if os(iOS)
import UIKit
import SwiftUI
import AVFoundation
import Combine
import SwiftWhisper

/// Main view controller for the KrakWhisper custom keyboard extension.
///
/// This is a `UIInputViewController` subclass — required by Apple for custom keyboards.
/// It embeds a SwiftUI `KeyboardView` for the UI and manages audio recording +
/// transcription using the shared WhisperTranscriptionService.
///
/// Memory budget: Extensions are limited to ~50MB. We use the tiny or base model
/// only, and keep audio buffered in memory (no disk writes during recording).
final class KeyboardViewController: UIInputViewController {

    // MARK: - Properties

    private var hostingController: UIHostingController<KeyboardView>?
    private var heightConstraint: NSLayoutConstraint?

    /// Current keyboard state — drives the SwiftUI view.
    private var keyboardState: KeyboardState = .idle {
        didSet { updateView() }
    }

    /// Current keyboard mode (voice dictation or QWERTY typing).
    /// Default to voice mode — it's lighter on memory and the primary use case.
    private var keyboardMode: KeyboardMode = .voice {
        didSet {
            updateHeightConstraint()
            updateView()
        }
    }

    /// Shift state for QWERTY keyboard (managed here so it persists across view updates).
    private var isShifted = false {
        didSet { updateView() }
    }

    /// Transcribed text waiting to be inserted.
    private var transcribedText: String = "" {
        didSet { updateView() }
    }

    /// Audio level samples for waveform visualization.
    private var audioLevels: [Float] = [] {
        didSet { updateView() }
    }

    /// Duration of the current recording.
    private var recordingDuration: TimeInterval = 0 {
        didSet { updateView() }
    }

    // Audio engine
    private var audioEngine: AVAudioEngine?
    private var recordedFrames: [Float] = []
    private let sampleRate: Double = 16_000
    private let maxAudioLevels = 60

    /// Maximum recording duration in seconds to prevent OOM in the extension.
    /// At 16kHz Float32, 60 seconds = ~3.8MB — safe within the 50MB limit.
    private let maxRecordingDuration: TimeInterval = 60

    // Recording timer
    private var durationTimer: Timer?

    // Transcription
    private let transcriptionService = WhisperTranscriptionService()
    private var isModelLoaded = false

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()

        // Remove default keyboard background
        guard let inputView = self.inputView else { return }
        inputView.allowsSelfSizing = true

        setupHostingController()
        loadModelIfAvailable()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // Refresh model availability each time keyboard appears
        if !isModelLoaded {
            loadModelIfAvailable()
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        // Clean up if recording was in progress
        if keyboardState == .recording {
            cancelRecording()
        }
    }

    // MARK: - Setup

    private func setupHostingController() {
        let keyboardView = makeKeyboardView()
        let hosting = UIHostingController(rootView: keyboardView)
        hosting.view.translatesAutoresizingMaskIntoConstraints = false
        hosting.view.backgroundColor = .clear

        addChild(hosting)
        view.addSubview(hosting.view)
        hosting.didMove(toParent: self)

        let height = hosting.view.heightAnchor.constraint(equalToConstant: keyboardMode == .text ? 260 : 200)
        self.heightConstraint = height

        // Pin to top, leading, trailing + fixed height.
        // Do NOT pin bottom — the height constraint defines the size,
        // and pinning both top+bottom+height causes a constraint conflict
        // that iOS resolves by killing the extension.
        NSLayoutConstraint.activate([
            hosting.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hosting.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hosting.view.topAnchor.constraint(equalTo: view.topAnchor),
            height,
        ])

        self.hostingController = hosting
    }

    private func makeKeyboardView() -> KeyboardView {
        KeyboardView(
            state: keyboardState,
            transcribedText: transcribedText,
            audioLevels: audioLevels,
            recordingDuration: recordingDuration,
            modelName: SharedModelManager.keyboardModelSize.rawValue,
            mode: keyboardMode,
            isShifted: isShifted,
            onMicTap: { [weak self] in self?.handleMicTap() },
            onInsert: { [weak self] in self?.insertText() },
            onBackspace: { [weak self] in self?.handleBackspace() },
            onSpace: { [weak self] in self?.handleSpace() },
            onReturn: { [weak self] in self?.handleReturn() },
            onGlobe: { [weak self] in self?.advanceToNextInputMode() },
            onSettings: { [weak self] in self?.openMainApp() },
            onClear: { [weak self] in self?.clearTranscription() },
            onTypeChar: { [weak self] char in self?.typeCharacter(char) },
            onToggleMode: { [weak self] in self?.toggleKeyboardMode() },
            onShiftTap: { [weak self] in self?.isShifted.toggle() }
        )
    }

    private func updateView() {
        hostingController?.rootView = makeKeyboardView()
    }

    private func updateHeightConstraint() {
        heightConstraint?.constant = keyboardMode == .text ? 260 : 200
        view.setNeedsLayout()
    }

    // MARK: - Model Loading

    private func loadModelIfAvailable() {
        guard SharedModelManager.hasAnyModel else {
            keyboardState = .noModel
            return
        }

        let modelSize = SharedModelManager.keyboardModelSize
        guard let modelURL = SharedModelManager.modelURL(for: modelSize) else {
            keyboardState = .noModel
            return
        }

        Task {
            do {
                try await transcriptionService.loadModel(from: modelURL, size: modelSize)
                isModelLoaded = true
                if keyboardState == .noModel {
                    keyboardState = .idle
                }
            } catch {
                keyboardState = .error("Model load failed")
                isModelLoaded = false
            }
        }
    }

    // MARK: - Mic Actions

    private func handleMicTap() {
        switch keyboardState {
        case .recording:
            stopRecordingAndTranscribe()
        case .idle, .completed, .error:
            startRecording()
        default:
            break
        }
    }

    // MARK: - Recording

    private func startRecording() {
        guard isModelLoaded else {
            keyboardState = .error("No model loaded")
            return
        }

        // Request mic permission — use modern API (iOS 17+)
        Task {
            let granted = await AVAudioApplication.requestRecordPermission()
            await MainActor.run {
                if granted {
                    self.beginAudioCapture()
                } else {
                    self.keyboardState = .error("Mic access denied")
                }
            }
        }
    }

    private func beginAudioCapture() {
        // Reset state
        recordedFrames = []
        audioLevels = []
        recordingDuration = 0
        transcribedText = ""

        // Configure audio session
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.record, mode: .measurement, options: [])
            try session.setPreferredSampleRate(sampleRate)
            try session.setActive(true, options: [])
        } catch {
            keyboardState = .error("Audio session error")
            return
        }

        // Set up audio engine
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        guard let desiredFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            keyboardState = .error("Audio format error")
            return
        }

        let converter = AVAudioConverter(from: inputFormat, to: desiredFormat)

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }

            let level = self.calculateRMSLevel(buffer: buffer)

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
                    DispatchQueue.main.async {
                        self.recordedFrames.append(contentsOf: frames)
                        self.appendAudioLevel(level)
                    }
                }
            }
        }

        do {
            try engine.start()
            audioEngine = engine
            keyboardState = .recording

            // Start duration timer with auto-stop at max duration
            durationTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                DispatchQueue.main.async {
                    guard let self, self.keyboardState == .recording else { return }
                    self.recordingDuration += 0.1

                    // Auto-stop at max duration to prevent OOM in extension
                    if self.recordingDuration >= self.maxRecordingDuration {
                        self.stopRecordingAndTranscribe()
                    }
                }
            }
        } catch {
            keyboardState = .error("Mic start failed")
        }
    }

    private func stopRecordingAndTranscribe() {
        // Stop audio
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        durationTimer?.invalidate()
        durationTimer = nil

        // Deactivate audio session
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)

        let frames = recordedFrames
        guard !frames.isEmpty else {
            keyboardState = .error("No audio captured")
            return
        }

        // Transcribe
        keyboardState = .transcribing
        Task {
            do {
                let result = try await transcriptionService.transcribe(audioFrames: frames)
                transcribedText = result.text
                keyboardState = .completed(result.text)
            } catch {
                keyboardState = .error("Transcription failed")
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
        keyboardState = .idle
    }

    // MARK: - Audio Level

    private func appendAudioLevel(_ level: Float) {
        audioLevels.append(level)
        if audioLevels.count > maxAudioLevels {
            audioLevels.removeFirst(audioLevels.count - maxAudioLevels)
        }
    }

    private func calculateRMSLevel(buffer: AVAudioPCMBuffer) -> Float {
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

    // MARK: - Mode Toggle

    private func toggleKeyboardMode() {
        // Don't toggle while recording
        guard keyboardState != .recording && keyboardState != .transcribing else { return }
        keyboardMode = (keyboardMode == .voice) ? .text : .voice
    }

    private func typeCharacter(_ char: String) {
        textDocumentProxy.insertText(char)
    }

    // MARK: - Text Actions

    private func insertText() {
        guard !transcribedText.isEmpty else { return }
        textDocumentProxy.insertText(transcribedText)
        clearTranscription()
    }

    private func clearTranscription() {
        transcribedText = ""
        recordedFrames = []
        audioLevels = []
        recordingDuration = 0
        keyboardState = .idle
    }

    private func handleBackspace() {
        textDocumentProxy.deleteBackward()
    }

    private func handleSpace() {
        textDocumentProxy.insertText(" ")
    }

    private func handleReturn() {
        textDocumentProxy.insertText("\n")
    }

    // MARK: - App Switching

    private func openMainApp() {
        // Open the main app via URL scheme
        guard let url = URL(string: "krakwhisper://settings") else { return }

        // Extensions can't call UIApplication.shared.open directly.
        // We use the responder chain trick.
        var responder: UIResponder? = self
        while let nextResponder = responder?.next {
            if let application = nextResponder as? UIApplication {
                application.open(url, options: [:], completionHandler: nil)
                return
            }
            responder = nextResponder
        }
    }

    // MARK: - Text Input Overrides

    override func textWillChange(_ textInput: (any UITextInput)?) {
        // Called when the text is about to change in the document
    }

    override func textDidChange(_ textInput: (any UITextInput)?) {
        // Called when text has changed — we could update appearance here
    }
}

#endif // os(iOS)
