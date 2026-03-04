#if os(iOS)
import UIKit
import CryptoKit

// MARK: - KrakWhisper QWERTY Keyboard with Voice Handoff
//
// iOS keyboard extensions CANNOT access the microphone (hard Apple sandbox).
// There is NO way to programmatically open the containing app from a keyboard
// extension on iOS 26 — tested exhaustively (extensionContext.open returns
// success but doesn't navigate, UIApplication.shared.open blocked, responder
// chain openURL: silently fails since iOS 18).
//
// Architecture (same pattern as GBoard, SwiftKey, KeyboardKit):
// 1. Mic button shows instructions to open main app
// 2. User opens KrakWhisper app manually
// 3. App detects keyboard intent, auto-records + transcribes
// 4. Result written to App Group (encrypted)
// 5. Darwin notification fires
// 6. Keyboard reads result and auto-inserts text
//
// The keyboard is a thin UI shell. All heavy lifting happens in the main app.

final class KeyboardViewController: UIInputViewController {
    
    private enum KeyboardPage { case letters, numbers, symbols }
    
    // App Group for sharing data with main app
    private let appGroupID = "group.com.krakwhisper.shared"
    private let resultFileName = "keyboard-result.json"
    
    private var keyboardPage: KeyboardPage = .letters
    private var isShifted = true
    private var waitingForResult = false
    
    // UI
    private let containerView = UIView()
    private var keyRows: [UIStackView] = []
    private let statusLabel = UILabel()
    private var micButton: UIButton?
    
    // Mic overlay (shown when user taps mic)
    private var micOverlay: UIView?
    
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
    
