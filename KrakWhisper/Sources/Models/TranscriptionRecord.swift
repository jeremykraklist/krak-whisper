import Foundation
import SwiftData

// MARK: - TranscriptionRecord

/// SwiftData model for persisted transcription records.
///
/// Stores the result of a whisper.cpp transcription along with metadata
/// about the recording session (duration, model used, etc.).
@Model
final class TranscriptionRecord {

    /// Unique identifier for this record.
    @Attribute(.unique)
    var id: UUID

    /// The transcribed text content.
    var text: String

    /// Duration of the audio recording in seconds.
    var duration: TimeInterval

    /// When this transcription was created.
    var createdAt: Date

    /// Which whisper model was used (e.g., "tiny", "base", "small", "medium", "large").
    var modelUsed: String

    /// User-editable title for this transcription.
    var title: String

    /// Comma-separated tags for categorization.
    var tags: String

    /// Whether this record has been favorited by the user.
    var isFavorited: Bool

    /// Computed property: display title falls back to first line of text.
    var displayTitle: String {
        if !title.isEmpty {
            return title
        }
        let firstLine = text.prefix(60)
        if firstLine.count < text.count {
            return firstLine + "…"
        }
        return String(firstLine)
    }

    /// Computed property: parsed tags array.
    var tagList: [String] {
        get {
            tags.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }
        set {
            tags = newValue.joined(separator: ", ")
        }
    }

    /// Computed property: formatted duration string (e.g., "1:23").
    var formattedDuration: String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    /// Computed property: formatted date for display.
    var formattedDate: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: createdAt, relativeTo: Date())
    }

    init(
        text: String,
        duration: TimeInterval,
        modelUsed: String,
        title: String = "",
        tags: String = "",
        isFavorited: Bool = false
    ) {
        self.id = UUID()
        self.text = text
        self.duration = duration
        self.createdAt = Date()
        self.modelUsed = modelUsed
        self.title = title
        self.tags = tags
        self.isFavorited = isFavorited
    }
}

// MARK: - TranscriptionStore

/// Service layer for managing transcription records via SwiftData.
///
/// Provides CRUD operations and query helpers for the transcription history.
/// Uses SwiftData's `ModelContext` for persistence.
@MainActor
final class TranscriptionStore: ObservableObject {

    private let modelContext: ModelContext

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    // MARK: - Create

    /// Save a new transcription record.
    @discardableResult
    func save(
        text: String,
        duration: TimeInterval,
        modelUsed: String,
        title: String = "",
        tags: String = ""
    ) -> TranscriptionRecord {
        let record = TranscriptionRecord(
            text: text,
            duration: duration,
            modelUsed: modelUsed,
            title: title,
            tags: tags
        )
        modelContext.insert(record)
        try? modelContext.save()
        return record
    }

    // MARK: - Read

    /// Fetch all records sorted by creation date (newest first).
    func fetchAll() -> [TranscriptionRecord] {
        let descriptor = FetchDescriptor<TranscriptionRecord>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        return (try? modelContext.fetch(descriptor)) ?? []
    }

    /// Search records by text content or title.
    func search(query: String) -> [TranscriptionRecord] {
        let descriptor = FetchDescriptor<TranscriptionRecord>(
            predicate: #Predicate<TranscriptionRecord> { record in
                record.text.localizedStandardContains(query) ||
                record.title.localizedStandardContains(query) ||
                record.tags.localizedStandardContains(query)
            },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        return (try? modelContext.fetch(descriptor)) ?? []
    }

    /// Fetch records filtered by model name.
    func fetchByModel(_ model: String) -> [TranscriptionRecord] {
        let descriptor = FetchDescriptor<TranscriptionRecord>(
            predicate: #Predicate<TranscriptionRecord> { record in
                record.modelUsed == model
            },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        return (try? modelContext.fetch(descriptor)) ?? []
    }

    /// Fetch favorited records.
    func fetchFavorites() -> [TranscriptionRecord] {
        let descriptor = FetchDescriptor<TranscriptionRecord>(
            predicate: #Predicate<TranscriptionRecord> { record in
                record.isFavorited
            },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        return (try? modelContext.fetch(descriptor)) ?? []
    }

    // MARK: - Update

    /// Update the title of a record.
    func updateTitle(_ record: TranscriptionRecord, title: String) {
        record.title = title
        try? modelContext.save()
    }

    /// Update the tags of a record.
    func updateTags(_ record: TranscriptionRecord, tags: String) {
        record.tags = tags
        try? modelContext.save()
    }

    /// Toggle favorite status.
    func toggleFavorite(_ record: TranscriptionRecord) {
        record.isFavorited.toggle()
        try? modelContext.save()
    }

    // MARK: - Delete

    /// Delete a single record.
    func delete(_ record: TranscriptionRecord) {
        modelContext.delete(record)
        try? modelContext.save()
    }

    /// Delete multiple records.
    func delete(_ records: [TranscriptionRecord]) {
        for record in records {
            modelContext.delete(record)
        }
        try? modelContext.save()
    }

    /// Delete all records.
    func deleteAll() {
        let all = fetchAll()
        for record in all {
            modelContext.delete(record)
        }
        try? modelContext.save()
    }

    // MARK: - Stats

    /// Total number of transcriptions.
    var totalCount: Int {
        fetchAll().count
    }

    /// Total recording duration across all transcriptions.
    var totalDuration: TimeInterval {
        fetchAll().reduce(0) { $0 + $1.duration }
    }
}
