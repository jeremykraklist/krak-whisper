#if os(iOS)
import UIKit
import SwiftUI
import CryptoKit

// MARK: - KrakWhisper QWERTY Keyboard
// iOS keyboard extensions CANNOT access the microphone directly.
// Mic button opens the main app (via URL scheme) which records + transcribes.
// Keyboard receives Darwin notification when result is ready, reads encrypted
// result from App Group, decrypts, and inserts text.
//
// URL Opening Strategy (iOS 26):
// The old responder chain openURL: hack is BROKEN since iOS 18.
// We now use extensionContext?.open(url) as the primary method,
// with a SwiftUI Link overlay as fallback.

final class KeyboardViewController: UIInputViewController {
    
    private enum KeyboardPage { case letters, numbers, symbols }
    
    // App Group for sharing data with main app
    private let appGroupID = "group.com.krakwhisper.shared"
    private let resultFileName = "keyboard-result.json"
    
    private var keyboardPage: KeyboardPage = .letters
    private var isShifted = true
    private var pendingTranscription = false
    
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
        // Fallback: check if main app left a transcription result for us
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
    
    /// Register for Darwin notifications so we get alerted the instant the
    /// main app finishes transcription — no need to wait for viewDidAppear.
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
    
    // MARK: - Check for results from main app (encrypted)
    
