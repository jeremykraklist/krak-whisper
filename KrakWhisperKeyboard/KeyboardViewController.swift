#if os(iOS)
import UIKit
import Speech
import AVFoundation

// MARK: - KrakWhisper QWERTY Keyboard with Speech Recognition
// Uses Apple's SFSpeechRecognizer instead of Whisper — keyboard extensions have a
// 42-45MB memory limit and Whisper's C++ library alone exceeds that.
// SFSpeechRecognizer is a system framework with zero extra memory cost.

final class KeyboardViewController: UIInputViewController {
    
    // MARK: - Types
    
    private enum KeyboardPage {
        case letters
        case numbers
        case symbols
    }
    
    private enum RecordingState {
        case idle
        case recording
        case processing
    }
    
    // MARK: - State
    
    private var keyboardPage: KeyboardPage = .letters
    private var isShifted = true
    private var recordingState: RecordingState = .idle
    
    // Speech recognition
    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var audioEngine = AVAudioEngine()
    private var liveTranscript = ""
    
    // MARK: - UI Elements
    
    private let containerView = UIView()
    private var keyRows: [UIStackView] = []
    private let statusLabel = UILabel()
    private var micButton: UIButton?
    
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
        ["_","\\","|","~","<",">"],
        [".",",","?","!","\'"]
    ]
    
    // MARK: - Lifecycle
    
    override func viewDidLoad() {
        super.viewDidLoad()
        guard let inputView = self.inputView else { return }
        inputView.allowsSelfSizing = true
        setupKeyboard()
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // Check speech authorization status after view appears (sandbox is ready)
        updateMicAvailability()
    }
    
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if recordingState == .recording { stopRecording() }
    }
    
    // MARK: - Setup
    
    private func setupKeyboard() {
        containerView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(containerView)
        
        NSLayoutConstraint.activate([
            containerView.topAnchor.constraint(equalTo: view.topAnchor),
            containerView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            containerView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            containerView.heightAnchor.constraint(equalToConstant: 260),
        ])
        
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabel
        statusLabel.textAlignment = .center
        statusLabel.text = "KrakWhisper"
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
    
    private func updateMicAvailability() {
        let authStatus = SFSpeechRecognizer.authorizationStatus()
        switch authStatus {
        case .notDetermined:
            statusLabel.text = "KrakWhisper · Tap 🎤 to enable voice"
        case .authorized:
            statusLabel.text = "KrakWhisper"
        case .denied, .restricted:
            statusLabel.text = "KrakWhisper · Voice disabled in Settings"
            statusLabel.textColor = .systemOrange
        @unknown default:
            break
        }
    }
    
    // MARK: - Build Key Rows
    
    private func buildKeyRows() {
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
        
        for (index, keys) in rows.enumerated() {
            let rowStack = UIStackView()
            rowStack.axis = .horizontal
            rowStack.spacing = 4
            rowStack.distribution = .fillEqually
            rowStack.translatesAutoresizingMaskIntoConstraints = false
            containerView.addSubview(rowStack)
            
            if index == 2 && keyboardPage == .letters {
                let shiftBtn = makeSpecialKey(
                    title: nil,
                    image: UIImage(systemName: isShifted ? "shift.fill" : "shift"),
                    action: #selector(shiftTapped)
                )
                shiftBtn.widthAnchor.constraint(equalToConstant: 40).isActive = true
                rowStack.addArrangedSubview(shiftBtn)
            }
            
            if index == 2 && keyboardPage != .letters {
                let toggleTitle = keyboardPage == .numbers ? "#+=" : "123"
                let toggleBtn = makeSpecialKey(title: toggleTitle, image: nil, action: #selector(symbolToggleTapped))
                toggleBtn.widthAnchor.constraint(equalToConstant: 44).isActive = true
                rowStack.addArrangedSubview(toggleBtn)
            }
            
            for key in keys {
                rowStack.addArrangedSubview(makeKeyButton(title: key))
            }
            
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
        
        let globeBtn = makeSpecialKey(title: nil, image: UIImage(systemName: "globe"), action: #selector(globeTapped))
        globeBtn.widthAnchor.constraint(equalToConstant: 40).isActive = true
        bottomRow.addArrangedSubview(globeBtn)
        
        let pageTitle = keyboardPage == .letters ? "123" : "ABC"
        let pageBtn = makeSpecialKey(title: pageTitle, image: nil, action: #selector(pageToggleTapped))
        pageBtn.widthAnchor.constraint(equalToConstant: 44).isActive = true
        bottomRow.addArrangedSubview(pageBtn)
        
        // Mic button
        let mic = UIButton(type: .system)
        configureMicButtonAppearance(mic)
        mic.widthAnchor.constraint(equalToConstant: 40).isActive = true
        mic.addTarget(self, action: #selector(micTapped), for: .touchUpInside)
        bottomRow.addArrangedSubview(mic)
        micButton = mic
        
        let spaceBtn = UIButton(type: .system)
        spaceBtn.setTitle("space", for: .normal)
        spaceBtn.titleLabel?.font = .systemFont(ofSize: 15)
        spaceBtn.backgroundColor = UIColor.systemGray5
        spaceBtn.setTitleColor(.label, for: .normal)
        spaceBtn.layer.cornerRadius = 5
        spaceBtn.addTarget(self, action: #selector(spaceTapped), for: .touchUpInside)
        spaceBtn.setContentHuggingPriority(.defaultLow, for: .horizontal)
        bottomRow.addArrangedSubview(spaceBtn)
        
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
    }
    
    // MARK: - Button Factory
    
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
    
    private func configureMicButtonAppearance(_ btn: UIButton) {
        switch recordingState {
        case .idle:
            btn.setImage(UIImage(systemName: "mic.fill"), for: .normal)
            btn.backgroundColor = .systemGray3
            btn.tintColor = .label
        case .recording:
            btn.setImage(UIImage(systemName: "stop.fill"), for: .normal)
            btn.backgroundColor = .systemRed
            btn.tintColor = .white
        case .processing:
            btn.setImage(UIImage(systemName: "waveform"), for: .normal)
            btn.backgroundColor = .systemBlue
            btn.tintColor = .white
        }
        btn.layer.cornerRadius = 5
    }
    
    // MARK: - Key Actions
    
    @objc private func keyTapped(_ sender: UIButton) {
        guard let title = sender.title(for: .normal) else { return }
        textDocumentProxy.insertText(title)
        if keyboardPage == .letters && isShifted {
            isShifted = false
            buildKeyRows()
        }
    }
    
    @objc private func shiftTapped() { isShifted.toggle(); buildKeyRows() }
    @objc private func backspaceTapped() { textDocumentProxy.deleteBackward() }
    @objc private func spaceTapped() { textDocumentProxy.insertText(" ") }
    @objc private func returnTapped() { textDocumentProxy.insertText("\n") }
    @objc private func globeTapped() { advanceToNextInputMode() }
    @objc private func pageToggleTapped() {
        keyboardPage = (keyboardPage == .letters) ? .numbers : .letters
        buildKeyRows()
    }
    @objc private func symbolToggleTapped() {
        keyboardPage = (keyboardPage == .numbers) ? .symbols : .numbers
        buildKeyRows()
    }
    
    // MARK: - Mic / Speech Recognition
    
    @objc private func micTapped() {
        switch recordingState {
        case .idle:
            requestPermissionsAndStart()
        case .recording:
            stopRecording()
        case .processing:
            break
        }
    }
    
    private func requestPermissionsAndStart() {
        // Check speech recognition authorization
        SFSpeechRecognizer.requestAuthorization { [weak self] authStatus in
            DispatchQueue.main.async {
                guard let self else { return }
                switch authStatus {
                case .authorized:
                    self.startRecording()
                case .denied:
                    self.statusLabel.text = "Speech recognition denied — enable in Settings"
                    self.statusLabel.textColor = .systemRed
                case .restricted:
                    self.statusLabel.text = "Speech recognition restricted on this device"
                    self.statusLabel.textColor = .systemRed
                case .notDetermined:
                    self.statusLabel.text = "Tap mic again to authorize"
                    self.statusLabel.textColor = .systemOrange
                @unknown default:
                    break
                }
            }
        }
    }
    
    private func startRecording() {
        guard let speechRecognizer, speechRecognizer.isAvailable else {
            statusLabel.text = "Speech recognition unavailable"
            statusLabel.textColor = .systemRed
            return
        }
        
        // Cancel any existing task
        recognitionTask?.cancel()
        recognitionTask = nil
        
        // Configure audio session
        let audioSession = AVAudioSession.sharedInstance()
        do {
            try audioSession.setCategory(.record, mode: .measurement, options: .duckOthers)
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            statusLabel.text = "Audio session error"
            statusLabel.textColor = .systemRed
            return
        }
        
        // Create recognition request
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = speechRecognizer.supportsOnDeviceRecognition
        recognitionRequest = request
        liveTranscript = ""
        
        // Start recognition task
        recognitionTask = speechRecognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            
            if let result {
                let text = result.bestTranscription.formattedString
                self.liveTranscript = text
                
                DispatchQueue.main.async {
                    let preview = text.count > 40 ? "..." + text.suffix(37) : text
                    self.statusLabel.text = "🎤 \(preview)"
                    self.statusLabel.textColor = .systemBlue
                }
                
                if result.isFinal {
                    DispatchQueue.main.async {
                        self.finishRecognition(text: text)
                    }
                }
            }
            
            if let error {
                DispatchQueue.main.async {
                    // Only show error if we're still recording (not user-cancelled)
                    if self.recordingState == .recording {
                        if !self.liveTranscript.isEmpty {
                            // We got partial results — insert what we have
                            self.finishRecognition(text: self.liveTranscript)
                        } else {
                            self.statusLabel.text = "Recognition error"
                            self.statusLabel.textColor = .systemRed
                            self.recordingState = .idle
                            if let mic = self.micButton { self.configureMicButtonAppearance(mic) }
                        }
                    }
                }
            }
        }
        
        // Install audio tap
        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] buffer, _ in
            self?.recognitionRequest?.append(buffer)
        }
        
        do {
            audioEngine.prepare()
            try audioEngine.start()
            
            recordingState = .recording
            if let mic = micButton { configureMicButtonAppearance(mic) }
            statusLabel.text = "🎤 Listening..."
            statusLabel.textColor = .systemRed
        } catch {
            statusLabel.text = "Mic start failed"
            statusLabel.textColor = .systemRed
        }
    }
    
    private func stopRecording() {
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        
        // If we have partial transcript, insert it
        if !liveTranscript.isEmpty {
            finishRecognition(text: liveTranscript)
        } else {
            recordingState = .idle
            if let mic = micButton { configureMicButtonAppearance(mic) }
            statusLabel.text = "KrakWhisper"
            statusLabel.textColor = .secondaryLabel
        }
    }
    
    private func finishRecognition(text: String) {
        recognitionTask?.cancel()
        recognitionTask = nil
        
        // Insert the transcribed text
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            textDocumentProxy.insertText(trimmed + " ")
            statusLabel.text = "✓ Inserted"
            statusLabel.textColor = .systemGreen
        }
        
        recordingState = .idle
        if let mic = micButton { configureMicButtonAppearance(mic) }
        liveTranscript = ""
        
        // Reset status after a moment
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, self.recordingState == .idle else { return }
            self.statusLabel.text = "KrakWhisper"
            self.statusLabel.textColor = .secondaryLabel
        }
    }
}
#endif
