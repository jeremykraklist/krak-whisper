#if os(iOS)
import UIKit
import SwiftUI
import AVFoundation
import SwiftWhisper

// MARK: - State Types

enum KeyboardState: Equatable {
    case idle
    case recording
    case transcribing
    case completed(String)
    case error(String)
    case noModel
}

enum KeyboardMode: Equatable {
    case voice
    case text
}

// MARK: - KeyboardViewController

final class KeyboardViewController: UIInputViewController {
    
    private var hostingController: UIHostingController<AnyView>?
    private var heightConstraint: NSLayoutConstraint?
    
    private var keyboardState: KeyboardState = .idle
    private var keyboardMode: KeyboardMode = .voice
    private var isShifted = false
    private var transcribedText: String = ""
    private var recordingDuration: TimeInterval = 0
    
    // Audio
    private var audioEngine: AVAudioEngine?
    private var recordedFrames: [Float] = []
    private let sampleRate: Double = 16_000
    private let maxRecordingDuration: TimeInterval = 60
    private var durationTimer: Timer?
    
    // Transcription
    private let transcriptionService = WhisperTranscriptionService()
    private var isModelLoaded = false
    
    // MARK: - Lifecycle
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        guard let inputView = self.inputView else { return }
        inputView.allowsSelfSizing = true
        
