#if os(iOS)
import AVFoundation
import SwiftWhisper
import CryptoKit
import UIKit

/// Background recording service that listens for keyboard extension requests.
/// When the keyboard sends a Darwin notification, this service starts recording
/// in the background (using background audio mode), transcribes with Whisper,
/// writes the result to the App Group, and notifies the keyboard via Darwin notification.
///
/// The user sees the Dynamic Island / Live Activity indicator while recording.
final class BackgroundRecordingService: NSObject, ObservableObject {
    static let shared = BackgroundRecordingService()
    
    @Published var isRecording = false
    @Published var isTranscribing = false
    @Published var duration: TimeInterval = 0
    
    private let appGroupID = "group.com.krakwhisper.shared"
    private let resultFileName = "keyboard-result.json"
    private let whisperAPIURL = "http://157.173.203.33:8178/inference"
    
    private var audioRecorder: AVAudioRecorder?
    private var recordingURL: URL?
    private var timer: Timer?
    private var darwinObserverRaw: UnsafeMutableRawPointer?
    
    private var sharedURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)
    }
    
    override init() {
        super.init()
    }
    
    // MARK: - Start Listening for Keyboard Requests
    
    func startListening() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        
        // Listen for "start recording" from keyboard
        CFNotificationCenterAddObserver(
            center,
            Unmanaged.passUnretained(self).toOpaque(),
            { (_, observer, _, _, _) in
                guard let observer = observer else { return }
                let service = Unmanaged<BackgroundRecordingService>
                    .fromOpaque(observer)
                    .takeUnretainedValue()
                DispatchQueue.main.async {
                    service.handleKeyboardStartRequest()
                }
            },
            "com.krakwhisper.startRecording" as CFString,
            nil,
            .deliverImmediately
        )
        
        // Listen for "stop recording" from keyboard
        CFNotificationCenterAddObserver(
            center,
            Unmanaged.passUnretained(self).toOpaque(),
            { (_, observer, _, _, _) in
                guard let observer = observer else { return }
                let service = Unmanaged<BackgroundRecordingService>
                    .fromOpaque(observer)
                    .takeUnretainedValue()
                DispatchQueue.main.async {
                    service.stopAndTranscribe()
                }
            },
            "com.krakwhisper.stopRecording" as CFString,
            nil,
            .deliverImmediately
        )
    }
    
    func stopListening() {
        CFNotificationCenterRemoveEveryObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque()
        )
    }
    
    // MARK: - Handle Keyboard Request
    
    private func handleKeyboardStartRequest() {
        if isRecording {
            // Already recording — treat as stop
            stopAndTranscribe()
            return
        }
        startRecording()
    }
    
    // MARK: - Recording
    
    func startRecording() {
        let session = AVAudioSession.sharedInstance()
        do {
            // Use playAndRecord to keep background audio session alive
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
            try session.setActive(true)
        } catch {
            writeResult(text: "", durationMs: 0, error: "Mic error: \(error.localizedDescription)")
            return
        }
        
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("kw-bg-voice-\(Int(Date().timeIntervalSince1970)).wav")
        recordingURL = url
        
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 16000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        
        do {
            let recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder.record()
            audioRecorder = recorder
            isRecording = true
            duration = 0
            
            // Start Live Activity
            Task { @MainActor in
                RecordingActivityManager.shared.startRecordingActivity(source: "keyboard")
            }
            
            // Notify keyboard that recording has started
            CFNotificationCenterPostNotification(
                CFNotificationCenterGetDarwinNotifyCenter(),
                CFNotificationName("com.krakwhisper.recordingStarted" as CFString),
                nil, nil, true
            )
            
            // Duration timer
            timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                guard let self, self.isRecording else { return }
                self.duration += 0.5
                
                Task { @MainActor in
                    RecordingActivityManager.shared.updateDuration(self.duration)
                }
                
                // Auto-stop after 60 seconds
                if self.duration >= 60 {
                    self.stopAndTranscribe()
                }
            }
        } catch {
            writeResult(text: "", durationMs: 0, error: "Record error: \(error.localizedDescription)")
        }
    }
    
    func stopAndTranscribe() {
        guard isRecording else { return }
        
        audioRecorder?.stop()
        audioRecorder = nil
        timer?.invalidate()
        timer = nil
        isRecording = false
        isTranscribing = true
        
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        
        Task { @MainActor in
            RecordingActivityManager.shared.updateTranscribing()
        }
        
        guard duration > 0.3, let url = recordingURL, let wavData = try? Data(contentsOf: url) else {
            isTranscribing = false
            writeResult(text: "", durationMs: 0, error: "Too short")
            Task { @MainActor in
                RecordingActivityManager.shared.updateError("Too short")
            }
            return
        }
        
        // Transcribe
        Task {
            var result = await transcribeOnDevice(wavData: wavData)
            if result == nil { result = await transcribeViaAPI(wavData: wavData) }
            
            await MainActor.run {
                isTranscribing = false
                
                if let result, !result.text.isEmpty {
                    writeResult(text: result.text, durationMs: result.durationMs, error: nil)
                    RecordingActivityManager.shared.updateDone(text: result.text)
                } else {
                    writeResult(text: "", durationMs: 0, error: result == nil ? "Transcription failed" : "No speech detected")
                    RecordingActivityManager.shared.updateError(result == nil ? "Failed" : "No speech")
                }
            }
            
            // Clean up temp file
            try? FileManager.default.removeItem(at: url)
        }
    }
    
    // MARK: - On-device Whisper
    
    private func transcribeOnDevice(wavData: Data) async -> BGTranscriptionResult? {
        let modelSizes = ["small", "base", "tiny"]
        let searchDirs: [URL] = [sharedURL, FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first].compactMap { $0 }
        
        for dir in searchDirs {
            for size in modelSizes {
                let modelURL = dir.appendingPathComponent("ggml-\(size).en.bin")
                guard FileManager.default.fileExists(atPath: modelURL.path) else { continue }
                
                do {
                    let start = Date()
                    let whisper = try Whisper(fromFileURL: modelURL)
                    let samples = decodeWAV(data: wavData)
                    guard !samples.isEmpty else { return nil }
                    let segments = try await whisper.transcribe(audioFrames: samples)
                    let text = segments.map { $0.text }.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
                    // Strip >> prefix from whisper.cpp output
                    let cleaned = text.hasPrefix(">>") ? String(text.dropFirst(2)).trimmingCharacters(in: .whitespaces) : text
                    let ms = Int(Date().timeIntervalSince(start) * 1000)
                    return BGTranscriptionResult(text: cleaned, durationMs: ms)
                } catch {
                    continue
                }
            }
        }
        return nil
    }
    
    // MARK: - API Fallback
    
    private func transcribeViaAPI(wavData: Data) async -> BGTranscriptionResult? {
        guard let url = URL(string: whisperAPIURL) else { return nil }
        
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
        
        let start = Date()
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let text = json["text"] as? String else { return nil }
            let ms = Int(Date().timeIntervalSince(start) * 1000)
            return BGTranscriptionResult(text: text.trimmingCharacters(in: .whitespacesAndNewlines), durationMs: ms)
        } catch {
            return nil
        }
    }
    
    // MARK: - Write Result to App Group
    
    private func writeResult(text: String, durationMs: Int, error: String?) {
        guard let url = sharedURL?.appendingPathComponent(resultFileName) else { return }
        var result: [String: Any] = [
            "text": text,
            "timestamp": Date().timeIntervalSince1970,
            "durationMs": durationMs,
            "consumed": false
        ]
        if let error { result["error"] = error }
        
        guard let jsonData = try? JSONSerialization.data(withJSONObject: result) else { return }
        
        if let encrypted = try? AppGroupCrypto.encrypt(jsonData) {
            try? encrypted.write(to: url)
        } else {
            try? jsonData.write(to: url)
        }
        
        // Notify keyboard extension
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName("com.krakwhisper.transcriptionReady" as CFString),
            nil, nil, true
        )
    }
    
    // MARK: - Helpers
    
    private func decodeWAV(data: Data) -> [Float] {
        guard data.count > 44 else { return [] }
        let raw = data.subdata(in: 44..<data.count)
        var samples: [Float] = []
        samples.reserveCapacity(raw.count / 2)
        for i in stride(from: 0, to: raw.count - 1, by: 2) {
            let v = Int16(bitPattern: UInt16(raw[i]) | (UInt16(raw[i + 1]) << 8))
            samples.append(Float(v) / 32768.0)
        }
        return samples
    }
}

private struct BGTranscriptionResult {
    let text: String
    let durationMs: Int
}
#endif
