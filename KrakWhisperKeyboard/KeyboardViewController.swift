#if os(iOS)
import UIKit
import AVFoundation

// MARK: - KrakWhisper QWERTY Keyboard
// Records audio, sends to Contabo whisper.cpp server, inserts transcript.
// Pure UIKit — no SwiftUI, no Whisper framework (stays under 42MB).

final class KeyboardViewController: UIInputViewController {
    
    private enum KeyboardPage { case letters, numbers, symbols }
    private enum RecordingState { case idle, recording, transcribing }
    
    // Whisper API endpoint on Contabo
    private let whisperURL = "http://157.173.203.33:8178/inference"
    
    private var keyboardPage: KeyboardPage = .letters
    private var isShifted = true
    private var recordingState: RecordingState = .idle
    
    // Audio
    private var audioEngine: AVAudioEngine?
    private var recordedFrames: [Float] = []
    private let sampleRate: Double = 16_000
    private var recordingDuration: TimeInterval = 0
    private var durationTimer: Timer?
    
    // UI
    private let containerView = UIView()
    private var keyRows: [UIStackView] = []
    private let statusLabel = UILabel()
    private var micButton: UIButton?
    
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
    
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if recordingState == .recording { cancelRecording() }
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
    
    private func buildKeyRows() {
        keyRows.forEach { $0.removeFromSuperview() }
        keyRows.removeAll()
        
        let rows: [[String]]
        switch keyboardPage {
        case .letters: rows = letterRows
        case .numbers: rows = numberRows
        case .symbols: rows = symbolRows
        }
        
        var prev = statusLabel.bottomAnchor
        let h: CGFloat = 42, sp: CGFloat = 6, pad: CGFloat = 3
        
        for (i, keys) in rows.enumerated() {
            let stack = UIStackView()
            stack.axis = .horizontal; stack.spacing = 4; stack.distribution = .fillEqually
            stack.translatesAutoresizingMaskIntoConstraints = false
            containerView.addSubview(stack)
            
            if i == 2 && keyboardPage == .letters {
                let btn = makeSpecial(nil, UIImage(systemName: isShifted ? "shift.fill" : "shift"), #selector(shiftTapped))
                btn.widthAnchor.constraint(equalToConstant: 40).isActive = true
                stack.addArrangedSubview(btn)
            }
            if i == 2 && keyboardPage != .letters {
                let t = keyboardPage == .numbers ? "#+=" : "123"
                let btn = makeSpecial(t, nil, #selector(symbolToggleTapped))
                btn.widthAnchor.constraint(equalToConstant: 44).isActive = true
                stack.addArrangedSubview(btn)
            }
            for key in keys { stack.addArrangedSubview(makeKey(key)) }
            if i == 2 {
                let btn = makeSpecial(nil, UIImage(systemName: "delete.left"), #selector(backspaceTapped))
                btn.widthAnchor.constraint(equalToConstant: 40).isActive = true
                stack.addArrangedSubview(btn)
            }
            
            NSLayoutConstraint.activate([
                stack.topAnchor.constraint(equalTo: prev, constant: sp),
                stack.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: pad),
                stack.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -pad),
                stack.heightAnchor.constraint(equalToConstant: h),
            ])
            keyRows.append(stack)
            prev = stack.bottomAnchor
        }
        
        // Bottom row
        let bot = UIStackView()
        bot.axis = .horizontal; bot.spacing = 4
        bot.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(bot)
        
        let globe = makeSpecial(nil, UIImage(systemName: "globe"), #selector(globeTapped))
        globe.widthAnchor.constraint(equalToConstant: 40).isActive = true
        bot.addArrangedSubview(globe)
        
        let pg = makeSpecial(keyboardPage == .letters ? "123" : "ABC", nil, #selector(pageToggleTapped))
        pg.widthAnchor.constraint(equalToConstant: 44).isActive = true
        bot.addArrangedSubview(pg)
        
        let mic = UIButton(type: .system)
        updateMic(mic)
        mic.widthAnchor.constraint(equalToConstant: 40).isActive = true
        mic.addTarget(self, action: #selector(micTapped), for: .touchUpInside)
        bot.addArrangedSubview(mic)
        micButton = mic
        
        let space = UIButton(type: .system)
        space.setTitle("space", for: .normal)
        space.titleLabel?.font = .systemFont(ofSize: 15)
        space.backgroundColor = .systemGray5
        space.setTitleColor(.label, for: .normal)
        space.layer.cornerRadius = 5
        space.addTarget(self, action: #selector(spaceTapped), for: .touchUpInside)
        space.setContentHuggingPriority(.defaultLow, for: .horizontal)
        bot.addArrangedSubview(space)
        
        let ret = makeSpecial("return", nil, #selector(returnTapped))
        ret.backgroundColor = .systemGray4
        ret.widthAnchor.constraint(equalToConstant: 72).isActive = true
        bot.addArrangedSubview(ret)
        
        NSLayoutConstraint.activate([
            bot.topAnchor.constraint(equalTo: prev, constant: sp),
            bot.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: pad),
            bot.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -pad),
            bot.heightAnchor.constraint(equalToConstant: h),
        ])
        keyRows.append(bot)
    }
    
    // MARK: - Button Factory
    
    private func makeKey(_ title: String) -> UIButton {
        let b = UIButton(type: .system)
        b.setTitle((keyboardPage == .letters && isShifted) ? title.uppercased() : title, for: .normal)
        b.titleLabel?.font = .systemFont(ofSize: 22)
        b.backgroundColor = .systemGray5; b.setTitleColor(.label, for: .normal)
        b.layer.cornerRadius = 5
        b.layer.shadowColor = UIColor.black.cgColor
        b.layer.shadowOffset = CGSize(width: 0, height: 1)
        b.layer.shadowOpacity = 0.15; b.layer.shadowRadius = 0.5
        b.addTarget(self, action: #selector(keyTapped(_:)), for: .touchUpInside)
        return b
    }
    
    private func makeSpecial(_ title: String?, _ image: UIImage?, _ action: Selector) -> UIButton {
        let b = UIButton(type: .system)
        if let t = title { b.setTitle(t, for: .normal); b.titleLabel?.font = .systemFont(ofSize: 14, weight: .medium) }
        if let i = image { b.setImage(i, for: .normal) }
        b.backgroundColor = .systemGray3; b.tintColor = .label; b.layer.cornerRadius = 5
        b.addTarget(self, action: action, for: .touchUpInside)
        return b
    }
    
    private func updateMic(_ b: UIButton) {
        switch recordingState {
        case .idle:
            b.setImage(UIImage(systemName: "mic.fill"), for: .normal)
            b.backgroundColor = .systemGray3; b.tintColor = .label
        case .recording:
            b.setImage(UIImage(systemName: "stop.fill"), for: .normal)
            b.backgroundColor = .systemRed; b.tintColor = .white
        case .transcribing:
            b.setImage(UIImage(systemName: "waveform"), for: .normal)
            b.backgroundColor = .systemBlue; b.tintColor = .white
        }
        b.layer.cornerRadius = 5
    }
    
    // MARK: - Key Actions
    
    @objc private func keyTapped(_ s: UIButton) {
        guard let t = s.title(for: .normal) else { return }
        textDocumentProxy.insertText(t)
        if keyboardPage == .letters && isShifted { isShifted = false; buildKeyRows() }
    }
    @objc private func shiftTapped() { isShifted.toggle(); buildKeyRows() }
    @objc private func backspaceTapped() { textDocumentProxy.deleteBackward() }
    @objc private func spaceTapped() { textDocumentProxy.insertText(" ") }
    @objc private func returnTapped() { textDocumentProxy.insertText("\n") }
    @objc private func globeTapped() { advanceToNextInputMode() }
    @objc private func pageToggleTapped() {
        keyboardPage = (keyboardPage == .letters) ? .numbers : .letters; buildKeyRows()
    }
    @objc private func symbolToggleTapped() {
        keyboardPage = (keyboardPage == .numbers) ? .symbols : .numbers; buildKeyRows()
    }
    
    // MARK: - Mic / Recording
    
    @objc private func micTapped() {
        switch recordingState {
        case .idle: startRecording()
        case .recording: stopAndTranscribe()
        case .transcribing: break
        }
    }
    
    private func startRecording() {
        recordedFrames = []; recordingDuration = 0
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.record, mode: .measurement, options: [])
            try session.setPreferredSampleRate(sampleRate)
            try session.setActive(true, options: [])
        } catch {
            statusLabel.text = "⚠️ Enable mic in Settings → KrakWhisper"
            statusLabel.textColor = .systemRed; return
        }
        
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let fmt = input.outputFormat(forBus: 0)
        guard let desired = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false) else { return }
        let conv = AVAudioConverter(from: fmt, to: desired)
        
        input.installTap(onBus: 0, bufferSize: 1024, format: fmt) { [weak self] buf, _ in
            guard let self, let conv else { return }
            let fc = AVAudioFrameCount(Double(buf.frameLength) * self.sampleRate / fmt.sampleRate)
            guard let cb = AVAudioPCMBuffer(pcmFormat: desired, frameCapacity: fc) else { return }
            var err: NSError?
            let st = conv.convert(to: cb, error: &err) { _, os in os.pointee = .haveData; return buf }
            if st == .haveData, let cd = cb.floatChannelData {
                let frames = Array(UnsafeBufferPointer(start: cd[0], count: Int(cb.frameLength)))
                DispatchQueue.main.async { self.recordedFrames.append(contentsOf: frames) }
            }
        }
        
        do {
            try engine.start()
            audioEngine = engine
            recordingState = .recording
            if let m = micButton { updateMic(m) }
            durationTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                guard let self, self.recordingState == .recording else { return }
                self.recordingDuration += 0.1
                self.statusLabel.text = String(format: "🎤 %.1fs", self.recordingDuration)
                self.statusLabel.textColor = .systemRed
                if self.recordingDuration >= 60 { self.stopAndTranscribe() }
            }
        } catch {
            statusLabel.text = "Mic failed"; statusLabel.textColor = .systemRed
        }
    }
    
    private func stopAndTranscribe() {
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop(); audioEngine = nil
        durationTimer?.invalidate(); durationTimer = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        
        let frames = recordedFrames
        guard frames.count > 1600 else { // < 0.1s
            statusLabel.text = "Too short"; statusLabel.textColor = .systemOrange
            recordingState = .idle; if let m = micButton { updateMic(m) }; return
        }
        
        recordingState = .transcribing
        if let m = micButton { updateMic(m) }
        statusLabel.text = "⏳ Transcribing..."; statusLabel.textColor = .systemBlue
        
        // Encode WAV
        let wavData = encodeWAV(samples: frames)
        
        // Send to Contabo whisper server
        sendToWhisperAPI(wavData: wavData)
    }
    
    // MARK: - Whisper API
    
    private func sendToWhisperAPI(wavData: Data) {
        guard let url = URL(string: whisperURL) else {
            handleError("Invalid API URL"); return
        }
        
        let boundary = "KrakWhisper-\(UUID().uuidString)"
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30
        
        // Build multipart body
        var body = Data()
        
        // Audio file
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(wavData)
        body.append("\r\n".data(using: .utf8)!)
        
        // Response format
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"response_format\"\r\n\r\n".data(using: .utf8)!)
        body.append("json\r\n".data(using: .utf8)!)
        
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        
        request.httpBody = body
        
        let startTime = Date()
        
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self else { return }
                
                if let error {
                    if (error as NSError).code == NSURLErrorTimedOut {
                        self.handleError("Timeout — check internet")
                    } else {
                        self.handleError("Network error")
                    }
                    return
                }
                
                guard let data,
                      let httpResp = response as? HTTPURLResponse,
                      httpResp.statusCode == 200 else {
                    self.handleError("Server error")
                    return
                }
                
                // Parse response: {"text": "..."}
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let text = json["text"] as? String {
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.isEmpty {
                        self.statusLabel.text = "No speech detected"
                        self.statusLabel.textColor = .systemOrange
                    } else {
                        self.textDocumentProxy.insertText(trimmed + " ")
                        let dur = String(format: "%.1fs", Date().timeIntervalSince(startTime))
                        self.statusLabel.text = "✓ Whisper · \(dur)"
                        self.statusLabel.textColor = .systemGreen
                    }
                } else {
                    self.handleError("Bad response")
                }
                
                self.recordingState = .idle
                if let m = self.micButton { self.updateMic(m) }
                
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    guard self.recordingState == .idle else { return }
                    self.statusLabel.text = "KrakWhisper"
                    self.statusLabel.textColor = .secondaryLabel
                }
            }
        }.resume()
    }
    
    private func handleError(_ msg: String) {
        statusLabel.text = "⚠️ \(msg)"
        statusLabel.textColor = .systemRed
        recordingState = .idle
        if let m = micButton { updateMic(m) }
    }
    
    // MARK: - WAV Encoding
    
    private func encodeWAV(samples: [Float]) -> Data {
        let dataSize = samples.count * 2
        var d = Data()
        d.append(contentsOf: "RIFF".utf8)
        appendUInt32(&d, UInt32(36 + dataSize))
        d.append(contentsOf: "WAVE".utf8)
        d.append(contentsOf: "fmt ".utf8)
        appendUInt32(&d, 16)
        appendUInt16(&d, 1) // PCM
        appendUInt16(&d, 1) // mono
        appendUInt32(&d, 16000) // sample rate
        appendUInt32(&d, 32000) // byte rate
        appendUInt16(&d, 2) // block align
        appendUInt16(&d, 16) // bits per sample
        d.append(contentsOf: "data".utf8)
        appendUInt32(&d, UInt32(dataSize))
        for s in samples {
            let v = Int16(max(-1, min(1, s)) * 32767)
            appendInt16(&d, v)
        }
        return d
    }
    
    private func appendUInt32(_ d: inout Data, _ v: UInt32) {
        withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) }
    }
    private func appendUInt16(_ d: inout Data, _ v: UInt16) {
        withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) }
    }
    private func appendInt16(_ d: inout Data, _ v: Int16) {
        withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) }
    }
    
    private func cancelRecording() {
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop(); audioEngine = nil
        durationTimer?.invalidate()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        recordedFrames = []; recordingState = .idle
        if let m = micButton { updateMic(m) }
    }
}
#endif
