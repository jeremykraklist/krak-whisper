#if os(iOS)
import SwiftUI

/// Instructions for enabling the KrakWhisper keyboard extension.
///
/// Shown in the Settings screen of the main app. Guides the user through
/// the iOS Settings flow to enable the custom keyboard.
struct KeyboardSetupInstructionsView: View {

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Step 1
            SetupStepRow(
                number: 1,
                icon: "gear",
                title: "Open Settings",
                description: "Go to Settings → General → Keyboard → Keyboards"
            )

            // Step 2
            SetupStepRow(
                number: 2,
                icon: "plus.circle",
                title: "Add Keyboard",
                description: "Tap \"Add New Keyboard…\" and select KrakWhisper"
            )

            // Step 3
            SetupStepRow(
                number: 3,
                icon: "lock.open",
                title: "Allow Full Access",
                description: "Tap KrakWhisper → enable \"Allow Full Access\" (required for microphone)"
            )

            // Step 4
            SetupStepRow(
                number: 4,
                icon: "globe",
                title: "Switch to KrakWhisper",
                description: "In any app, hold the globe button and select KrakWhisper"
            )

            // Open Settings button
            Button {
                openKeyboardSettings()
            } label: {
                HStack {
                    Image(systemName: "arrow.up.forward.app")
                    Text("Open Keyboard Settings")
                }
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.accentColor)
                )
                .foregroundStyle(.white)
            }
            .padding(.top, 4)
        }
        .padding(.vertical, 4)
    }

    private func openKeyboardSettings() {
        #if os(iOS)
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
        #endif
    }
}

/// A single setup instruction step.
private struct SetupStepRow: View {
    let number: Int
    let icon: String
    let title: String
    let description: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // Step number badge
            ZStack {
                Circle()
                    .fill(Color.blue.opacity(0.15))
                    .frame(width: 28, height: 28)
                Text("\(number)")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.blue)
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Image(systemName: icon)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                }
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

#endif // os(iOS)
