#if os(iOS)
import Foundation
import SwiftWhisper

/// Background service in the main app that listens for keyboard transcription requests.
/// Keyboard records audio → writes to App Group → Darwin notification → this service transcribes → writes result back.
class KeyboardTranscriptionService {
    
    static let shared = KeyboardTranscriptionService()
    
    private let appGroupID = "group.com.krakwhisper.shared"
    private let wakeNotification = "com.krakwhisper.wake" as CFString
    private let requestNotification = "com.krakwhisper.transcribe.request" as CFString
    private let responseNotification = "com.krakwhisper.transcribe.response" as CFString
    private let readyNotification = "com.krakwhisper.app.ready" as CFString
    
    private let audioFileName = "keyboard-audio.wav"
    private let requestFileName = "keyboard-request.json"
    private let resultFileName = "keyboard-result.json"
    
    private var isListening = false
    private var whisperInstance: Whisper?
    private var heartbeatTimer: Timer?
    private var pollTimer: Timer?
    
    private var sharedURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)
    }
    
    private init() {}
    
    // MARK: - Start/Stop
    
    func startListening() {
        guard !isListening else { return }
        isListening = true
        
        // Listen for wake and transcription requests
        observeDarwin(wakeNotification) { [weak self] in
            self?.handleWake()
        }
        observeDarwin(requestNotification) { [weak self] in
            self?.handleTranscriptionRequest()
        }
        
        // Poll for requests as backup
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.checkForPendingRequest()
        }
        
        // Write heartbeat so keyboard knows we're alive
        startHeartbeat()
        
        // Announce ready
        postDarwin(readyNotification)
        
        print("[KeyboardTranscriptionService] Started listening")
    }
    
    func stopListening() {
        isListening = false
        heartbeatTimer?.invalidate()
        pollTimer?.invalidate()
        CFNotificationCenterRemoveEveryObserver(CFNotificationCenterGetDarwinNotifyCenter(), nil)
        print("[KeyboardTranscriptionService] Stopped")
    }
    
    // MARK: - Heartbeat
    
    private func startHeartbeat() {
        writeHeartbeat()
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            self?.writeHeartbeat()
        }
    }
    
    private func writeHeartbeat() {
        guard let url = sharedURL?.appendingPathComponent("app-heartbeat.txt") else { return }
        try? String(Date().timeIntervalSince1970).write(to: url, atomically: true, encoding: .utf8)
    }
    
    // MARK: - Handle Wake
    
    private func handleWake() {
        writeHeartbeat()
        postDarwin(readyNotification)
        print("[KeyboardTranscriptionService] Wake received — announced ready")
    }
    
    // MARK: - Handle Transcription
    
    private func handleTranscriptionRequest() {
        checkForPendingRequest()
    }
    
    private func checkForPendingRequest() {
        guard let reqURL = sharedURL?.appendingPathComponent(requestFileName),
              FileManager.default.fileExists(atPath: reqURL.path) else { return }
        
        do {
            let data = try Data(contentsOf: reqURL)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let requestId = json["id"] as? String else { return }
            
            // Remove request to prevent re-processing
            try FileManager.default.removeItem(at: reqURL)
            
            Task { await processTranscription(requestId: requestId) }
        } catch {
            print("[KeyboardTranscriptionService] Failed to read request: \(error)")
        }
    }
    
    private func processTranscription(requestId: String) async {
        let startTime = Date()
        
        guard let audioURL = sharedURL?.appendingPathComponent(audioFileName),
              FileManager.default.fileExists(atPath: audioURL.path) else {
            writeResult(id: requestId, text: "", durationMs: 0, error: "Audio file not found")
            return
        }
        
        // Load model if needed
        if whisperInstance == nil {
            do {
                try await loadWhisperModel()
            } catch {
                writeResult(id: requestId, text: "", durationMs: 0, error: "Model not loaded")
                return
            }
        }
        
        guard let whisper = whisperInstance else {
            writeResult(id: requestId, text: "", durationMs: 0, error: "Whisper not initialized")
            return
        }
        
        do {
            let audioData = try Data(contentsOf: audioURL)
            let samples = decodeWAV(data: audioData)
            guard !samples.isEmpty else {
                writeResult(id: requestId, text: "", durationMs: 0, error: "Empty audio")
                return
            }
            
            let segments = try await whisper.transcribe(audioFrames: samples)
            let text = segments.map { $0.text }.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            let durationMs = Int(Date().timeIntervalSince(startTime) * 1000)
            
            writeResult(id: requestId, text: text, durationMs: durationMs, error: nil)
            try? FileManager.default.removeItem(at: audioURL)
            
            print("[KeyboardTranscriptionService] Transcribed in \(durationMs)ms: \(text.prefix(50))...")
        } catch {
            let durationMs = Int(Date().timeIntervalSince(startTime) * 1000)
            writeResult(id: requestId, text: "", durationMs: durationMs, error: "Transcription failed")
        }
    }
    
    // MARK: - Write Result
    
    private func writeResult(id: String, text: String, durationMs: Int, error: String?) {
        guard let url = sharedURL?.appendingPathComponent(resultFileName) else { return }
        var result: [String: Any] = ["id": id, "text": text, "timestamp": Date().timeIntervalSince1970, "durationMs": durationMs]
        if let error { result["error"] = error }
        
        if let data = try? JSONSerialization.data(withJSONObject: result) {
            try? data.write(to: url)
            postDarwin(responseNotification)
        }
    }
    
    // MARK: - Model Loading
    
    private func loadWhisperModel() async throws {
        let modelSizes = ["small", "base", "tiny"]
        let searchDirs: [URL] = [sharedURL, FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first].compactMap { $0 }
        
        for dir in searchDirs {
            for size in modelSizes {
                let modelURL = dir.appendingPathComponent("ggml-\(size).en.bin")
                if FileManager.default.fileExists(atPath: modelURL.path) {
                    whisperInstance = try Whisper(fromFileURL: modelURL)
                    print("[KeyboardTranscriptionService] Loaded \(size) model from \(dir.lastPathComponent)")
                    return
                }
            }
        }
        
        throw NSError(domain: "KrakWhisper", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "No model found. Download one in the app."
        ])
    }
    
    // MARK: - WAV Decode
    
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
    
    // MARK: - Darwin Helpers
    
    private func postDarwin(_ name: CFString) {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(name), nil, nil, true)
    }
    
    private func observeDarwin(_ name: CFString, callback: @escaping () -> Void) {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let box = CallbackBox(callback: callback)
        let ptr = Unmanaged.passRetained(box).toOpaque()
        CFNotificationCenterAddObserver(center, ptr,
            { _, observer, _, _, _ in
                guard let observer else { return }
                let box = Unmanaged<CallbackBox>.fromOpaque(observer).takeUnretainedValue()
                DispatchQueue.main.async { box.callback() }
            }, name, nil, .deliverImmediately)
    }
}

private class CallbackBox {
    let callback: () -> Void
    init(callback: @escaping () -> Void) { self.callback = callback }
}
#endif
