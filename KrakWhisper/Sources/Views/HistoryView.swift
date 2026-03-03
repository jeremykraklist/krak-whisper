#if os(iOS)
import SwiftUI
import SwiftData

// MARK: - HistoryView

/// Displays a searchable, sorted list of transcription records.
///
/// Features:
/// - List sorted by date (newest first)
/// - Tap for detail view
/// - Swipe to delete
/// - Search by text, title, or tags
/// - Share individual transcriptions
struct HistoryView: View {

    @Environment(\.modelContext) private var modelContext

    @Query(sort: \TranscriptionRecord.createdAt, order: .reverse)
    private var records: [TranscriptionRecord]

    @State private var searchText = ""
    @State private var selectedRecord: TranscriptionRecord?
    @State private var showingDeleteConfirmation = false
    @State private var recordToDelete: TranscriptionRecord?
    @State private var showingError = false
    @State private var errorMessage = ""

    /// Filtered records based on search text.
    private var filteredRecords: [TranscriptionRecord] {
        if searchText.isEmpty {
            return records
        }
        let query = searchText.lowercased()
        return records.filter { record in
            record.text.localizedCaseInsensitiveContains(query) ||
            record.title.localizedCaseInsensitiveContains(query) ||
            record.tags.localizedCaseInsensitiveContains(query)
        }
    }

    /// Group records by date section (Today, Yesterday, This Week, Earlier).
    private var groupedRecords: [(String, [TranscriptionRecord])] {
        let calendar = Calendar.current
        let now = Date()

        var today: [TranscriptionRecord] = []
        var yesterday: [TranscriptionRecord] = []
        var thisWeek: [TranscriptionRecord] = []
        var earlier: [TranscriptionRecord] = []

        for record in filteredRecords {
            if calendar.isDateInToday(record.createdAt) {
                today.append(record)
            } else if calendar.isDateInYesterday(record.createdAt) {
                yesterday.append(record)
            } else if let weekAgo = calendar.date(byAdding: .day, value: -7, to: now),
                      record.createdAt > weekAgo {
                thisWeek.append(record)
            } else {
                earlier.append(record)
            }
        }

        var groups: [(String, [TranscriptionRecord])] = []
        if !today.isEmpty { groups.append(("Today", today)) }
        if !yesterday.isEmpty { groups.append(("Yesterday", yesterday)) }
        if !thisWeek.isEmpty { groups.append(("This Week", thisWeek)) }
        if !earlier.isEmpty { groups.append(("Earlier", earlier)) }

        return groups
    }

