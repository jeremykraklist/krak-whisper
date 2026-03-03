#if os(iOS)
import UIKit

/// Pure UIKit keyboard view — no SwiftUI dependency.
/// This is more reliable in keyboard extensions where SwiftUI hosting
/// can cause memory/constraint issues.
final class UIKitKeyboardView: UIView {

    // MARK: - State

    enum State {
        case idle
        case recording
        case transcribing
        case completed(String)
        case error(String)
        case noModel
    }

    enum Mode {
        case voice
        case text
    }

    var state: State = .idle { didSet { updateUI() } }
    var mode: Mode = .voice { didSet { updateUI() } }
    var recordingDuration: TimeInterval = 0 { didSet { durationLabel.text = String(format: "%.1fs", recordingDuration) } }
    var transcribedText: String = "" { didSet { previewLabel.text = transcribedText } }
    var modelName: String = "tiny" { didSet { modelLabel.text = "Model: \(modelName)" } }

    // MARK: - Callbacks

    var onMicTap: (() -> Void)?
    var onInsert: (() -> Void)?
    var onBackspace: (() -> Void)?
    var onSpace: (() -> Void)?
    var onReturn: (() -> Void)?
    var onGlobe: (() -> Void)?
    var onClear: (() -> Void)?
    var onToggleMode: (() -> Void)?
    var onTypeChar: ((String) -> Void)?

    // MARK: - UI Elements

    private let statusLabel = UILabel()
    private let previewLabel = UILabel()
    private let durationLabel = UILabel()
    private let modelLabel = UILabel()
    private let micButton = UIButton(type: .system)
    private let insertButton = UIButton(type: .system)
    private let clearButton = UIButton(type: .system)
    private let globeButton = UIButton(type: .system)
    private let modeToggleButton = UIButton(type: .system)
    private let backspaceButton = UIButton(type: .system)
    private let spaceButton = UIButton(type: .system)
    private let returnButton = UIButton(type: .system)

    // QWERTY rows
    private let qwertyStack = UIStackView()
    private let row1Keys = "qwertyuiop".map { String($0) }
    private let row2Keys = "asdfghjkl".map { String($0) }
    private let row3Keys = "zxcvbnm".map { String($0) }