    private var sharedURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)
    }
    
    // MARK: - Lifecycle
    
    override func viewDidLoad() {
        super.viewDidLoad()
        guard let inputView = self.inputView else { return }
        inputView.allowsSelfSizing = true
        setupKeyboard()
        startListeningForTranscription()
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        checkForTranscriptionResult()
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        checkForTranscriptionResult()
    }
    
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        stopListeningForTranscription()
    }
    
    // MARK: - Darwin Notification IPC
    
    private func startListeningForTranscription() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterAddObserver(
            center,
            Unmanaged.passUnretained(self).toOpaque(),
            { (_, observer, _, _, _) in
                guard let observer = observer else { return }
                let controller = Unmanaged<KeyboardViewController>
                    .fromOpaque(observer)
                    .takeUnretainedValue()
                DispatchQueue.main.async {
                    controller.checkForTranscriptionResult()
                }
            },
            "com.krakwhisper.transcriptionReady" as CFString,
            nil,
            .deliverImmediately
        )
    }
    
    private func stopListeningForTranscription() {
        CFNotificationCenterRemoveEveryObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque()
        )
    }
    
    // MARK: - Check for results from main app
    
    private func checkForTranscriptionResult() {
        guard let url = sharedURL?.appendingPathComponent(resultFileName),
              FileManager.default.fileExists(atPath: url.path),
              let rawData = try? Data(contentsOf: url) else { return }
        
        let json: [String: Any]?
        if let decryptedData = try? AppGroupCrypto.decrypt(rawData),
           let decoded = try? JSONSerialization.jsonObject(with: decryptedData) as? [String: Any] {
            json = decoded
        } else if let decoded = try? JSONSerialization.jsonObject(with: rawData) as? [String: Any] {
            json = decoded
        } else {
            return
        }
        
        guard let json,
              let text = json["text"] as? String,
              let consumed = json["consumed"] as? Bool,
              consumed == false else { return }
        
        // Dismiss mic overlay if showing
        dismissMicOverlay()
        waitingForResult = false
        
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        
        if !trimmed.isEmpty {
            textDocumentProxy.insertText(trimmed + " ")
            let durationMs = json["durationMs"] as? Int ?? 0
            let dur = String(format: "%.1fs", Double(durationMs) / 1000)
            statusLabel.text = "\u{2713} Inserted \u{00B7} \(dur)"
            statusLabel.textColor = .systemGreen
        } else if let error = json["error"] as? String, !error.isEmpty {
            statusLabel.text = "\u{26A0}\u{FE0F} \(error)"
            statusLabel.textColor = .systemRed
        } else {
            statusLabel.text = "No speech detected"
            statusLabel.textColor = .systemOrange
        }
        
        // Mark as consumed
        var updated = json
        updated["consumed"] = true
        if let updatedData = try? JSONSerialization.data(withJSONObject: updated),
           let encrypted = try? AppGroupCrypto.encrypt(updatedData) {
            try? encrypted.write(to: url)
        } else if let updatedData = try? JSONSerialization.data(withJSONObject: updated) {
            try? updatedData.write(to: url)
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            self?.statusLabel.text = "KrakWhisper"
            self?.statusLabel.textColor = .secondaryLabel
        }
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
        mic.setImage(UIImage(systemName: "mic.fill"), for: .normal)
        mic.backgroundColor = .systemTeal; mic.tintColor = .white; mic.layer.cornerRadius = 5
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
    
    // MARK: - Mic Button — Voice Handoff
    
    @objc private func micTapped() {
        if waitingForResult {
            // Already waiting — check for result
            checkForTranscriptionResult()
            return
        }
        
        guard hasFullAccess else {
            statusLabel.text = "\u{26A0}\u{FE0F} Enable Full Access in Settings"
            statusLabel.textColor = .systemRed
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                self?.statusLabel.text = "KrakWhisper"
                self?.statusLabel.textColor = .secondaryLabel
            }
            return
        }
        
        // Clear any old result
        if let url = sharedURL?.appendingPathComponent(resultFileName) {
            try? FileManager.default.removeItem(at: url)
        }
        
        // Write intent so main app auto-records on launch
        if let intentURL = sharedURL?.appendingPathComponent("keyboard-intent.json") {
            let intent: [String: Any] = [
                "action": "record",
                "timestamp": Date().timeIntervalSince1970,
                "source": "keyboard"
            ]
            if let data = try? JSONSerialization.data(withJSONObject: intent) {
                try? data.write(to: intentURL)
            }
        }
        
        waitingForResult = true
        showMicOverlay()
    }
    
    // MARK: - Mic Overlay UI
    
    private func showMicOverlay() {
        // Show overlay on top of keys with instructions
        let overlay = UIView()
        overlay.backgroundColor = UIColor.systemBackground.withAlphaComponent(0.95)
        overlay.layer.cornerRadius = 12
        overlay.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(overlay)
        
        NSLayoutConstraint.activate([
            overlay.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 4),
            overlay.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 8),
            overlay.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -8),
            overlay.bottomAnchor.constraint(equalTo: containerView.bottomAnchor, constant: -8),
        ])
        
        // Mic icon
        let micIcon = UIImageView(image: UIImage(systemName: "mic.circle.fill"))
        micIcon.tintColor = .systemTeal
        micIcon.contentMode = .scaleAspectFit
        micIcon.translatesAutoresizingMaskIntoConstraints = false
        overlay.addSubview(micIcon)
        
        // Title
        let title = UILabel()
        title.text = "Voice Recording"
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        title.textColor = .label
        title.textAlignment = .center
        title.translatesAutoresizingMaskIntoConstraints = false
        overlay.addSubview(title)
        
        // Instructions
        let instructions = UILabel()
        instructions.text = "Open the KrakWhisper app to record.\nYour transcription will appear here automatically."
        instructions.font = .systemFont(ofSize: 13)
        instructions.textColor = .secondaryLabel
        instructions.textAlignment = .center
        instructions.numberOfLines = 0
        instructions.translatesAutoresizingMaskIntoConstraints = false
        overlay.addSubview(instructions)
        
        // Waiting indicator
        let waitLabel = UILabel()
        waitLabel.text = "\u{23F3} Waiting for transcription..."
        waitLabel.font = .systemFont(ofSize: 12, weight: .medium)
        waitLabel.textColor = .systemTeal
        waitLabel.textAlignment = .center
        waitLabel.translatesAutoresizingMaskIntoConstraints = false
        overlay.addSubview(waitLabel)
        
        // Cancel button
        let cancel = UIButton(type: .system)
        cancel.setTitle("Cancel", for: .normal)
        cancel.titleLabel?.font = .systemFont(ofSize: 14, weight: .medium)
        cancel.setTitleColor(.systemGray, for: .normal)
        cancel.addTarget(self, action: #selector(cancelMicOverlay), for: .touchUpInside)
        cancel.translatesAutoresizingMaskIntoConstraints = false
        overlay.addSubview(cancel)
        
        NSLayoutConstraint.activate([
            micIcon.topAnchor.constraint(equalTo: overlay.topAnchor, constant: 16),
            micIcon.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
            micIcon.widthAnchor.constraint(equalToConstant: 44),
            micIcon.heightAnchor.constraint(equalToConstant: 44),
            
            title.topAnchor.constraint(equalTo: micIcon.bottomAnchor, constant: 8),
            title.leadingAnchor.constraint(equalTo: overlay.leadingAnchor, constant: 16),
            title.trailingAnchor.constraint(equalTo: overlay.trailingAnchor, constant: -16),
            
            instructions.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 6),
            instructions.leadingAnchor.constraint(equalTo: overlay.leadingAnchor, constant: 20),
            instructions.trailingAnchor.constraint(equalTo: overlay.trailingAnchor, constant: -20),
            
            waitLabel.topAnchor.constraint(equalTo: instructions.bottomAnchor, constant: 12),
            waitLabel.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
            
            cancel.bottomAnchor.constraint(equalTo: overlay.bottomAnchor, constant: -8),
            cancel.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
        ])
        
        // Animate in
        overlay.alpha = 0
        UIView.animate(withDuration: 0.2) { overlay.alpha = 1 }
        
        micOverlay = overlay
        statusLabel.text = "\u{1F3A4} Open KrakWhisper app to record"
        statusLabel.textColor = .systemTeal
    }
    
    @objc private func cancelMicOverlay() {
        dismissMicOverlay()
        waitingForResult = false
        statusLabel.text = "KrakWhisper"
        statusLabel.textColor = .secondaryLabel
        
        // Clean up intent
        if let intentURL = sharedURL?.appendingPathComponent("keyboard-intent.json") {
            try? FileManager.default.removeItem(at: intentURL)
        }
    }
    
    private func dismissMicOverlay() {
        if let overlay = micOverlay {
            UIView.animate(withDuration: 0.15, animations: {
                overlay.alpha = 0
            }) { _ in
                overlay.removeFromSuperview()
            }
            micOverlay = nil
        }
    }
}

#endif
