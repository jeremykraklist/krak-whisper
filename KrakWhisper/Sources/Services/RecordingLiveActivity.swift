#if os(iOS)
import ActivityKit
import SwiftUI

// MARK: - Live Activity Attributes for Dynamic Island

struct RecordingAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        var status: RecordingStatus
        var duration: TimeInterval
        var transcribedText: String?
    }
    
    enum RecordingStatus: String, Codable, Hashable {
        case recording
        case transcribing
        case done
        case error
    }
    
    var source: String // "keyboard" or "app"
}

// MARK: - Live Activity Manager

@MainActor
final class RecordingActivityManager: ObservableObject {
    static let shared = RecordingActivityManager()
    
    private var currentActivity: Activity<RecordingAttributes>?
    
    func startRecordingActivity(source: String = "keyboard") {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        
        // End any existing activity
        endActivity()
        
        let attributes = RecordingAttributes(source: source)
        let state = RecordingAttributes.ContentState(
            status: .recording,
            duration: 0,
            transcribedText: nil
        )
        
        do {
            let activity = try Activity.request(
                attributes: attributes,
                content: .init(state: state, staleDate: nil),
                pushType: nil
            )
            currentActivity = activity
        } catch {
            print("Failed to start Live Activity: \(error)")
        }
    }
    
    func updateDuration(_ duration: TimeInterval) {
        Task {
            let state = RecordingAttributes.ContentState(
                status: .recording,
                duration: duration,
                transcribedText: nil
            )
            await currentActivity?.update(.init(state: state, staleDate: nil))
        }
    }
    
    func updateTranscribing() {
        Task {
            let state = RecordingAttributes.ContentState(
                status: .transcribing,
                duration: 0,
                transcribedText: nil
            )
            await currentActivity?.update(.init(state: state, staleDate: nil))
        }
    }
    
    func updateDone(text: String) {
        Task {
            let state = RecordingAttributes.ContentState(
                status: .done,
                duration: 0,
                transcribedText: String(text.prefix(80))
            )
            await currentActivity?.update(.init(state: state, staleDate: nil))
            
            // End after showing result briefly
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            endActivity()
        }
    }
    
    func updateError(_ message: String) {
        Task {
            let state = RecordingAttributes.ContentState(
                status: .error,
                duration: 0,
                transcribedText: message
            )
            await currentActivity?.update(.init(state: state, staleDate: nil))
            
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            endActivity()
        }
    }
    
    func endActivity() {
        Task {
            await currentActivity?.end(nil, dismissalPolicy: .immediate)
            currentActivity = nil
        }
    }
}

// MARK: - Live Activity Widget (requires Widget extension, but we define the views here)

struct RecordingLiveActivityView: View {
    let state: RecordingAttributes.ContentState
    
    var body: some View {
        HStack(spacing: 12) {
            // Status icon
            statusIcon
                .font(.title2)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(statusText)
                    .font(.headline)
                    .foregroundColor(.white)
                
                if state.status == .recording {
                    Text(String(format: "%.1fs", state.duration))
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.7))
                }
                
                if let text = state.transcribedText {
                    Text(text)
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.7))
                        .lineLimit(1)
                }
            }
            
            Spacer()
            
            if state.status == .recording {
                Image(systemName: "stop.fill")
                    .foregroundColor(.red)
                    .font(.title3)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
    
    @ViewBuilder
    private var statusIcon: some View {
        switch state.status {
        case .recording:
            Image(systemName: "mic.fill")
                .foregroundColor(.red)
        case .transcribing:
            Image(systemName: "waveform")
                .foregroundColor(.blue)
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(.green)
        case .error:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
        }
    }
    
    private var statusText: String {
        switch state.status {
        case .recording: return "Recording..."
        case .transcribing: return "Transcribing..."
        case .done: return "Done!"
        case .error: return "Error"
        }
    }
}
#endif