    var body: some View {
        NavigationStack {
            Group {
                if records.isEmpty {
                    emptyStateView
                } else if filteredRecords.isEmpty {
                    noSearchResultsView
                } else {
                    recordsList
                }
            }
            .navigationTitle("History")
            .searchable(text: $searchText, prompt: "Search transcriptions")
            .navigationDestination(item: $selectedRecord) { record in
                TranscriptionDetailView(record: record)
            }
            .alert("Error", isPresented: $showingError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage)
            }
        }
    }

    // MARK: - Records List

    private var recordsList: some View {
        List {
            ForEach(groupedRecords, id: \.0) { section, sectionRecords in
                Section(section) {
                    ForEach(sectionRecords) { record in
                        Button(action: { selectedRecord = record }) {
                            HistoryRowView(record: record)
                        }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                deleteRecord(record)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                        .swipeActions(edge: .leading) {
                            Button {
                                toggleFavorite(record)
                            } label: {
                                Label(
                                    record.isFavorited ? "Unfavorite" : "Favorite",
                                    systemImage: record.isFavorited ? "star.slash" : "star.fill"
                                )
                            }
                            .tint(.yellow)

                            ShareLink(item: record.text) {
                                Label("Share", systemImage: "square.and.arrow.up")
                            }
                            .tint(.blue)
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    // MARK: - Empty States

    private var emptyStateView: some View {
        ContentUnavailableView(
            "No Transcriptions Yet",
            systemImage: "waveform",
            description: Text("Record your first transcription to see it here.")
        )
    }

    private var noSearchResultsView: some View {
        ContentUnavailableView.search(text: searchText)
    }

    // MARK: - Actions

    private func deleteRecord(_ record: TranscriptionRecord) {
        withAnimation {
            modelContext.delete(record)
            do {
                try modelContext.save()
            } catch {
                errorMessage = "Failed to delete: \(error.localizedDescription)"
                showingError = true
            }
        }
    }

    private func toggleFavorite(_ record: TranscriptionRecord) {
        record.isFavorited.toggle()
        do {
            try modelContext.save()
        } catch {
            record.isFavorited.toggle() // revert
            errorMessage = "Failed to save: \(error.localizedDescription)"
            showingError = true
        }
    }
}

// MARK: - HistoryRowView

/// A single row in the history list showing a transcription summary.
struct HistoryRowView: View {

    let record: TranscriptionRecord

    @State private var showCopyConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(record.displayTitle)
                    .font(.headline)
                    .lineLimit(1)

                Spacer()

                if record.isFavorited {
                    Image(systemName: "star.fill")
                        .foregroundStyle(.yellow)
                        .font(.caption)
                }

                // Quick copy button
                Button {
                    ClipboardService.copy(record.text)
                    showCopyConfirmation = true
                    Task {
                        try? await Task.sleep(for: .seconds(1.5))
                        showCopyConfirmation = false
                    }
                } label: {
                    Image(systemName: showCopyConfirmation ? "checkmark.circle.fill" : "doc.on.doc")
                        .font(.system(size: 16))
                        .foregroundStyle(showCopyConfirmation ? .green : .secondary)
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.plain)
            }

            Text(record.text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)

            HStack(spacing: 12) {
                Label(record.formattedDuration, systemImage: "clock")
                Label(record.modelUsed, systemImage: "cpu")
                Text(record.formattedDate)
            }
            .font(.caption)
            .foregroundStyle(.tertiary)

            if !record.tagList.isEmpty {
                HStack(spacing: 4) {
                    ForEach(record.tagList.prefix(3), id: \.self) { tag in
                        Text(tag)
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.fill.tertiary)
                            .clipShape(Capsule())
                    }
                    if record.tagList.count > 3 {
                        Text("+\(record.tagList.count - 3)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - TranscriptionDetailView

/// Detail view for a single transcription record.
///
/// Shows full text, metadata, and provides editing/sharing capabilities.
/// Includes AI cleanup with before/after toggle.
struct TranscriptionDetailView: View {

    @Environment(\.modelContext) private var modelContext
    @Bindable var record: TranscriptionRecord

    @State private var isEditingTitle = false
    @State private var editedTitle = ""
    @State private var isEditingTags = false
    @State private var editedTags = ""
    @State private var showingShareSheet = false
    @State private var showingError = false
    @State private var errorMessage = ""
    @State private var showCopiedInline = false

    /// Whether to show the cleaned version (true) or original (false).
    @State private var showingCleanedText = false

    /// AI cleanup service instance.
    @State private var cleanupService = AICleanupService()

    /// Whether cleanup is currently running.
    @State private var isCleaningUp = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Title section
                titleSection

                // Metadata
                metadataSection

                // Tags
                tagsSection

                Divider()

                // AI Cleanup section
                cleanupSection

                // Full transcription text
                textSection
            }
            .padding()
        }
        .navigationTitle("Transcription")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    record.isFavorited.toggle()
                    do {
                        try modelContext.save()
                    } catch {
                        record.isFavorited.toggle() // revert
                        errorMessage = "Failed to save: \(error.localizedDescription)"
                        showingError = true
                    }
                } label: {
                    Image(systemName: record.isFavorited ? "star.fill" : "star")
                        .foregroundStyle(record.isFavorited ? .yellow : .secondary)
                }

                ShareLink(item: shareText) {
                    Image(systemName: "square.and.arrow.up")
                }

                Menu {
                    Button {
                        ClipboardService.copy(record.text)
                        UIPasteboard.general.string = displayedText
                    } label: {
                        Label("Copy Text", systemImage: "doc.on.doc")
                    }

                    if record.cleanedText != nil {
                        Button {
                            UIPasteboard.general.string = record.cleanedText ?? ""
                        } label: {
                            Label("Copy Cleaned Text", systemImage: "doc.on.doc.fill")
                        }

                        Button {
                            UIPasteboard.general.string = record.text
                        } label: {
                            Label("Copy Original Text", systemImage: "doc.on.doc")
                        }
                    }

                    Button {
                        isEditingTitle = true
                        editedTitle = record.title
                    } label: {
                        Label("Edit Title", systemImage: "pencil")
                    }

                    Button {
                        isEditingTags = true
                        editedTags = record.tags
                    } label: {
                        Label("Edit Tags", systemImage: "tag")
                    }

                    if record.cleanedText != nil {
                        Divider()

                        Button(role: .destructive) {
                            record.cleanedText = nil
                            showingCleanedText = false
                            do {
                                try modelContext.save()
                            } catch {
                                errorMessage = "Failed to clear cleanup: \(error.localizedDescription)"
                                showingError = true
                            }
                        } label: {
                            Label("Remove Cleaned Version", systemImage: "trash")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .alert("Edit Title", isPresented: $isEditingTitle) {
            TextField("Title", text: $editedTitle)
            Button("Save") {
                record.title = editedTitle
                do {
                    try modelContext.save()
                } catch {
                    errorMessage = "Failed to save title: \(error.localizedDescription)"
                    showingError = true
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Edit Tags", isPresented: $isEditingTags) {
            TextField("Tags (comma-separated)", text: $editedTags)
            Button("Save") {
                record.tags = editedTags
                do {
                    try modelContext.save()
                } catch {
                    errorMessage = "Failed to save tags: \(error.localizedDescription)"
                    showingError = true
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Error", isPresented: $showingError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage)
        }
    }

    // MARK: - Sections

    private var titleSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(record.displayTitle)
                .font(.title2)
                .fontWeight(.bold)
        }
    }

    private var metadataSection: some View {
        HStack(spacing: 16) {
            MetadataBadge(icon: "clock", label: record.formattedDuration)
            MetadataBadge(icon: "cpu", label: record.modelUsed)
            MetadataBadge(icon: "calendar", label: record.formattedDate)
        }
    }

    private var tagsSection: some View {
        Group {
            if !record.tagList.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(record.tagList, id: \.self) { tag in
                        Text(tag)
                            .font(.caption)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(.blue.opacity(0.1))
                            .foregroundStyle(.blue)
                            .clipShape(Capsule())
                    }
                }
            }
        }
    }

    // MARK: - AI Cleanup Section

    private var cleanupSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                // Clean Up / Re-clean button
                Button {
                    Task {
                        await performCleanup()
                    }
                } label: {
                    HStack(spacing: 6) {
                        if isCleaningUp {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "sparkles")
                        }
                        Text(record.cleanedText != nil ? "Re-clean" : "Clean Up")
                    }
                    .font(.subheadline.weight(.medium))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.blue)
                    .foregroundStyle(.white)
                    .clipShape(Capsule())
                }
                .disabled(isCleaningUp)

                Spacer()

                // Before/After toggle (only visible when cleaned text exists)
                if record.cleanedText != nil {
                    Picker("View", selection: $showingCleanedText) {
                        Text("Original").tag(false)
                        Text("Cleaned").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 200)
                }
            }

            // Cleanup stats badge
            if let cleaned = record.cleanedText, showingCleanedText {
                let originalWords = record.text.split(whereSeparator: \.isWhitespace).count
                let cleanedWords = cleaned.split(whereSeparator: \.isWhitespace).count
                let removed = originalWords - cleanedWords

                if removed > 0 {
                    HStack(spacing: 4) {
                        Image(systemName: "minus.circle.fill")
                            .foregroundStyle(.green)
                        Text("\(removed) filler word\(removed == 1 ? "" : "s") removed")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var textSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Transcription")
                .font(.headline)
                .foregroundStyle(.secondary)
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(showingCleanedText && record.cleanedText != nil ? "Cleaned Transcription" : "Transcription")
                    .font(.headline)
                    .foregroundStyle(.secondary)

                if showingCleanedText && record.cleanedText != nil {
                    Image(systemName: "sparkles")
                        .font(.caption)
                        .foregroundStyle(.blue)
                }
            }

            Text(displayedText)
                .font(.body)
                .textSelection(.enabled)
                .lineSpacing(4)

            // Inline action buttons for quick access
            HStack(spacing: 12) {
                Button {
                    ClipboardService.copy(record.text)
                    showCopiedInline = true
                    Task {
                        try? await Task.sleep(for: .seconds(2))
                        showCopiedInline = false
                    }
                } label: {
                    Label(showCopiedInline ? "Copied!" : "Copy", systemImage: showCopiedInline ? "checkmark" : "doc.on.doc")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(showCopiedInline ? .green : .accentColor)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(.fill.tertiary)
                        .clipShape(Capsule())
                }
                .animation(.easeInOut, value: showCopiedInline)

                ShareLink(item: shareText) {
                    Label("Share", systemImage: "square.and.arrow.up")
                        .font(.subheadline.weight(.medium))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(.fill.tertiary)
                        .clipShape(Capsule())
                }
            }
            .padding(.top, 4)
        }
    }

    /// The text currently displayed based on the toggle state.
    private var displayedText: String {
        if showingCleanedText, let cleaned = record.cleanedText {
            return cleaned
        }
        return record.text
    }

    private var shareText: String {
        var text = record.displayTitle + "\n\n"
        text += displayedText
        text += "\n\n---\nRecorded \(record.formattedDate) • \(record.formattedDuration) • \(record.modelUsed)"
        if showingCleanedText && record.cleanedText != nil {
            text += " • AI Cleaned"
        }
        return text
    }

    // MARK: - Actions

    /// Run AI cleanup on the original text and save the result.
    private func performCleanup() async {
        isCleaningUp = true
        defer { isCleaningUp = false }

        let cleaned = await cleanupService.cleanup(record.text)

        record.cleanedText = cleaned
        showingCleanedText = true

        do {
            try modelContext.save()
        } catch {
            errorMessage = "Failed to save cleaned text: \(error.localizedDescription)"
            showingError = true
        }
    }
}

// MARK: - MetadataBadge

/// Small metadata chip showing an icon and label.
struct MetadataBadge: View {
    let icon: String
    let label: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
            Text(label)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.fill.tertiary)
        .clipShape(Capsule())
    }
}

// MARK: - FlowLayout

/// A simple flow layout that wraps items to the next line.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = layout(proposal: proposal, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = layout(proposal: proposal, subviews: subviews)
        for (index, position) in result.positions.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y),
                proposal: .unspecified
            )
        }
    }

    private func layout(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, positions: [CGPoint]) {
        let maxWidth = proposal.width ?? .infinity
        var positions: [CGPoint] = []
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var lineHeight: CGFloat = 0
        var maxX: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)

            if currentX + size.width > maxWidth, currentX > 0 {
                currentX = 0
                currentY += lineHeight + spacing
                lineHeight = 0
            }

            positions.append(CGPoint(x: currentX, y: currentY))
            lineHeight = max(lineHeight, size.height)
            currentX += size.width + spacing
            maxX = max(maxX, currentX - spacing)
        }

        return (CGSize(width: maxX, height: currentY + lineHeight), positions)
    }
}

// MARK: - Preview

#Preview {
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    let container = try! ModelContainer(for: TranscriptionRecord.self, configurations: config)

    // Add sample data
    let context = container.mainContext
    let samples = [
        TranscriptionRecord(text: "Hello, this is a test transcription. I'm testing the voice recording feature of KrakWhisper to make sure everything works correctly.", duration: 15.3, modelUsed: "base", title: "Test Recording"),
        TranscriptionRecord(text: "Meeting notes: We discussed the Q1 roadmap and agreed on three key priorities for the next sprint.", duration: 45.7, modelUsed: "small", title: "Meeting Notes", tags: "work, meeting"),
        TranscriptionRecord(text: "Quick voice memo about the grocery list. Need milk, eggs, bread, and some vegetables for dinner tonight.", duration: 8.2, modelUsed: "tiny"),
    ]
    for sample in samples {
        context.insert(sample)
    }

    return HistoryView()
        .modelContainer(container)
}
#endif // os(iOS)