    // MARK: - Init

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupUI()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupUI()
    }

    // MARK: - Setup

    private func setupUI() {
        backgroundColor = .systemBackground

        // Status label
        statusLabel.font = .systemFont(ofSize: 13, weight: .medium)
        statusLabel.textColor = .secondaryLabel
        statusLabel.textAlignment = .center

        // Preview label (transcribed text)
        previewLabel.font = .systemFont(ofSize: 15)
        previewLabel.textColor = .label
        previewLabel.textAlignment = .left
        previewLabel.numberOfLines = 3
        previewLabel.lineBreakMode = .byTruncatingTail

        // Duration label
        durationLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        durationLabel.textColor = .systemRed
        durationLabel.textAlignment = .center
        durationLabel.isHidden = true

        // Model label
        modelLabel.font = .systemFont(ofSize: 10)
        modelLabel.textColor = .tertiaryLabel
        modelLabel.textAlignment = .center

        // Mic button (big circle)
        micButton.backgroundColor = .systemRed
        micButton.layer.cornerRadius = 24
        micButton.tintColor = .white
        micButton.setImage(UIImage(systemName: "mic.fill"), for: .normal)
        micButton.addTarget(self, action: #selector(micTapped), for: .touchUpInside)

        // Insert button
        insertButton.setTitle("Insert", for: .normal)
        insertButton.titleLabel?.font = .systemFont(ofSize: 14, weight: .semibold)
        insertButton.backgroundColor = .systemBlue
        insertButton.setTitleColor(.white, for: .normal)
        insertButton.layer.cornerRadius = 8
        insertButton.addTarget(self, action: #selector(insertTapped), for: .touchUpInside)
        insertButton.isHidden = true

        // Clear button
        clearButton.setTitle("Clear", for: .normal)
        clearButton.titleLabel?.font = .systemFont(ofSize: 14)
        clearButton.setTitleColor(.systemGray, for: .normal)
        clearButton.addTarget(self, action: #selector(clearTapped), for: .touchUpInside)
        clearButton.isHidden = true

        // Globe button
        globeButton.setImage(UIImage(systemName: "globe"), for: .normal)
        globeButton.tintColor = .label
        globeButton.addTarget(self, action: #selector(globeTapped), for: .touchUpInside)

        // Mode toggle button
        modeToggleButton.setImage(UIImage(systemName: "keyboard"), for: .normal)
        modeToggleButton.tintColor = .label
        modeToggleButton.addTarget(self, action: #selector(modeToggleTapped), for: .touchUpInside)

        // Backspace button
        backspaceButton.setImage(UIImage(systemName: "delete.left"), for: .normal)
        backspaceButton.tintColor = .label
        backspaceButton.addTarget(self, action: #selector(backspaceTapped), for: .touchUpInside)

        // Space button
        spaceButton.setTitle("space", for: .normal)
        spaceButton.titleLabel?.font = .systemFont(ofSize: 14)
        spaceButton.backgroundColor = .systemGray5
        spaceButton.setTitleColor(.label, for: .normal)
        spaceButton.layer.cornerRadius = 6
        spaceButton.addTarget(self, action: #selector(spaceTapped), for: .touchUpInside)

        // Return button
        returnButton.setTitle("return", for: .normal)
        returnButton.titleLabel?.font = .systemFont(ofSize: 14)
        returnButton.backgroundColor = .systemGray4
        returnButton.setTitleColor(.label, for: .normal)
        returnButton.layer.cornerRadius = 6
        returnButton.addTarget(self, action: #selector(returnTapped), for: .touchUpInside)

        // Setup QWERTY stack (hidden by default)
        setupQWERTYKeys()

        // Layout — using AutoLayout
        let topRow = UIStackView(arrangedSubviews: [modelLabel, statusLabel, durationLabel])
        topRow.axis = .horizontal
        topRow.distribution = .fillEqually
        topRow.alignment = .center

        let bottomRow = UIStackView(arrangedSubviews: [globeButton, modeToggleButton, micButton, clearButton, insertButton])
        bottomRow.axis = .horizontal
        bottomRow.distribution = .equalSpacing
        bottomRow.alignment = .center
        bottomRow.spacing = 12

        let mainStack = UIStackView(arrangedSubviews: [topRow, previewLabel, bottomRow])
        mainStack.axis = .vertical
        mainStack.spacing = 8
        mainStack.alignment = .fill
        mainStack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(mainStack)
        addSubview(qwertyStack)

        NSLayoutConstraint.activate([
            mainStack.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            mainStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            mainStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            mainStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),

            micButton.widthAnchor.constraint(equalToConstant: 48),
            micButton.heightAnchor.constraint(equalToConstant: 48),

            qwertyStack.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            qwertyStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            qwertyStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            qwertyStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
        ])

        updateUI()
    }

    private func setupQWERTYKeys() {
        qwertyStack.axis = .vertical
        qwertyStack.spacing = 6
        qwertyStack.distribution = .fillEqually
        qwertyStack.translatesAutoresizingMaskIntoConstraints = false
        qwertyStack.isHidden = true

        let rows = [row1Keys, row2Keys, row3Keys]
        for keys in rows {
            let row = UIStackView()
            row.axis = .horizontal
            row.spacing = 4
            row.distribution = .fillEqually

            for key in keys {
                let btn = UIButton(type: .system)
                btn.setTitle(key, for: .normal)
                btn.titleLabel?.font = .systemFont(ofSize: 18)
                btn.backgroundColor = .systemGray5
                btn.setTitleColor(.label, for: .normal)
                btn.layer.cornerRadius = 5
                btn.tag = Int(key.unicodeScalars.first!.value)
                btn.addTarget(self, action: #selector(keyTapped(_:)), for: .touchUpInside)
                row.addArrangedSubview(btn)
            }
            qwertyStack.addArrangedSubview(row)
        }

        // Bottom row: globe, space, backspace, return
        let bottomRow = UIStackView(arrangedSubviews: [globeButton, spaceButton, backspaceButton, returnButton])
        bottomRow.axis = .horizontal
        bottomRow.spacing = 4
        bottomRow.distribution = .fill

        // Space gets more room
        spaceButton.setContentHuggingPriority(.defaultLow, for: .horizontal)
        globeButton.widthAnchor.constraint(equalToConstant: 40).isActive = true
        backspaceButton.widthAnchor.constraint(equalToConstant: 40).isActive = true
        returnButton.widthAnchor.constraint(equalToConstant: 60).isActive = true

        // Add mic toggle at far left of bottom
        let modeBtn = UIButton(type: .system)
        modeBtn.setImage(UIImage(systemName: "mic.fill"), for: .normal)
        modeBtn.tintColor = .systemRed
        modeBtn.addTarget(self, action: #selector(modeToggleTapped), for: .touchUpInside)
        modeBtn.widthAnchor.constraint(equalToConstant: 40).isActive = true
        bottomRow.insertArrangedSubview(modeBtn, at: 0)

        qwertyStack.addArrangedSubview(bottomRow)
    }

    // MARK: - UI Update

    private func updateUI() {
        let isVoice = mode == .voice

        // Show/hide voice vs QWERTY
        qwertyStack.isHidden = isVoice
        // When in voice mode, show main voice UI elements
        statusLabel.superview?.isHidden = !isVoice
        previewLabel.superview?.isHidden = !isVoice

        // Update mode toggle icon
        modeToggleButton.setImage(
            UIImage(systemName: isVoice ? "keyboard" : "mic.fill"),
            for: .normal
        )
        modeToggleButton.tintColor = isVoice ? .label : .systemRed

        switch state {
        case .idle:
            statusLabel.text = "Tap mic to start"
            micButton.backgroundColor = .systemRed
            micButton.setImage(UIImage(systemName: "mic.fill"), for: .normal)
            durationLabel.isHidden = true
            insertButton.isHidden = true
            clearButton.isHidden = true
        case .recording:
            statusLabel.text = "Recording..."
            micButton.backgroundColor = .systemGray
            micButton.setImage(UIImage(systemName: "stop.fill"), for: .normal)
            durationLabel.isHidden = false
        case .transcribing:
            statusLabel.text = "Transcribing..."
            micButton.backgroundColor = .systemBlue
            micButton.setImage(UIImage(systemName: "waveform"), for: .normal)
        case .completed(let text):
            statusLabel.text = "Done ✓"
            previewLabel.text = text
            insertButton.isHidden = false
            clearButton.isHidden = false
            micButton.backgroundColor = .systemRed
            micButton.setImage(UIImage(systemName: "mic.fill"), for: .normal)
            durationLabel.isHidden = true
        case .error(let msg):
            statusLabel.text = "⚠ \(msg)"
            micButton.backgroundColor = .systemRed
            micButton.setImage(UIImage(systemName: "mic.fill"), for: .normal)
        case .noModel:
            statusLabel.text = "No model — open KrakWhisper app to download"
            micButton.isEnabled = false
        }
    }

    // MARK: - Actions

    @objc private func micTapped() { onMicTap?() }
    @objc private func insertTapped() { onInsert?() }
    @objc private func clearTapped() { onClear?() }
    @objc private func globeTapped() { onGlobe?() }
    @objc private func modeToggleTapped() { onToggleMode?() }
    @objc private func backspaceTapped() { onBackspace?() }
    @objc private func spaceTapped() { onSpace?() }
    @objc private func returnTapped() { onReturn?() }

    @objc private func keyTapped(_ sender: UIButton) {
        guard let title = sender.title(for: .normal) else { return }
        onTypeChar?(title)
    }
}
#endif
