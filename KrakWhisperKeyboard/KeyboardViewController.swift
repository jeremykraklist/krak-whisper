#if os(iOS)
import UIKit
import AVFoundation
import SwiftWhisper

// MARK: - KeyboardViewController (Pure UIKit — no SwiftUI)

final class KeyboardViewController: UIInputViewController {
    
    // MARK: - State
    
    private enum RecordingState {
        case idle
        case recording
        case transcribing
    }
    
    private enum KeyboardPage {
        case letters
        case numbers
        case symbols
    }
    
    private var recordingState: RecordingState = .idle
    private var keyboardPage: KeyboardPage = .letters
    private var isShifted = true // Start shifted for first letter
    private var transcribedText = ""
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
    
    // MARK: - UI Elements
    
    private let containerView = UIView()
    private var keyRows: [UIStackView] = []
    private let statusLabel = UILabel()
    private let micButton = UIButton(type: .system)
    
    // Key definitions
    private let letterRows = [
        ["q","w","e","r","t","y","u","i","o","p"],
        ["a","s","d","f","g","h","j","k","l"],
        ["z","x","c","v","b","n","m"]
    ]
    private let numberRows = [
        ["1","2","3","4","5","6","7","8","9","0"],
        ["-","/",":",";","(",")","$","&","@","\""],
        [".",",","?","!","\'"]
    ]
    private let symbolRows = [
        ["[","]","{","}","#","%","^","*","+","="],
        ["_","\\","|","~","<",">","€","£","¥","·"],
        [".",",","?","!","\'"]
    ]
    
    // MARK: - Lifecycle
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        guard let inputView = self.inputView else { return }
        inputView.allowsSelfSizing = true
        