    private func checkForTranscriptionResult() {
        guard let url = sharedURL?.appendingPathComponent(resultFileName),
              FileManager.default.fileExists(atPath: url.path),
              let rawData = try? Data(contentsOf: url) else { return }
        
        // Decrypt the data (try encrypted first, fall back to plaintext)
        let json: [String: Any]?
        if let decryptedData = try? AppGroupCrypto.decrypt(rawData),
           let decoded = try? JSONSerialization.jsonObject(with: decryptedData) as? [String: Any] {
            json = decoded
        } else if let decoded = try? JSONSerialization.jsonObject(with: rawData) as? [String: Any] {
            // Fallback: unencrypted data (backwards compatibility)
            json = decoded
        } else {
            return
        }
        
        guard let json,
              let text = json["text"] as? String,
              let consumed = json["consumed"] as? Bool,
              consumed == false else { return }
        
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        
        if !trimmed.isEmpty {
            textDocumentProxy.insertText(trimmed + " ")
            let durationMs = json["durationMs"] as? Int ?? 0
            let dur = String(format: "%.1fs", Double(durationMs) / 1000)
            statusLabel.text = "\u{2713} Whisper \u{00B7} \(dur)"
            statusLabel.textColor = .systemGreen
        } else if let error = json["error"] as? String, !error.isEmpty {
            statusLabel.text = "\u{26A0}\u{FE0F} \(error)"
            statusLabel.textColor = .systemRed
        } else {
            statusLabel.text = "No speech detected"
            statusLabel.textColor = .systemOrange
        }
        
        // Mark as consumed so we don't insert twice (re-encrypt)
        var updated = json
        updated["consumed"] = true
        if let updatedData = try? JSONSerialization.data(withJSONObject: updated),
           let encrypted = try? AppGroupCrypto.encrypt(updatedData) {
            try? encrypted.write(to: url)
        } else if let updatedData = try? JSONSerialization.data(withJSONObject: updated) {
            // Fallback: write unencrypted
            try? updatedData.write(to: url)
        }
        
        // Reset status after delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
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
        mic.backgroundColor = .systemGray3; mic.tintColor = .label; mic.layer.cornerRadius = 5
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
    
    // MARK: - Mic — Opens Main App (iOS 26 compatible)
    
    /// Invisible SwiftUI Link used as fallback for URL opening when
    /// extensionContext?.open() fails. Retains the UIHostingController
    /// (not just its view) so the SwiftUI Link stays alive for tap handling.
    private var linkHostingController: UIHostingController<OpenURLLink>?
    
    @objc private func micTapped() {
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
        
        // Write intent so main app knows to start recording immediately
        if let intentURL = sharedURL?.appendingPathComponent("keyboard-intent.json") {
            let intent: [String: Any] = ["action": "record", "timestamp": Date().timeIntervalSince1970]
            if let data = try? JSONSerialization.data(withJSONObject: intent) {
                try? data.write(to: intentURL)
            }
        }
        
        statusLabel.text = "\u{1F3A4} Opening KrakWhisper..."
        statusLabel.textColor = .systemBlue
        
        openMainApp()
    }
    
    /// Open main app via URL scheme.
    /// Strategy 1: extensionContext?.open(url) — the official NSExtensionContext API
    /// Strategy 2: SwiftUI Link programmatic trigger (KeyboardKit approach for iOS 18+)
    /// Strategy 3: Legacy responder chain (kept as last resort, unlikely to work)
    ///
    /// NOTE: All approaches require Full Access. iOS will dismiss the keyboard
    /// when the main app opens. User returns via the "Back to" status bar pill.
    private func openMainApp() {
        guard let url = URL(string: "krakwhisper://record") else {
            statusLabel.text = "\u{26A0}\u{FE0F} Invalid URL"
            statusLabel.textColor = .systemRed
            return
        }
        
        // Strategy 1: NSExtensionContext.open() — official API for extensions
        // This is the documented way for extensions to ask the system to open a URL.
        if let context = extensionContext {
            context.open(url) { [weak self] success in
                DispatchQueue.main.async {
                    if success {
                        self?.statusLabel.text = "\u{1F3A4} Recording in KrakWhisper..."
                        self?.statusLabel.textColor = .systemGreen
                    } else {
                        // Strategy 1 failed, try fallback
                        self?.openMainAppViaLink(url)
                    }
                }
            }
            return
        }
        
        // No extension context available, try fallback
        openMainAppViaLink(url)
    }
    
    /// Fallback: Use a SwiftUI Link to open the URL.
    /// This is the approach KeyboardKit 8.8.6+ uses since iOS 18 broke
    /// the selector-based method. SwiftUI Link uses a different code path
    /// that the system still honors for URL opening.
    private func openMainAppViaLink(_ url: URL) {
        // Create a temporary SwiftUI Link view and trigger it.
        // We must retain the UIHostingController (not just its view) so the
        // SwiftUI Link remains alive when we programmatically tap it.
        let linkView = OpenURLLink(url: url)
        let hosting = UIHostingController(rootView: linkView)
        hosting.view.frame = CGRect(x: -100, y: -100, width: 1, height: 1)
        hosting.view.alpha = 0.01 // Nearly invisible
        
        // Proper UIKit container view controller lifecycle
        addChild(hosting)
        view.addSubview(hosting.view)
        hosting.didMove(toParent: self)
        linkHostingController = hosting
        
        // The Link needs to be "tapped" — we trigger via accessibility
        // Give the system a moment to lay out, then trigger
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            // Find the Link button in the hosting view and trigger it
            if let linkButton = self?.findLinkButton(in: hosting.view) {
                linkButton.sendActions(for: .touchUpInside)
            } else {
                // If we can't find the link button, try legacy method
                self?.openMainAppLegacy(url)
            }
            
            // Cleanup hosting controller after a delay using proper lifecycle
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                self?.linkHostingController?.willMove(toParent: nil)
                self?.linkHostingController?.view.removeFromSuperview()
                self?.linkHostingController?.removeFromParent()
                self?.linkHostingController = nil
            }
        }
    }
    
    /// Recursively find a UIControl (the Link's button) in a view hierarchy.
    private func findLinkButton(in view: UIView) -> UIControl? {
        if let control = view as? UIControl {
            return control
        }
        for subview in view.subviews {
            if let found = findLinkButton(in: subview) {
                return found
            }
        }
        return nil
    }
    
    /// Legacy fallback: responder chain openURL (unlikely to work on iOS 26,
    /// but kept as absolute last resort).
    private func openMainAppLegacy(_ url: URL) {
        // Try the modern UIApplication.open approach via responder chain
        // Use the 1-param openURL: selector as last resort
        var responder: UIResponder? = self as UIResponder
        let selector = NSSelectorFromString("openURL:")
        while let r = responder {
            if r.responds(to: selector) {
                r.perform(selector, with: url)
                return
            }
            responder = r.next
        }
        
        statusLabel.text = "\u{26A0}\u{FE0F} Open KrakWhisper manually"
        statusLabel.textColor = .systemOrange
        
        // Reset status after delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            self?.statusLabel.text = "KrakWhisper"
            self?.statusLabel.textColor = .secondaryLabel
        }
    }
}

// MARK: - SwiftUI Link for URL Opening (iOS 18+ compatible)

/// A minimal SwiftUI view containing a Link that opens the given URL.
/// Used as a fallback when extensionContext?.open() doesn't work.
private struct OpenURLLink: View {
    let url: URL
    
    var body: some View {
        Link(destination: url) {
            Color.clear
                .frame(width: 44, height: 44)
        }
        .accessibilityIdentifier("krakwhisper-open-link")
    }
}
#endif
