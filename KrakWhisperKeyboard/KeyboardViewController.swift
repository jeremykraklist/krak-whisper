#if os(iOS)
import UIKit
import AVFoundation

// MARK: - KrakWhisper QWERTY Keyboard
// Primary: App Group IPC (keyboard → main app Whisper → text)
// Fallback: Contabo whisper.cpp API (if main app not responding)
// Pure UIKit — stays under 42MB memory limit.

final class KeyboardViewController: UIInputViewController {
    
    private enum KeyboardPage { case letters, numbers, symbols }
    private enum RecordingState { case idle, waking, recording, transcribing }
    
    // MARK: - Config
    
    private let appGroupID = "group.com.krakwhisper.shared"
    private let whisperAPIURL = "http://157.173.203.33:8178/inference"
    private let ipcTimeout: TimeInterval = 8 // seconds before fallback to API
    private let wakeTimeout: TimeInterval = 3 // seconds to wait for app wake
    
    // Darwin notification names
    private let wakeNotification = "com.krakwhisper.wake" as CFString
    private let requestNotification = "com.krakwhisper.transcribe.request" as CFString
    private let responseNotification = "com.krakwhisper.transcribe.response" as CFString
    private let readyNotification = "com.krakwhisper.app.ready" as CFString
    
    // App Group file names
    private let audioFileName = "keyboard-audio.wav"
    private let requestFileName = "keyboard-request.json"
    private let resultFileName = "keyboard-result.json"
    
    // MARK: - State
    
    private var keyboardPage: KeyboardPage = .letters
    private var isShifted = true
    private var recordingState: RecordingState = .idle
    private var currentRequestId: String?
    private var appIsReady = false
    
    // Audio
    private var audioEngine: AVAudioEngine?
    private var recordedFrames: [Float] = []
    private let sampleRate: Double = 16_000
    private var recordingDuration: TimeInterval = 0
    private var durationTimer: Timer?
    private var pollTimer: Timer?
    
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
    
