import AVFoundation
import Combine

// MARK: - AudioCaptureError

/// Errors that can occur during audio capture operations.
enum AudioCaptureError: Error, LocalizedError {
    case microphonePermissionDenied
    case microphonePermissionUndetermined
    case audioEngineSetupFailed(underlying: Error)
    case audioSessionConfigurationFailed(underlying: Error)
    case alreadyRecording
    case notRecording

    var errorDescription: String? {
        switch self {
        case .microphonePermissionDenied:
            return "Microphone access was denied. Enable it in Settings > Privacy > Microphone."
        case .microphonePermissionUndetermined:
            return "Microphone permission has not been requested yet."
        case .audioEngineSetupFailed(let error):
            return "Audio engine setup failed: \(error.localizedDescription)"
        case .audioSessionConfigurationFailed(let error):
            return "Audio session configuration failed: \(error.localizedDescription)"
        case .alreadyRecording:
            return "Recording is already in progress."
        case .notRecording:
            return "No recording is currently in progress."
        }
    }
}

// MARK: - AudioCaptureState

/// Represents the current state of audio capture.
enum AudioCaptureState: Equatable {
    case idle
    case recording
    case interrupted
    case error(String)

    static func == (lhs: AudioCaptureState, rhs: AudioCaptureState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle), (.recording, .recording), (.interrupted, .interrupted):
            return true
        case (.error(let a), .error(let b)):
            return a == b
        default:
            return false
        }
    }
}

// MARK: - AudioLevelMeter

/// Provides RMS audio level values for UI waveform display.
struct AudioLevelSample {
    /// RMS level in range [0.0, 1.0]
    let level: Float
    /// Peak level in range [0.0, 1.0]
    let peak: Float
    /// Timestamp relative to recording start
    let timestamp: TimeInterval
}

// MARK: - AudioCaptureService

/// Real-time microphone capture service using AVAudioEngine.
///
/// Captures audio in 16kHz mono Float32 PCM format — the exact format
/// required by whisper.cpp for inference. Provides audio level metering
/// for UI waveform visualization and handles audio session interruptions.
///
/// Usage:
/// ```swift
/// let service = AudioCaptureService()
/// let granted = await service.requestPermission()
/// guard granted else { return }
/// try service.startRecording()
/// // ... recording ...
/// let buffer = service.stopRecording()
/// ```
@MainActor
final class AudioCaptureService: ObservableObject {

    // MARK: - Published Properties

    /// Current state of the capture service.
    @Published private(set) var state: AudioCaptureState = .idle

    /// Latest audio level sample for waveform UI.
    @Published private(set) var currentLevel: AudioLevelSample = AudioLevelSample(level: 0, peak: 0, timestamp: 0)

    /// Duration of the current recording in seconds.
    @Published private(set) var recordingDuration: TimeInterval = 0

    // MARK: - Audio Engine

    private let audioEngine = AVAudioEngine()