        setupHostingController()
        loadModelIfAvailable()
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if !isModelLoaded { loadModelIfAvailable() }
    }
    
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if keyboardState == .recording { cancelRecording() }
    }
    
    // MARK: - Setup
    
    private func setupHostingController() {
        let hosting = UIHostingController(rootView: AnyView(buildView()))
        hosting.view.translatesAutoresizingMaskIntoConstraints = false
        hosting.view.backgroundColor = .clear
        // Disable safe area to prevent layout issues in keyboard extensions
        hosting.additionalSafeAreaInsets = .zero
        
        addChild(hosting)
        view.addSubview(hosting.view)
        hosting.didMove(toParent: self)
        
        let height = hosting.view.heightAnchor.constraint(equalToConstant: 200)
        heightConstraint = height
        
        NSLayoutConstraint.activate([
            hosting.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hosting.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hosting.view.topAnchor.constraint(equalTo: view.topAnchor),
            height,
        ])
        
        hostingController = hosting
    }
    
    private func refreshView() {
        hostingController?.rootView = AnyView(buildView())
    }
    
    private func buildView() -> some View {
        VoiceKeyboardView(
            state: keyboardState,
            transcribedText: transcribedText,
            recordingDuration: recordingDuration,
            modelName: SharedModelManager.keyboardModelSize.rawValue,
            onMicTap: { [weak self] in self?.handleMicTap() },
            onInsert: { [weak self] in self?.insertTranscription() },
            onBackspace: { [weak self] in self?.textDocumentProxy.deleteBackward() },
            onGlobe: { [weak self] in self?.advanceToNextInputMode() },
            onClear: { [weak self] in self?.clearTranscription() }
        )
    }
    
    // MARK: - Model Loading
    
    private func loadModelIfAvailable() {
        guard SharedModelManager.hasAnyModel else {
            keyboardState = .noModel
            refreshView()
            return
        }
        
        let modelSize = SharedModelManager.keyboardModelSize
        guard let modelURL = SharedModelManager.modelURL(for: modelSize) else {
            keyboardState = .noModel
            refreshView()
            return
        }
        
        Task {
            do {
                try await transcriptionService.loadModel(from: modelURL, size: modelSize)
                isModelLoaded = true
                if keyboardState == .noModel {
                    keyboardState = .idle
                    refreshView()
                }
            } catch {
                keyboardState = .error("Model load failed")
                refreshView()
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
    
    private func startRecording() {
        guard isModelLoaded else {
            keyboardState = .error("No model loaded")
            refreshView()
            return
        }
        
        Task {
            let granted = await AVAudioApplication.requestRecordPermission()
            await MainActor.run {
                if granted { beginAudioCapture() }
                else {
                    keyboardState = .error("Mic access denied")
                    refreshView()
                }
            }
        }
    }
    
    private func beginAudioCapture() {
        recordedFrames = []
        recordingDuration = 0
        transcribedText = ""
        
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.record, mode: .measurement, options: [])
            try session.setPreferredSampleRate(sampleRate)
            try session.setActive(true, options: [])
        } catch {
            keyboardState = .error("Audio error")
            refreshView()
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
            keyboardState = .error("Format error")
            refreshView()
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
            keyboardState = .recording
            refreshView()
            
            durationTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                DispatchQueue.main.async {
                    guard let self, self.keyboardState == .recording else { return }
                    self.recordingDuration += 0.1
                    self.refreshView()
                    if self.recordingDuration >= self.maxRecordingDuration {
                        self.stopRecordingAndTranscribe()
                    }
                }
            }
        } catch {
            keyboardState = .error("Mic start failed")
            refreshView()
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
            keyboardState = .error("No audio")
            refreshView()
            return
        }
        
        keyboardState = .transcribing
        refreshView()
        
        Task {
            do {
                let result = try await transcriptionService.transcribe(audioFrames: frames)
                transcribedText = result.text
                keyboardState = .completed(result.text)
                refreshView()
            } catch {
                keyboardState = .error("Failed")
                refreshView()
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
        refreshView()
    }
    
    private func insertTranscription() {
        guard !transcribedText.isEmpty else { return }
        textDocumentProxy.insertText(transcribedText)
        clearTranscription()
    }
    
    private func clearTranscription() {
        transcribedText = ""
        recordedFrames = []
        recordingDuration = 0
        keyboardState = .idle
        refreshView()
    }
}

// MARK: - SwiftUI Voice Keyboard View

struct VoiceKeyboardView: View {
    let state: KeyboardState
    let transcribedText: String
    let recordingDuration: TimeInterval
    let modelName: String
    
    let onMicTap: () -> Void
    let onInsert: () -> Void
    let onBackspace: () -> Void
    let onGlobe: () -> Void
    let onClear: () -> Void
    
    var body: some View {
        VStack(spacing: 0) {
            // Top: status + preview
            topSection
                .frame(height: 80)
                .padding(.horizontal, 8)
                .padding(.top, 4)
            
            Spacer(minLength: 4)
            
            // Bottom: controls
            bottomControls
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
        }
        .frame(height: 200)
        .background(Color(uiColor: .systemBackground).opacity(0.95))
    }
    
    // MARK: - Top Section
    
    private var topSection: some View {
        VStack(spacing: 4) {
            // Status text
            statusText
                .font(.caption)
                .foregroundColor(.secondary)
            
            // Preview area
            if case .completed(let text) = state {
                Text(text)
                    .font(.body)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if state == .recording {
                Text(String(format: "%.1fs", recordingDuration))
                    .font(.system(.title2, design: .monospaced))
                    .foregroundColor(.red)
            } else if state == .transcribing {
                ProgressView()
                    .progressViewStyle(.circular)
            } else if state == .noModel {
                Text("Open KrakWhisper app to download a model")
                    .font(.caption)
                    .foregroundColor(.orange)
                    .multilineTextAlignment(.center)
            }
        }
    }
    
    @ViewBuilder
    private var statusText: some View {
        switch state {
        case .idle: Text("Tap mic to dictate · \(modelName)")
        case .recording: Text("Recording...")
        case .transcribing: Text("Transcribing...")
        case .completed: Text("Done ✓ Tap Insert or mic again")
        case .error(let msg): Text("⚠ \(msg)").foregroundColor(.red)
        case .noModel: Text("No model available")
        }
    }
    
    // MARK: - Bottom Controls
    
    private var bottomControls: some View {
        HStack(spacing: 16) {
            // Globe button
            Button(action: onGlobe) {
                Image(systemName: "globe")
                    .font(.title3)
                    .foregroundColor(.primary)
                    .frame(width: 36, height: 36)
            }
            
            // Backspace
            Button(action: onBackspace) {
                Image(systemName: "delete.left")
                    .font(.title3)
                    .foregroundColor(.primary)
                    .frame(width: 36, height: 36)
            }
            
            Spacer()
            
            // Main mic button
            Button(action: onMicTap) {
                ZStack {
                    Circle()
                        .fill(micColor)
                        .frame(width: 56, height: 56)
                    
                    Image(systemName: micIcon)
                        .font(.title2)
                        .foregroundColor(.white)
                }
            }
            .disabled(state == .noModel || state == .transcribing)
            
            Spacer()
            
            // Clear button (visible when completed)
            if case .completed = state {
                Button(action: onClear) {
                    Text("Clear")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .frame(width: 44, height: 36)
                }
            }
            
            // Insert button (visible when completed)
            if case .completed = state {
                Button(action: onInsert) {
                    Text("Insert")
                        .font(.caption.bold())
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.blue)
                        .cornerRadius(8)
                }
            }
        }
    }
    
    private var micColor: Color {
        switch state {
        case .recording: return .gray
        case .transcribing: return .blue
        default: return .red
        }
    }
    
    private var micIcon: String {
        switch state {
        case .recording: return "stop.fill"
        case .transcribing: return "waveform"
        default: return "mic.fill"
        }
    }
}
#endif