    // Shared container
    private var sharedURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)
    }
    
    // MARK: - Lifecycle
    
    override func viewDidLoad() {
        super.viewDidLoad()
        guard let inputView = self.inputView else { return }
        inputView.allowsSelfSizing = true
        setupKeyboard()
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // Listen for transcription results and app ready signal
        observeDarwin(responseNotification) { [weak self] in self?.handleIPCResponse() }
        observeDarwin(readyNotification) { [weak self] in
            self?.appIsReady = true
            // If we were waiting for app to wake, start recording now
            if self?.recordingState == .waking {
                DispatchQueue.main.async { self?.startRecording() }
            }
        }
        // Check if app already has a recent heartbeat
        checkAppReady()
    }
    
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if recordingState == .recording { cancelRecording() }
        CFNotificationCenterRemoveEveryObserver(
            CFNotificationCenterGetDarwinNotifyCenter(), Unmanaged.passUnretained(self).toOpaque())
        pollTimer?.invalidate()
    }
    
    // MARK: - App Ready Check
    
    private func checkAppReady() {
        // Check if app wrote a heartbeat recently (within 30 seconds)
        guard let url = sharedURL?.appendingPathComponent("app-heartbeat.txt"),
              let data = try? Data(contentsOf: url),
              let str = String(data: data, encoding: .utf8),
              let ts = Double(str) else {
            appIsReady = false; return
        }
        appIsReady = Date().timeIntervalSince1970 - ts < 30
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
        case .waking:
            b.setImage(UIImage(systemName: "arrow.up.forward.app"), for: .normal)
            b.backgroundColor = .systemOrange; b.tintColor = .white
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
    
    // MARK: - Mic Flow
    
    @objc private func micTapped() {
        switch recordingState {
        case .idle: initiateRecording()
        case .waking: break // Still waiting for app
        case .recording: stopAndTranscribe()
        case .transcribing: break
        }
    }
    
    /// Step 1: Wake the main app if needed, then start recording
    private func initiateRecording() {
        if appIsReady {
            // App is already running — go straight to recording
            startRecording()
        } else {
            // Send wake signal to main app
            recordingState = .waking
            if let m = micButton { updateMic(m) }
            statusLabel.text = "🔄 Opening KrakWhisper..."
            statusLabel.textColor = .systemOrange
            
            postDarwin(wakeNotification)
            
            // Try to open the main app via URL scheme
            if let url = URL(string: "krakwhisper://wake") {
                // Keyboard extensions can't open URLs directly, but we try via shared app
                // The Darwin notification is the real mechanism
                let _ = url // suppress warning
            }
            
            // Wait for ready signal or timeout
            DispatchQueue.main.asyncAfter(deadline: .now() + wakeTimeout) { [weak self] in
                guard let self, self.recordingState == .waking else { return }
                // App didn't respond — start recording anyway (will use API fallback)
                self.appIsReady = false
                self.startRecording()
            }
        }
    }
    
    /// Step 2: Record audio
    private func startRecording() {
        recordedFrames = []; recordingDuration = 0
        
        // Check Full Access is enabled (required for mic + network)
        guard hasFullAccess else {
            statusLabel.text = "⚠️ Enable Full Access in Settings"
            statusLabel.textColor = .systemRed
            recordingState = .idle; if let m = micButton { updateMic(m) }
            return
        }
        
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.record, mode: .measurement, options: [])
            try session.setPreferredSampleRate(sampleRate)
            try session.setActive(true, options: [])
        } catch {
            statusLabel.text = "⚠️ Mic access: \(error.localizedDescription)"
            statusLabel.textColor = .systemRed
            recordingState = .idle; if let m = micButton { updateMic(m) }
            return
        }
        
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let fmt = input.outputFormat(forBus: 0)
        guard let desired = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false) else {
            recordingState = .idle; if let m = micButton { updateMic(m) }; return
        }
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
            statusLabel.text = "Mic: \(error.localizedDescription)"; statusLabel.textColor = .systemRed
            recordingState = .idle; if let m = micButton { updateMic(m) }
        }
    }
    
    /// Step 3: Stop recording and transcribe (IPC primary, API fallback)
    private func stopAndTranscribe() {
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop(); audioEngine = nil
        durationTimer?.invalidate(); durationTimer = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        
        let frames = recordedFrames
        guard frames.count > 1600 else {
            statusLabel.text = "Too short"; statusLabel.textColor = .systemOrange
            recordingState = .idle; if let m = micButton { updateMic(m) }; return
        }
        
        recordingState = .transcribing
        if let m = micButton { updateMic(m) }
        
        let wavData = encodeWAV(samples: frames)
        
        // Try IPC first
        if appIsReady, let audioURL = sharedURL?.appendingPathComponent(audioFileName),
           let reqURL = sharedURL?.appendingPathComponent(requestFileName) {
            
            statusLabel.text = "⏳ Whisper (on-device)..."
            statusLabel.textColor = .systemBlue
            
            do {
                try wavData.write(to: audioURL)
                let rid = UUID().uuidString
                currentRequestId = rid
                let req: [String: Any] = ["id": rid, "timestamp": Date().timeIntervalSince1970, "audioFile": audioFileName]
                try JSONSerialization.data(withJSONObject: req).write(to: reqURL)
                
                // Clear old result
                if let resURL = sharedURL?.appendingPathComponent(resultFileName) {
                    try? FileManager.default.removeItem(at: resURL)
                }
                
                // Notify main app
                postDarwin(requestNotification)
                
                // Poll for result
                let startTime = Date()
                pollTimer?.invalidate()
                pollTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
                    self?.checkIPCResult()
                }
                
                // Fallback to API after timeout
                DispatchQueue.main.asyncAfter(deadline: .now() + ipcTimeout) { [weak self] in
                    guard let self, self.recordingState == .transcribing,
                          self.currentRequestId == rid else { return }
                    // IPC didn't respond — fallback to Contabo API
                    self.pollTimer?.invalidate()
                    self.statusLabel.text = "⏳ Whisper (cloud)..."
                    self.statusLabel.textColor = .systemCyan
                    self.sendToWhisperAPI(wavData: wavData)
                }
                return
            } catch {
                // IPC setup failed — fall through to API
            }
        }
        
        // Direct to API (no IPC available)
        statusLabel.text = "⏳ Whisper (cloud)..."
        statusLabel.textColor = .systemCyan
        sendToWhisperAPI(wavData: wavData)
    }
    
    // MARK: - IPC Response
    
    private func handleIPCResponse() {
        DispatchQueue.main.async { self.checkIPCResult() }
    }
    
    private func checkIPCResult() {
        guard recordingState == .transcribing,
              let url = sharedURL?.appendingPathComponent(resultFileName),
              FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rid = json["id"] as? String,
              rid == currentRequestId else { return }
        
        pollTimer?.invalidate()
        
        let text = (json["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let durationMs = json["durationMs"] as? Int ?? 0
        let error = json["error"] as? String
        
        if let err = error, !err.isEmpty {
            // IPC error — try API fallback
            statusLabel.text = "⏳ Whisper (cloud)..."
            statusLabel.textColor = .systemCyan
            let wavData = encodeWAV(samples: recordedFrames)
            sendToWhisperAPI(wavData: wavData)
        } else if !text.isEmpty {
            textDocumentProxy.insertText(text + " ")
            let dur = String(format: "%.1fs", Double(durationMs) / 1000)
            statusLabel.text = "✓ Whisper (local) · \(dur)"
            statusLabel.textColor = .systemGreen
            finishTranscription()
        } else {
            statusLabel.text = "No speech detected"
            statusLabel.textColor = .systemOrange
            finishTranscription()
        }
        
        try? FileManager.default.removeItem(at: url)
    }
    
    // MARK: - Whisper API Fallback
    
    private func sendToWhisperAPI(wavData: Data) {
        guard let url = URL(string: whisperAPIURL) else {
            handleError("Invalid API URL"); return
        }
        
        let boundary = "KW-\(UUID().uuidString)"
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30
        
        var body = Data()
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\nContent-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(wavData)
        body.append("\r\n--\(boundary)\r\nContent-Disposition: form-data; name=\"response_format\"\r\n\r\njson\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body
        
        let startTime = Date()
        
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self else { return }
                
                if let error {
                    self.handleError((error as NSError).code == NSURLErrorTimedOut ? "Timeout" : "Network error")
                    return
                }
                guard let data, let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                    self.handleError("Server error"); return
                }
                
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let text = json["text"] as? String {
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.isEmpty {
                        self.statusLabel.text = "No speech detected"
                        self.statusLabel.textColor = .systemOrange
                    } else {
                        self.textDocumentProxy.insertText(trimmed + " ")
                        let dur = String(format: "%.1fs", Date().timeIntervalSince(startTime))
                        self.statusLabel.text = "✓ Whisper (cloud) · \(dur)"
                        self.statusLabel.textColor = .systemGreen
                    }
                } else {
                    self.handleError("Bad response")
                }
                self.finishTranscription()
            }
        }.resume()
    }
    
    // MARK: - Helpers
    
    private func finishTranscription() {
        recordingState = .idle
        if let m = micButton { updateMic(m) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, self.recordingState == .idle else { return }
            self.statusLabel.text = "KrakWhisper"
            self.statusLabel.textColor = .secondaryLabel
        }
    }
    
    private func handleError(_ msg: String) {
        statusLabel.text = "⚠️ \(msg)"
        statusLabel.textColor = .systemRed
        recordingState = .idle
        if let m = micButton { updateMic(m) }
    }
    
    private func cancelRecording() {
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop(); audioEngine = nil
        durationTimer?.invalidate(); pollTimer?.invalidate()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        recordedFrames = []; recordingState = .idle
        if let m = micButton { updateMic(m) }
    }
    
    // MARK: - Darwin Notifications
    
    private func postDarwin(_ name: CFString) {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(name), nil, nil, true)
    }
    
    private func observeDarwin(_ name: CFString, callback: @escaping () -> Void) {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = Unmanaged.passUnretained(self).toOpaque()
        // Store callback in a property we can look up
        darwinCallbacks[String(describing: name)] = callback
        CFNotificationCenterAddObserver(center, observer,
            { _, observer, notifName, _, _ in
                guard let observer, let notifName else { return }
                let vc = Unmanaged<KeyboardViewController>.fromOpaque(observer).takeUnretainedValue()
                let key = String(describing: notifName.rawValue)
                if let cb = vc.darwinCallbacks[key] {
                    DispatchQueue.main.async { cb() }
                }
            }, name, nil, .deliverImmediately)
    }
    
    private var darwinCallbacks: [String: () -> Void] = [:]
    
    // MARK: - WAV Encoding
    
    private func encodeWAV(samples: [Float]) -> Data {
        let dataSize = samples.count * 2
        var d = Data()
        d.append(contentsOf: "RIFF".utf8)
        appendU32(&d, UInt32(36 + dataSize))
        d.append(contentsOf: "WAVE".utf8)
        d.append(contentsOf: "fmt ".utf8)
        appendU32(&d, 16); appendU16(&d, 1); appendU16(&d, 1)
        appendU32(&d, 16000); appendU32(&d, 32000)
        appendU16(&d, 2); appendU16(&d, 16)
        d.append(contentsOf: "data".utf8)
        appendU32(&d, UInt32(dataSize))
        for s in samples {
            let v = Int16(max(-1, min(1, s)) * 32767)
            withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) }
        }
        return d
    }
    private func appendU32(_ d: inout Data, _ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
    private func appendU16(_ d: inout Data, _ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
}
#endif
