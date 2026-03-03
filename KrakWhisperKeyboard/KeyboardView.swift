#if os(iOS)
import SwiftUI

// MARK: - Keyboard State

/// Represents the current state of the keyboard extension.
enum KeyboardState: Equatable {
    case idle
    case recording
    case transcribing
    case completed(String)
    case error(String)
    case noModel
}

/// Which keyboard mode is active.
enum KeyboardMode: Equatable {
    case voice   // Whisper dictation mode
    case text    // Standard QWERTY typing mode
}

// MARK: - KeyboardView

/// SwiftUI layout for the KrakWhisper custom keyboard.
///
/// Supports two modes:
/// - **Voice mode:** Whisper-powered dictation with mic button and waveform
/// - **Text mode:** Full QWERTY keyboard for typing and editing
///
/// Toggle between modes with the mic/keyboard button in the bottom bar.
struct KeyboardView: View {
    let state: KeyboardState
    let transcribedText: String
    let audioLevels: [Float]
    let recordingDuration: TimeInterval
    let modelName: String
    let mode: KeyboardMode

    // Actions
    let onMicTap: () -> Void
    let onInsert: () -> Void
    let onBackspace: () -> Void
    let onSpace: () -> Void
    let onReturn: () -> Void
    let onGlobe: () -> Void
    let onSettings: () -> Void
    let onClear: () -> Void
    let onTypeChar: (String) -> Void
    let onToggleMode: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            switch mode {
            case .voice:
                voiceLayout
            case .text:
                qwertyLayout
            }
        }
        .background(Color(uiColor: .systemBackground).opacity(0.95))
    }

    // MARK: - Voice Layout (original)

    private var voiceLayout: some View {
        VStack(spacing: 0) {
            // Top: Status + Preview
            topSection
                .frame(height: 84)
                .padding(.horizontal, 8)
                .padding(.top, 4)

            // Middle: Waveform or Instructions
            middleSection
                .frame(height: 44)
                .padding(.horizontal, 12)

            // Bottom: Controls
            voiceBottomControls
                .frame(height: 64)
                .padding(.horizontal, 8)
                .padding(.bottom, 4)
        }
    }

    // MARK: - QWERTY Layout

    private var qwertyLayout: some View {
        VStack(spacing: 0) {
            // Transcription preview if we have text
            if !transcribedText.isEmpty {
                HStack {
                    Text(transcribedText)
                        .font(.system(size: 13))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer()
                    Button(action: onInsert) {
                        Text("Insert")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(.blue))
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color(uiColor: .secondarySystemBackground))
            }

            // QWERTY keys
            qwertyKeys
                .padding(.horizontal, 3)
                .padding(.top, 6)

            // Bottom row: globe, mic toggle, space, return
            qwertyBottomRow
                .padding(.horizontal, 4)
                .padding(.bottom, 4)
                .padding(.top, 4)
        }
    }

    @State private var isShifted = false
    @State private var isCapsLock = false

    private var qwertyKeys: some View {
        let rows: [[String]] = [
            ["q","w","e","r","t","y","u","i","o","p"],
            ["a","s","d","f","g","h","j","k","l"],
            ["z","x","c","v","b","n","m"]
        ]

        return VStack(spacing: 6) {
            ForEach(0..<rows.count, id: \.self) { rowIndex in
                HStack(spacing: 4) {
                    // Shift key on last row
                    if rowIndex == 2 {
                        Button(action: {
                            isShifted.toggle()
                        }) {
                            Image(systemName: isShifted ? "shift.fill" : "shift")
                                .font(.system(size: 16, weight: .medium))
                                .foregroundStyle(.primary)
                                .frame(width: 36, height: 42)
                                .background(
                                    RoundedRectangle(cornerRadius: 5)
                                        .fill(isShifted
                                              ? Color(uiColor: .systemBackground)
                                              : Color(uiColor: .secondarySystemBackground))
                                )
                        }
                    }

                    ForEach(rows[rowIndex], id: \.self) { key in
                        Button(action: {
                            let char = (isShifted || isCapsLock) ? key.uppercased() : key
                            onTypeChar(char)
                            if isShifted && !isCapsLock {
                                isShifted = false
                            }
                        }) {
                            Text((isShifted || isCapsLock) ? key.uppercased() : key)
                                .font(.system(size: 22, weight: .regular))
                                .foregroundStyle(.primary)
                                .frame(maxWidth: .infinity, minHeight: 42)
                                .background(
                                    RoundedRectangle(cornerRadius: 5)
                                        .fill(Color(uiColor: .systemBackground))
                                        .shadow(color: .black.opacity(0.15), radius: 0.5, y: 1)
                                )
                        }
                    }

                    // Backspace on last row
                    if rowIndex == 2 {
                        Button(action: onBackspace) {
                            Image(systemName: "delete.left")
                                .font(.system(size: 16, weight: .medium))
                                .foregroundStyle(.primary)
                                .frame(width: 36, height: 42)
                                .background(
                                    RoundedRectangle(cornerRadius: 5)
                                        .fill(Color(uiColor: .secondarySystemBackground))
                                )
                        }
                    }
                }
            }
        }
    }

    private var qwertyBottomRow: some View {
        HStack(spacing: 4) {
            // Globe
            Button(action: onGlobe) {
                Image(systemName: "globe")
                    .font(.system(size: 16))
                    .foregroundStyle(.primary)
                    .frame(width: 40, height: 42)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(Color(uiColor: .secondarySystemBackground))
                    )
            }

            // Mic toggle (switch to voice mode)
            Button(action: onToggleMode) {
                Image(systemName: "mic.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(.red)
                    .frame(width: 40, height: 42)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(Color(uiColor: .secondarySystemBackground))
                    )
            }

            // Common punctuation
            Button(action: { onTypeChar(",") }) {
                Text(",")
                    .font(.system(size: 22))
                    .foregroundStyle(.primary)
                    .frame(width: 32, height: 42)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(Color(uiColor: .secondarySystemBackground))
                    )
            }

            // Space bar
            Button(action: onSpace) {
                Text("space")
                    .font(.system(size: 16))
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, minHeight: 42)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(Color(uiColor: .systemBackground))
                            .shadow(color: .black.opacity(0.15), radius: 0.5, y: 1)
                    )
            }

            // Period
            Button(action: { onTypeChar(".") }) {
                Text(".")
                    .font(.system(size: 22))
                    .foregroundStyle(.primary)
                    .frame(width: 32, height: 42)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(Color(uiColor: .secondarySystemBackground))
                    )
            }

            // Return
            Button(action: onReturn) {
                Image(systemName: "return")
                    .font(.system(size: 16))
                    .foregroundStyle(.primary)
                    .frame(width: 64, height: 42)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(Color(uiColor: .secondarySystemBackground))
                    )
            }
        }
    }

    // MARK: - Voice Mode Components

    private var topSection: some View {
        VStack(spacing: 4) {
            HStack {
                statusIndicator
                Spacer()
                if state == .recording {
                    Text(formattedDuration)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(.red)
                }
                modelBadge
            }
            .frame(height: 20)

            textPreviewArea
        }
    }

    private var statusIndicator: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(statusColor)
                .frame(width: 6, height: 6)
            Text(statusText)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }

    private var statusColor: Color {
        switch state {
        case .idle: return .green
        case .recording: return .red
        case .transcribing: return .blue
        case .completed: return .green
        case .error: return .orange
        case .noModel: return .gray
        }
    }

    private var statusText: String {
        switch state {
        case .idle: return "Ready"
        case .recording: return "Recording…"
        case .transcribing: return "Transcribing…"
        case .completed: return "Done — tap Insert"
        case .error(let msg): return msg
        case .noModel: return "No model — open app"
        }
    }

    private var modelBadge: some View {
        Text(modelName)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule().fill(Color(uiColor: .tertiarySystemFill))
            )
    }

    private var textPreviewArea: some View {
        Group {
            if transcribedText.isEmpty {
                switch state {
                case .noModel:
                    Text("Open KrakWhisper app to download a model")
                        .font(.system(size: 13))
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                case .error(let msg):
                    Text(msg)
                        .font(.system(size: 13))
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                default:
                    Text("Tap mic to start dictating")
                        .font(.system(size: 13))
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                }
            } else {
                ScrollView {
                    Text(transcribedText)
                        .font(.system(size: 14))
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(6)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(uiColor: .secondarySystemBackground))
        )
    }

    private var middleSection: some View {
        Group {
            switch state {
            case .recording:
                AudioLevelView(levels: audioLevels, isRecording: true)
            case .transcribing:
                TranscribingIndicator()
            default:
                AudioLevelView(levels: [], isRecording: false)
            }
        }
    }

    // MARK: - Voice Bottom Controls

    private var voiceBottomControls: some View {
        HStack(spacing: 6) {
            // Globe button
            keyboardButton(systemImage: "globe") {
                onGlobe()
            }
            .frame(width: 44)

            // Toggle to QWERTY mode
            keyboardButton(systemImage: "keyboard") {
                onToggleMode()
            }
            .frame(width: 44)

            // Backspace
            keyboardButton(systemImage: "delete.left") {
                onBackspace()
            }
            .frame(width: 48)

            Spacer()

            // Mic button
            micButton
                .frame(width: 60, height: 60)

            Spacer()

            // Clear transcription
            if !transcribedText.isEmpty {
                keyboardButton(systemImage: "xmark.circle") {
                    onClear()
                }
                .frame(width: 44)
            }

            // Space
            Button(action: onSpace) {
                Text("space")
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color(uiColor: .secondarySystemBackground))
                    )
            }
            .frame(width: 60, height: 44)

            // Insert / Return
            insertOrReturnButton
                .frame(width: 64, height: 44)
        }
        .frame(maxHeight: .infinity)
    }

    private var micButton: some View {
        Button(action: onMicTap) {
            ZStack {
                if state == .recording {
                    Circle()
                        .stroke(Color.red.opacity(0.3), lineWidth: 2)
                        .scaleEffect(1.3)
                }

                Circle()
                    .fill(micButtonColor)
                    .shadow(color: micButtonColor.opacity(0.4), radius: 4, y: 2)

                Image(systemName: micButtonIcon)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white)
            }
        }
        .disabled(state == .transcribing || state == .noModel)
        .animation(.easeInOut(duration: 0.2), value: state)
    }

    private var micButtonColor: Color {
        switch state {
        case .recording: return .red
        case .transcribing: return .blue.opacity(0.6)
        case .noModel: return .gray.opacity(0.4)
        default: return Color(red: 0.9, green: 0.2, blue: 0.2)
        }
    }

    private var micButtonIcon: String {
        switch state {
        case .recording: return "stop.fill"
        case .transcribing: return "waveform"
        default: return "mic.fill"
        }
    }

    private var insertOrReturnButton: some View {
        Button(action: {
            if !transcribedText.isEmpty {
                onInsert()
            } else {
                onReturn()
            }
        }) {
            Text(transcribedText.isEmpty ? "return" : "Insert")
                .font(.system(size: 14, weight: transcribedText.isEmpty ? .regular : .semibold))
                .foregroundStyle(transcribedText.isEmpty ? Color.primary : Color.white)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(
                            transcribedText.isEmpty
                            ? Color(uiColor: .secondarySystemBackground)
                            : Color.blue
                        )
                )
        }
    }

    private func keyboardButton(systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 18))
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color(uiColor: .tertiarySystemBackground))
                )
        }
        .frame(height: 44)
    }

    private var formattedDuration: String {
        let seconds = Int(recordingDuration)
        let tenths = Int((recordingDuration.truncatingRemainder(dividingBy: 1)) * 10)
        return String(format: "%d.%d", seconds, tenths)
    }
}

#endif // os(iOS)
