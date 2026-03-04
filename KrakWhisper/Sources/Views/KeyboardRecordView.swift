#if os(iOS)
import SwiftUI
import AVFoundation
import SwiftWhisper
import CryptoKit

/// Full-screen recording view shown when keyboard triggers voice input.
/// Records audio, transcribes with Whisper, writes result to App Group,
/// then prompts user to swipe back to keyboard.
struct KeyboardRecordView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var recorder = KeyboardRecordViewModel()
    
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            
            VStack(spacing: 30) {
                Spacer()
                
                // Status icon
                ZStack {
                    Circle()
                        .fill(recorder.statusColor.opacity(0.15))
                        .frame(width: 160, height: 160)
                    
                    Circle()
                        .fill(recorder.statusColor.opacity(0.3))
                        .frame(width: 120, height: 120)
                    
                    Image(systemName: recorder.statusIcon)
                        .font(.system(size: 50))
                        .foregroundColor(recorder.statusColor)
                }
                .scaleEffect(recorder.isRecording ? 1.1 : 1.0)
                .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: recorder.isRecording)
                
                // Status text
                Text(recorder.statusText)
                    .font(.title2.bold())
                    .foregroundColor(.white)
                
                if recorder.isRecording {
                    Text(String(format: "%.1fs", recorder.duration))
                        .font(.system(size: 48, weight: .light, design: .monospaced))
                        .foregroundColor(.white.opacity(0.7))
                }
                
                if recorder.isTranscribing {
                    ProgressView()
                        .tint(.white)
                        .scaleEffect(1.5)
                }
                
                Spacer()
                
                // Action button
                if recorder.isRecording {
                    Button(action: { recorder.stopAndTranscribe() }) {
                        HStack {
                            Image(systemName: "stop.fill")
                            Text("Stop Recording")
                        }
                        .font(.headline)
                        .foregroundColor(.white)
                        .padding(.horizontal, 40)
                        .padding(.vertical, 16)
                        .background(Color.red)
                        .cornerRadius(30)
                    }
                } else if recorder.isDone {
                    VStack(spacing: 16) {
                        if !recorder.transcribedText.isEmpty {
                            Text("\"\(recorder.transcribedText)\"")
                                .font(.body)
                                .foregroundColor(.white.opacity(0.8))
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 20)
                                .lineLimit(3)
                        }
                        
                        Text("Returning to keyboard...")
                            .font(.headline)
                            .foregroundColor(.white.opacity(0.6))
                    }
                }
                
                Spacer().frame(height: 40)
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
                // Auto-dismiss after showing result briefly
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    dismiss()
                }
            }
        }
    }
}

// MARK: - ViewModel

class KeyboardRecordViewModel: ObservableObject {
    @Published var isRecording = false
    @Published var isTranscribing = false
    @Published var isDone = false
    @Published var duration: TimeInterval = 0
    @Published var statusText = "Preparing..."
    @Published var statusIcon = "mic.fill"
    @Published var statusColor: Color = .blue
    @Published var transcribedText = ""
    
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
            statusText = "Mic error: \(error.localizedDescription)"
            statusColor = .red; statusIcon = "exclamationmark.triangle"
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
            recorder.record()
            audioRecorder = recorder
            isRecording = true
            statusText = "Listening..."
            statusIcon = "mic.fill"
            statusColor = .red
            
            timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                guard let self, self.isRecording else { return }
                self.duration += 0.1
                if self.duration >= 60 { self.stopAndTranscribe() }
            }
        } catch {
            statusText = "Record error: \(error.localizedDescription)"
            statusColor = .red; statusIcon = "exclamationmark.triangle"
        }
    }
    
    func stopAndTranscribe() {
        audioRecorder?.stop()
        audioRecorder = nil
        timer?.invalidate()
        timer = nil
        isRecording = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        
        guard duration > 0.3, let url = recordingURL, let wavData = try? Data(contentsOf: url) else {
            statusText = "Too short"
            statusColor = .orange; statusIcon = "exclamationmark.triangle"
            isDone = true
            return
        }
        
        isTranscribing = true
        statusText = "Transcribing..."
        statusIcon = "waveform"
        statusColor = .blue
        
        // Try on-device Whisper first, fall back to API
        Task {
            var result = await transcribeOnDevice(wavData: wavData)
            if result == nil { result = await transcribeViaAPI(wavData: wavData) }
            
            await MainActor.run {
                isTranscribing = false
                
                if let result {
                    transcribedText = result.text
                    writeResult(text: result.text, durationMs: result.durationMs, error: nil)
                    statusText = "Done!"
                    statusIcon = "checkmark.circle.fill"
                    statusColor = .green
                } else {
                    writeResult(text: "", durationMs: 0, error: "Transcription failed")
                    statusText = "Failed"
                    statusIcon = "xmark.circle.fill"
                    statusColor = .red
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
    
    // MARK: - Write Result to App Group (encrypted + Darwin notification)
    
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
        
        // Encrypt before writing to App Group
        if let encrypted = try? AppGroupCrypto.encrypt(jsonData) {
            try? encrypted.write(to: url)
        } else {
            // Fallback: write unencrypted if encryption fails
            try? jsonData.write(to: url)
        }
        
        // Post Darwin notification so keyboard extension picks up result immediately
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterPostNotification(
            center,
            CFNotificationName("com.krakwhisper.transcriptionReady" as CFString),
            nil,
            nil,
            true
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