        setupKeyboard()
        loadModelIfAvailable()
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if !isModelLoaded { loadModelIfAvailable() }
    }
    
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if recordingState == .recording { cancelRecording() }
    }
    
    // MARK: - Keyboard Setup
    
    private func setupKeyboard() {
        containerView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(containerView)
        
        NSLayoutConstraint.activate([
            containerView.topAnchor.constraint(equalTo: view.topAnchor),
            containerView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            containerView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            containerView.heightAnchor.constraint(equalToConstant: 260),
        ])
        
        // Status bar at top
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabel
        statusLabel.textAlignment = .center
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(statusLabel)
        
        NSLayoutConstraint.activate([
            statusLabel.topAnchor.constraint(equalTo: containerView.topAnchor, constant: 2),
            statusLabel.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 8),
            statusLabel.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -8),
            statusLabel.heightAnchor.constraint(equalToConstant: 16),
        ])
        
        buildKeyRows()
    }
    
    private func buildKeyRows() {
        // Remove old rows
        keyRows.forEach { $0.removeFromSuperview() }
        keyRows.removeAll()
        
        let rows: [[String]]
        switch keyboardPage {
        case .letters: rows = letterRows
        case .numbers: rows = numberRows
        case .symbols: rows = symbolRows
        }
        
        var previousAnchor = statusLabel.bottomAnchor
        let rowHeight: CGFloat = 42
        let spacing: CGFloat = 6
        let sidePadding: CGFloat = 3
        
        // Key rows
        for (index, keys) in rows.enumerated() {
            let rowStack = UIStackView()
            rowStack.axis = .horizontal
            rowStack.spacing = 4
            rowStack.distribution = .fillEqually
            rowStack.translatesAutoresizingMaskIntoConstraints = false
            containerView.addSubview(rowStack)
            
            // Add shift key to left of row 3 (letters mode)
            if index == 2 && keyboardPage == .letters {
                let shiftBtn = makeSpecialKey(
                    title: nil,
                    image: UIImage(systemName: isShifted ? "shift.fill" : "shift"),
                    action: #selector(shiftTapped)
                )
                shiftBtn.widthAnchor.constraint(equalToConstant: 40).isActive = true
                rowStack.addArrangedSubview(shiftBtn)
            }
            
            // Add symbol toggle for row 3 in numbers/symbols mode
            if index == 2 && keyboardPage != .letters {
                let toggleTitle = keyboardPage == .numbers ? "#+=" : "123"
                let toggleBtn = makeSpecialKey(title: toggleTitle, image: nil, action: #selector(symbolToggleTapped))
                toggleBtn.widthAnchor.constraint(equalToConstant: 44).isActive = true
                rowStack.addArrangedSubview(toggleBtn)
            }
            
            for key in keys {
                let btn = makeKeyButton(title: key)
                rowStack.addArrangedSubview(btn)
            }
            
            // Add backspace to right of row 3
            if index == 2 {
                let deleteBtn = makeSpecialKey(
                    title: nil,
                    image: UIImage(systemName: "delete.left"),
                    action: #selector(backspaceTapped)
                )
                deleteBtn.widthAnchor.constraint(equalToConstant: 40).isActive = true
                rowStack.addArrangedSubview(deleteBtn)
            }
            
            NSLayoutConstraint.activate([
                rowStack.topAnchor.constraint(equalTo: previousAnchor, constant: spacing),
                rowStack.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: sidePadding),
                rowStack.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -sidePadding),
                rowStack.heightAnchor.constraint(equalToConstant: rowHeight),
            ])
            
            keyRows.append(rowStack)
            previousAnchor = rowStack.bottomAnchor
        }
        
        // Bottom row: globe, 123/ABC, mic, space, return
        let bottomRow = UIStackView()
        bottomRow.axis = .horizontal
        bottomRow.spacing = 4
        bottomRow.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(bottomRow)
        
        // Globe
        let globeBtn = makeSpecialKey(title: nil, image: UIImage(systemName: "globe"), action: #selector(globeTapped))
        globeBtn.widthAnchor.constraint(equalToConstant: 40).isActive = true
        bottomRow.addArrangedSubview(globeBtn)
        
        // 123/ABC toggle
        let pageTitle = keyboardPage == .letters ? "123" : "ABC"
        let pageBtn = makeSpecialKey(title: pageTitle, image: nil, action: #selector(pageToggleTapped))
        pageBtn.widthAnchor.constraint(equalToConstant: 44).isActive = true
        bottomRow.addArrangedSubview(pageBtn)
        
        // Mic button
        micButton.removeTarget(nil, action: nil, for: .allEvents)
        configureMicButton()
        micButton.widthAnchor.constraint(equalToConstant: 40).isActive = true
        bottomRow.addArrangedSubview(micButton)
        
        // Space bar
        let spaceBtn = UIButton(type: .system)
        spaceBtn.setTitle("space", for: .normal)
        spaceBtn.titleLabel?.font = .systemFont(ofSize: 15)
        spaceBtn.backgroundColor = UIColor.systemGray5
        spaceBtn.setTitleColor(.label, for: .normal)
        spaceBtn.layer.cornerRadius = 5
        spaceBtn.addTarget(self, action: #selector(spaceTapped), for: .touchUpInside)
        spaceBtn.setContentHuggingPriority(.defaultLow, for: .horizontal)
        bottomRow.addArrangedSubview(spaceBtn)
        
        // Return
        let returnBtn = makeSpecialKey(title: "return", image: nil, action: #selector(returnTapped))
        returnBtn.backgroundColor = UIColor.systemGray4
        returnBtn.widthAnchor.constraint(equalToConstant: 72).isActive = true
        bottomRow.addArrangedSubview(returnBtn)
        
        NSLayoutConstraint.activate([
            bottomRow.topAnchor.constraint(equalTo: previousAnchor, constant: spacing),
            bottomRow.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: sidePadding),
            bottomRow.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -sidePadding),
            bottomRow.heightAnchor.constraint(equalToConstant: rowHeight),
        ])
        
        keyRows.append(bottomRow)
        updateStatusLabel()
    }
    
    // MARK: - Key Factory
    
    private func makeKeyButton(title: String) -> UIButton {
        let btn = UIButton(type: .system)
        let displayTitle = (keyboardPage == .letters && isShifted) ? title.uppercased() : title
        btn.setTitle(displayTitle, for: .normal)
        btn.titleLabel?.font = .systemFont(ofSize: 22)
        btn.backgroundColor = UIColor.systemGray5
        btn.setTitleColor(.label, for: .normal)
        btn.layer.cornerRadius = 5
        btn.layer.shadowColor = UIColor.black.cgColor
        btn.layer.shadowOffset = CGSize(width: 0, height: 1)
        btn.layer.shadowOpacity = 0.15
        btn.layer.shadowRadius = 0.5
        btn.addTarget(self, action: #selector(keyTapped(_:)), for: .touchUpInside)
        return btn
    }
    
    private func makeSpecialKey(title: String?, image: UIImage?, action: Selector) -> UIButton {
        let btn = UIButton(type: .system)
        if let title { btn.setTitle(title, for: .normal); btn.titleLabel?.font = .systemFont(ofSize: 14, weight: .medium) }
        if let image { btn.setImage(image, for: .normal) }
        btn.backgroundColor = UIColor.systemGray3
        btn.tintColor = .label
        btn.layer.cornerRadius = 5
        btn.addTarget(self, action: action, for: .touchUpInside)
        return btn
    }
    
    private func configureMicButton() {
        switch recordingState {
        case .idle:
            micButton.setImage(UIImage(systemName: "mic.fill"), for: .normal)
            micButton.backgroundColor = UIColor.systemGray3
            micButton.tintColor = .label
        case .recording:
            micButton.setImage(UIImage(systemName: "stop.fill"), for: .normal)
            micButton.backgroundColor = UIColor.systemRed
            micButton.tintColor = .white
        case .transcribing:
            micButton.setImage(UIImage(systemName: "waveform"), for: .normal)
            micButton.backgroundColor = UIColor.systemBlue
            micButton.tintColor = .white
        }
        micButton.layer.cornerRadius = 5
        micButton.addTarget(self, action: #selector(micTapped), for: .touchUpInside)
    }
    
    private func updateStatusLabel() {
        switch recordingState {
        case .idle:
            if !transcribedText.isEmpty {
                statusLabel.text = "✓ Transcribed — tap to insert"
                statusLabel.textColor = .systemGreen
            } else if !isModelLoaded {
                statusLabel.text = "Open KrakWhisper to download model"
                statusLabel.textColor = .systemOrange
            } else {
                let model = SharedModelManager.keyboardModelSize.rawValue
                statusLabel.text = "KrakWhisper · \(model)"
                statusLabel.textColor = .secondaryLabel
            }
        case .recording:
            statusLabel.text = String(format: "Recording · %.1fs", recordingDuration)
            statusLabel.textColor = .systemRed
        case .transcribing:
            statusLabel.text = "Transcribing..."
            statusLabel.textColor = .systemBlue
        }
    }
    
    // MARK: - Key Actions
    
    @objc private func keyTapped(_ sender: UIButton) {
        guard let title = sender.title(for: .normal) else { return }
        
        // If we have transcribed text waiting, insert it first
        if !transcribedText.isEmpty {
            textDocumentProxy.insertText(transcribedText)
            transcribedText = ""
        }
        
        textDocumentProxy.insertText(title)
        
        // Auto-unshift after typing a letter
        if keyboardPage == .letters && isShifted {
            isShifted = false
            buildKeyRows()
        }
    }
    
    @objc private func shiftTapped() {
        isShifted.toggle()
        buildKeyRows()
    }
    
    @objc private func backspaceTapped() {
        if !transcribedText.isEmpty {
            transcribedText = ""
            updateStatusLabel()
        } else {
            textDocumentProxy.deleteBackward()
        }
    }
    
    @objc private func spaceTapped() {
        if !transcribedText.isEmpty {
            textDocumentProxy.insertText(transcribedText)
            transcribedText = ""
            updateStatusLabel()
        }
        textDocumentProxy.insertText(" ")
    }
    
    @objc private func returnTapped() {
        if !transcribedText.isEmpty {
            textDocumentProxy.insertText(transcribedText)
            transcribedText = ""
            updateStatusLabel()
        }
        textDocumentProxy.insertText("\n")
    }
    
    @objc private func globeTapped() {
        advanceToNextInputMode()
    }
    
    @objc private func pageToggleTapped() {
        keyboardPage = (keyboardPage == .letters) ? .numbers : .letters
        buildKeyRows()
    }
    
    @objc private func symbolToggleTapped() {
        keyboardPage = (keyboardPage == .numbers) ? .symbols : .numbers
        buildKeyRows()
    }
    
    @objc private func micTapped() {
        switch recordingState {
        case .idle:
            if !transcribedText.isEmpty {
                // Insert existing transcription and start new recording
                textDocumentProxy.insertText(transcribedText)
                transcribedText = ""
            }
            startRecording()
        case .recording:
            stopRecordingAndTranscribe()
        case .transcribing:
            break
        }
    }
    
    // MARK: - Model Loading
    
    private func loadModelIfAvailable() {
        guard SharedModelManager.hasAnyModel else {
            updateStatusLabel()
            return
        }
        
        let modelSize = SharedModelManager.keyboardModelSize
        guard let modelURL = SharedModelManager.modelURL(for: modelSize) else {
            updateStatusLabel()
            return
        }
        
        Task {
            do {
                try await transcriptionService.loadModel(from: modelURL, size: modelSize)
                isModelLoaded = true
                updateStatusLabel()
            } catch {
                statusLabel.text = "Model load failed"
                statusLabel.textColor = .systemRed
            }
        }
    }
    
    // MARK: - Recording
    
    private func startRecording() {
        guard isModelLoaded else {
            statusLabel.text = "No model loaded"
            statusLabel.textColor = .systemRed
            return
        }
        
        Task {
            let granted = await AVAudioApplication.requestRecordPermission()
            await MainActor.run {
                if granted { beginAudioCapture() }
                else {
                    statusLabel.text = "Mic access denied"
                    statusLabel.textColor = .systemRed
                }
            }
        }
    }
    
    private func beginAudioCapture() {
        recordedFrames = []
        recordingDuration = 0
        
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.record, mode: .measurement, options: [])
            try session.setPreferredSampleRate(sampleRate)
            try session.setActive(true, options: [])
        } catch {
            statusLabel.text = "Audio error"
            statusLabel.textColor = .systemRed
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
        ) else { return }
        
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
            recordingState = .recording
            configureMicButton()
            
            durationTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                DispatchQueue.main.async {
                    guard let self, self.recordingState == .recording else { return }
                    self.recordingDuration += 0.1
                    self.updateStatusLabel()
                    if self.recordingDuration >= self.maxRecordingDuration {
                        self.stopRecordingAndTranscribe()
                    }
                }
            }
        } catch {
            statusLabel.text = "Mic start failed"
            statusLabel.textColor = .systemRed
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
            statusLabel.text = "No audio"
            statusLabel.textColor = .systemRed
            recordingState = .idle
            configureMicButton()
            return
        }
        
        recordingState = .transcribing
        configureMicButton()
        updateStatusLabel()
        
        Task {
            do {
                let result = try await transcriptionService.transcribe(audioFrames: frames)
                transcribedText = result.text
                recordingState = .idle
                configureMicButton()
                
                // Auto-insert the transcription
                if !result.text.isEmpty {
                    textDocumentProxy.insertText(result.text)
                    transcribedText = ""
                }
                updateStatusLabel()
            } catch {
                statusLabel.text = "Transcription failed"
                statusLabel.textColor = .systemRed
                recordingState = .idle
                configureMicButton()
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
        recordingState = .idle
        configureMicButton()
        updateStatusLabel()
    }
}
#endif