    /// The target format for whisper.cpp: 16kHz mono Float32 PCM.
    private let whisperFormat: AVAudioFormat = {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ) else {
            fatalError("Failed to create 16kHz mono Float32 audio format")
        }
        return format
    }()

    // MARK: - Recording Buffer

    /// Accumulated PCM samples during recording.
    private var recordingBuffer: [Float] = []
    private let bufferLock = NSLock()

    /// Timer for tracking recording duration.
    private var durationTimer: Timer?
    private var recordingStartTime: Date?
    private var accumulatedDuration: TimeInterval = 0

    // MARK: - Audio Level Metering

    /// Callback for audio level updates. Called on a background queue.
    var onAudioLevel: ((AudioLevelSample) -> Void)?

    // MARK: - Interruption Handling

    private var interruptionObserver: NSObjectProtocol?
    private var routeChangeObserver: NSObjectProtocol?
    private var wasRecordingBeforeInterruption = false

    // MARK: - Initialization

    init() {
        setupInterruptionHandling()
    }

    deinit {
        if let observer = interruptionObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = routeChangeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Permission

    /// Request microphone permission from the user.
    /// - Returns: `true` if permission was granted, `false` otherwise.
    @discardableResult
    func requestPermission() async -> Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)

        switch status {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    /// Check current microphone permission status.
    var permissionStatus: AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }

    // MARK: - Recording Control

    /// Start capturing audio from the microphone.
    ///
    /// Configures the audio session, sets up AVAudioEngine with format
    /// conversion to 16kHz mono Float32, and begins capturing PCM samples.
    ///
    /// - Throws: `AudioCaptureError` if permission is denied, engine setup
    ///   fails, or recording is already in progress.
    func startRecording() throws {
        guard state != .recording, state != .interrupted else {
            throw AudioCaptureError.alreadyRecording
        }

        guard permissionStatus == .authorized else {
            throw AudioCaptureError.microphonePermissionDenied
        }

        // Configure audio session for recording
        do {
            try configureAudioSession()
        } catch {
            throw AudioCaptureError.audioSessionConfigurationFailed(underlying: error)
        }

        // Reset buffer
        bufferLock.lock()
        recordingBuffer.removeAll()
        bufferLock.unlock()

        // Set up the audio tap
        do {
            try setupAudioTap()
        } catch {
            throw AudioCaptureError.audioEngineSetupFailed(underlying: error)
        }

        // Start the engine
        do {
            try audioEngine.start()
        } catch {
            audioEngine.inputNode.removeTap(onBus: 0)
            throw AudioCaptureError.audioEngineSetupFailed(underlying: error)
        }

        // Track timing
        recordingStartTime = Date()
        startDurationTimer()

        state = .recording
    }

    /// Stop capturing audio and return the recorded PCM buffer.
    ///
    /// - Returns: Array of Float32 PCM samples at 16kHz mono, suitable
    ///   for direct use with whisper.cpp inference.
    @discardableResult
    func stopRecording() -> [Float] {
        guard state == .recording || state == .interrupted else {
            return []
        }

        // Stop engine and remove tap
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)

        // Stop duration tracking
        stopDurationTimer()

        // Deactivate audio session
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif

        // Grab the buffer
        bufferLock.lock()
        let samples = recordingBuffer
        recordingBuffer.removeAll()
        bufferLock.unlock()

        state = .idle
        recordingDuration = 0

        return samples
    }

    /// Cancel recording without returning data.
    func cancelRecording() {
        _ = stopRecording()
    }

    /// Whether the service is currently recording.
    var isRecording: Bool {
        state == .recording
    }

    // MARK: - Audio Session Configuration

    private func configureAudioSession() throws {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: [])
        try session.setPreferredSampleRate(16_000)
        try session.setActive(true, options: [])
        #endif
        // macOS doesn't require explicit audio session configuration
    }

    // MARK: - Audio Tap Setup

    private func setupAudioTap() throws {
        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        // Validate input format
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw AudioCaptureError.audioEngineSetupFailed(
                underlying: NSError(
                    domain: "AudioCaptureService",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Invalid input format: \(inputFormat)"]
                )
            )
        }

        // Create a converter from device format to whisper format (16kHz mono Float32)
        guard let converter = AVAudioConverter(from: inputFormat, to: whisperFormat) else {
            throw AudioCaptureError.audioEngineSetupFailed(
                underlying: NSError(
                    domain: "AudioCaptureService",
                    code: -2,
                    userInfo: [NSLocalizedDescriptionKey: "Cannot create audio converter from \(inputFormat) to \(whisperFormat)"]
                )
            )
        }

        // Install tap on input node
        // Buffer size of 1024 frames gives ~64ms at 16kHz — good for real-time metering
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, time in
            self?.processAudioBuffer(buffer, converter: converter)
        }
    }

    // MARK: - Audio Processing

    private func processAudioBuffer(_ buffer: AVAudioPCMBuffer, converter: AVAudioConverter) {
        // Calculate the output frame capacity based on sample rate ratio
        let ratio = whisperFormat.sampleRate / buffer.format.sampleRate
        let outputFrameCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1

        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: whisperFormat,
            frameCapacity: outputFrameCapacity
        ) else { return }

        // Convert to 16kHz mono Float32
        var conversionError: NSError?
        var inputConsumed = false

        converter.convert(to: outputBuffer, error: &conversionError) { _, outStatus in
            if inputConsumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            inputConsumed = true
            outStatus.pointee = .haveData
            return buffer
        }

        if conversionError != nil { return }

        guard let channelData = outputBuffer.floatChannelData else { return }
        let frameLength = Int(outputBuffer.frameLength)
        guard frameLength > 0 else { return }

        let samples = Array(UnsafeBufferPointer(start: channelData[0], count: frameLength))

        // Append to recording buffer
        bufferLock.lock()
        recordingBuffer.append(contentsOf: samples)
        bufferLock.unlock()

        // Calculate audio levels for metering
        let level = calculateRMSLevel(samples)
        let peak = calculatePeakLevel(samples)
        let timestamp = recordingStartTime.map { Date().timeIntervalSince($0) } ?? 0

        let sample = AudioLevelSample(level: level, peak: peak, timestamp: timestamp)

        // Update published property on main thread
        Task { @MainActor [weak self] in
            self?.currentLevel = sample
        }

        // Fire callback
        onAudioLevel?(sample)
    }

    // MARK: - Audio Level Calculation

    /// Calculate RMS (Root Mean Square) level from samples, normalized to [0, 1].
    private func calculateRMSLevel(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }

        let sumOfSquares = samples.reduce(Float(0)) { $0 + $1 * $1 }
        let rms = sqrt(sumOfSquares / Float(samples.count))

        // Convert to a more perceptually useful range
        // RMS of speech typically ranges from ~0.001 to ~0.3
        // Map to [0, 1] with some headroom
        let normalized = min(rms / 0.2, 1.0)
        return normalized
    }

    /// Calculate peak level from samples, normalized to [0, 1].
    private func calculatePeakLevel(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        let peak = samples.map { abs($0) }.max() ?? 0
        return min(peak / 0.5, 1.0)
    }

    // MARK: - Duration Timer

    private func startDurationTimer() {
        durationTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let start = self.recordingStartTime else { return }
                self.recordingDuration = self.accumulatedDuration + Date().timeIntervalSince(start)
            }
        }
    }

    private func stopDurationTimer(resetStartTime: Bool = true) {
        durationTimer?.invalidate()
        durationTimer = nil
        if resetStartTime {
            recordingStartTime = nil
            accumulatedDuration = 0
        }
    }

    // MARK: - Interruption Handling

    private func setupInterruptionHandling() {
        #if os(iOS)
        // Handle audio session interruptions (phone calls, alarms, etc.)
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            self?.handleInterruption(notification)
        }

        // Handle route changes (headphones unplugged, etc.)
        routeChangeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            self?.handleRouteChange(notification)
        }
        #endif
    }

    private func handleInterruption(_ notification: Notification) {
        #if os(iOS)
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else {
            return
        }

        Task { @MainActor in
            switch type {
            case .began:
                // Interruption started (e.g., phone call)
                if self.state == .recording {
                    self.wasRecordingBeforeInterruption = true
                    self.audioEngine.pause()
                    self.accumulatedDuration = self.recordingDuration
                    self.stopDurationTimer(resetStartTime: false)
                    self.state = .interrupted
                }

            case .ended:
                // Interruption ended
                guard self.wasRecordingBeforeInterruption else { return }
                self.wasRecordingBeforeInterruption = false

                let options = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
                let shouldResume = AVAudioSession.InterruptionOptions(rawValue: options)
                    .contains(.shouldResume)

                if shouldResume {
                    do {
                        try AVAudioSession.sharedInstance().setActive(true)
                        try self.audioEngine.start()
                        self.recordingStartTime = Date()
                        self.startDurationTimer()
                        self.state = .recording
                    } catch {
                        self.state = .error("Failed to resume after interruption: \(error.localizedDescription)")
                    }
                } else {
                    // System says don't resume — stop gracefully
                    _ = self.stopRecording()
                }

            @unknown default:
                break
            }
        }
        #endif
    }

    private func handleRouteChange(_ notification: Notification) {
        #if os(iOS)
        guard let userInfo = notification.userInfo,
              let reasonValue = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else {
            return
        }

        // If the old device was removed (e.g., headphones unplugged),
        // the system may have changed the input device. The engine should
        // handle this automatically, but log it for debugging.
        if reason == .oldDeviceUnavailable {
            // AVAudioEngine usually handles route changes gracefully.
            // If issues arise, we could restart the tap here.
        }
        #endif
    }
}
