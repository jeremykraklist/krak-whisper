#if os(iOS)
import SwiftUI
import AVFoundation
import SwiftWhisper
import CryptoKit

/// Full-screen recording view styled like Whisper Flow.
/// Minimal UI: cancel/confirm buttons, audio level dots, status text.
/// Records → transcribes → writes to App Group → auto-returns.
struct KeyboardRecordView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var recorder = KeyboardRecordViewModel()
    
    var body: some View {
        ZStack {
            // Dark blurred background
            Color.black.opacity(0.92).ignoresSafeArea()
            
            VStack(spacing: 0) {
                // Top bar: Cancel / Confirm
                HStack {
                    // Cancel button
                    Button(action: { cancelRecording() }) {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(width: 44, height: 44)
                            .background(Color.white.opacity(0.15))
                            .clipShape(Circle())
                    }
                    
                    Spacer()
                    
                    // Confirm/Stop button
                    if recorder.isRecording {
                        Button(action: { recorder.stopAndTranscribe() }) {
                            Image(systemName: "checkmark")
                                .font(.system(size: 16, weight: .bold))
                                .foregroundColor(.black)
                                .frame(width: 44, height: 44)
                                .background(Color.white)
                                .clipShape(Circle())
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                
                Spacer()
                
                // Center: Audio level dots + status
                VStack(spacing: 24) {
                    if recorder.isRecording {
                        // Audio level dots (like Whisper Flow)
                        AudioLevelDotsView(level: recorder.audioLevel)
                            .frame(height: 16)
                            .padding(.horizontal, 60)
                    } else if recorder.isTranscribing {
                        // Transcribing spinner
                        ProgressView()
                            .tint(.white)
                            .scaleEffect(1.2)
                    } else if recorder.isDone {
                        // Checkmark
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 48))
                            .foregroundColor(.green)
                    }
                    
                    // Status text
                    Text(recorder.statusText)
                        .font(.system(size: 17, weight: .medium))
                        .foregroundColor(.white)
                    
                    // Subtitle
                    if recorder.isRecording {
                        Text("iPhone Microphone")
                            .font(.system(size: 14))
                            .foregroundColor(.white.opacity(0.5))
                    }
                    
                    // Transcribed text preview
                    if recorder.isDone && !recorder.transcribedText.isEmpty {
                        Text(recorder.transcribedText)
                            .font(.system(size: 15))
                            .foregroundColor(.white.opacity(0.7))
                            .multilineTextAlignment(.center)
                            .lineLimit(3)
                            .padding(.horizontal, 30)
                    }
                    
                    // Duration
                    if recorder.isRecording {
                        Text(String(format: "%d:%02d", Int(recorder.duration) / 60, Int(recorder.duration) % 60))
                            .font(.system(size: 14, design: .monospaced))
                            .foregroundColor(.white.opacity(0.4))
                    }
                }
                
                Spacer()
                Spacer()
            }
        }
        .onAppear {
            recorder.startRecording()
        }
        .onDisappear {
            recorder.cleanup()
        }
        .onChange(of: recorder.isDone) { _, done in
            if done {
                // Auto-dismiss and return to previous app
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    dismiss()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        Self.suspendApp()
                    }
                }
            }
        }
    }
    
    private func cancelRecording() {
        recorder.cleanup()
        dismiss()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            Self.suspendApp()
        }
    }
    
    private static func suspendApp() {
        let selector = NSSelectorFromString("suspend")
        UIApplication.shared.perform(selector)
    }
}

// MARK: - Audio Level Dots

/// Animated dots that respond to audio input level (like Whisper Flow).
struct AudioLevelDotsView: View {
    let level: Float
    private let dotCount = 9
    
    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<dotCount, id: \.self) { index in
                Circle()
                    .fill(Color.white.opacity(dotOpacity(for: index)))
                    .frame(width: dotSize(for: index), height: dotSize(for: index))
                    .animation(.easeInOut(duration: 0.15), value: level)
            }
        }
    }
    
    private func dotSize(for index: Int) -> CGFloat {
        let center = dotCount / 2
        let distance = abs(index - center)
        let baseSize: CGFloat = 8
        let boost = CGFloat(level) * 4 * (1.0 - CGFloat(distance) / CGFloat(center + 1))
        return baseSize + max(0, boost)
    }
    
    private func dotOpacity(for index: Int) -> Double {
        let center = dotCount / 2
        let distance = abs(index - center)
        let base = 0.4
        let boost = Double(level) * 0.6 * (1.0 - Double(distance) / Double(center + 1))
        return base + boost
    }
}

