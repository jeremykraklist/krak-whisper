import SwiftUI

/// A row displaying a model's name, size, download state, and action button.
struct ModelDownloadRow: View {
    let model: WhisperModelSize
    let state: ModelDownloadState
    let isSelected: Bool
    let onDownload: () -> Void
    let onCancel: () -> Void
    let onDelete: () -> Void
    let onSelect: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            // Model info
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(model.displayName)
                        .font(.headline)
                    if isSelected && state == .downloaded {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.subheadline)
                    }
                }
                Text(model.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(model.fileSizeDescription)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            // State-dependent action
            stateView
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var stateView: some View {
        switch state {
        case .notDownloaded:
            Button(action: onDownload) {
                Label("Download", systemImage: "arrow.down.circle")
                    .font(.subheadline)
            }
            .buttonStyle(.borderedProminent)
            .tint(.blue)

        case .downloading(let progress):
            HStack(spacing: 8) {
                VStack(alignment: .trailing, spacing: 2) {
                    ProgressView(value: progress)
                        .frame(width: 80)
                    Text("\(Int(progress * 100))%")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Button(action: onCancel) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

        case .validating:
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("Validating…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

        case .downloaded:
            Menu {
                if !isSelected {
                    Button("Use This Model", systemImage: "checkmark.circle") {
                        onSelect()
                    }
                }
                Button("Delete", systemImage: "trash", role: .destructive) {
                    onDelete()
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("Ready")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

        case .failed(let message):
            VStack(alignment: .trailing, spacing: 2) {
                Button(action: onDownload) {
                    Label("Retry", systemImage: "arrow.clockwise")
                        .font(.subheadline)
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(1)
            }
        }
    }
}