// MARK: - ViewModel

class KeyboardRecordViewModel: ObservableObject {
    @Published var isRecording = false
    @Published var isTranscribing = false
    @Published var isDone = false
    @Published var duration: TimeInterval = 0
    @Published var statusText = "Preparing..."
    @Published var statusColor: Color = .blue
    @Published var transcribedText = ""
    @Published var audioLevel: Float = 0
    
    private let appGroupID = "group.com.krakwhisper.shared"
    private let resultFileName = "keyboard-result.json"
    private let whisperAPIURL = "http://157.173.203.33:8178/inference"
    
    private var audioRecorder: AVAudioRecorder?
    private var recordingURL: URL?
    private var timer: Timer?
    
    private var sharedURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)
    }
    
    func startRecording() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.record, mode: .default)
            try session.setActive(true)
        } catch {
            statusText = "Mic error"
            statusColor = .red
            return
        }
        
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("kw-voice.wav")
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
            recorder.isMeteringEnabled = true
            recorder.record()
            audioRecorder = recorder
            isRecording = true
            statusText = "Listening"
            statusColor = .red
            
            timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
                guard let self, self.isRecording else { return }
                self.duration += 0.05
                
                // Update audio level from metering
                self.audioRecorder?.updateMeters()
                let db = self.audioRecorder?.averagePower(forChannel: 0) ?? -160
                // Convert dB to 0-1 range (-55dB = silence, 0dB = max)
                let normalized = max(0, min(1, (db + 55) / 55))
                DispatchQueue.main.async {
                    self.audioLevel = normalized
                }
                
                if self.duration >= 120 { self.stopAndTranscribe() }
            }
        } catch {
            statusText = "Record error"
            statusColor = .red
        }
    }
    
    func stopAndTranscribe() {
        audioRecorder?.stop()
        audioRecorder = nil
        timer?.invalidate()
        timer = nil
        isRecording = false
        audioLevel = 0
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        
        guard duration > 0.3, let url = recordingURL, let wavData = try? Data(contentsOf: url) else {
            statusText = "Too short"
            isDone = true
            return
        }
        
        isTranscribing = true
        statusText = "Transcribing..."
        
        Task {
            var result = await transcribeOnDevice(wavData: wavData)
            if result == nil { result = await transcribeViaAPI(wavData: wavData) }
            
            await MainActor.run {
                isTranscribing = false
                
                if let result {
                    transcribedText = result.text
                    writeResult(text: result.text, durationMs: result.durationMs, error: nil)
                    statusText = "Done!"
                } else {
                    writeResult(text: "", durationMs: 0, error: result == nil ? "Transcription failed" : "No speech detected")
                    statusText = "Failed"
                }
                isDone = true
            }
        }
    }
    
    // MARK: - On-device Whisper
    
    private func transcribeOnDevice(wavData: Data) async -> TranscriptionOutput? {
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
                    let ms = Int(Date().timeIntervalSince(start) * 1000)
                    return TranscriptionOutput(text: text, durationMs: ms)
                } catch {
                    continue
                }
            }
        }
        return nil
    }
    
    // MARK: - API Fallback
    
    private func transcribeViaAPI(wavData: Data) async -> TranscriptionOutput? {
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
            return TranscriptionOutput(text: text.trimmingCharacters(in: .whitespacesAndNewlines), durationMs: ms)
        } catch {
            return nil
        }
    }
    
    // MARK: - Write Result
    
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
    
    func cleanup() {
        audioRecorder?.stop()
        timer?.invalidate()
        try? AVAudioSession.sharedInstance().setActive(false)
    }
}

private struct TranscriptionOutput {
    let text: String
    let durationMs: Int
}
#endif
