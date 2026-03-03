import Foundation
import NaturalLanguage

// MARK: - AITextProcessor

/// Pure text processing engine for transcript cleanup.
///
/// Not actor-isolated — all methods are pure functions that can run on any thread.
/// Uses Apple's NaturalLanguage framework for tokenization and rule-based
/// processing for filler removal, capitalization, and whitespace normalization.
enum AITextProcessor {

    // MARK: - Filler Words

    /// Common English filler words to strip from transcriptions.
    /// Matched case-insensitively. Multi-word fillers are handled separately.
    static let singleFillerWords: Set<String> = [
        "um", "uh", "uhm", "umm", "uhh",
        "hmm", "hm", "hmph",
        "er", "erm",
        "ah", "ahh",
        "basically", "actually", "honestly", "literally",
        "like",  // contextual — removed only when standalone filler
        "right", // contextual — removed only at sentence boundaries
        "so",    // contextual — removed only at sentence starts
        "well",  // contextual — removed only at sentence starts
    ]

    /// Multi-word filler phrases to strip (matched case-insensitively).
    static let fillerPhrases: [String] = [
        "you know",
        "you know what",
        "you know what I mean",
        "I mean",
        "sort of",
        "kind of",
        "I guess",
        "or something",
        "or whatever",
    ]

    /// Words that are only fillers when they appear at the start of a sentence.
    private static let sentenceStartOnlyFillers: Set<String> = [
        "so", "well", "right", "like",
    ]

    // MARK: - Processing Pipeline

    /// Main text processing pipeline (pure function, no side effects).
    static func processText(_ input: String) -> String {
        guard !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return input
        }

        var text = input

        // Step 1: Remove multi-word filler phrases first (before tokenizing)
        text = removeFillerPhrases(text)

        // Step 2: Remove single filler words using NLP tokenization
        text = removeFillerWords(text)

        // Step 3: Collapse repeated whitespace and line breaks
        text = collapseWhitespace(text)

        // Step 4: Fix capitalization after sentence boundaries
        text = fixCapitalization(text)

        // Step 5: Detect and format lists
        text = formatLists(text)

        // Step 6: Final whitespace cleanup
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)

        return text
    }

    // MARK: - Step 1: Remove Multi-Word Filler Phrases

    /// Remove multi-word filler phrases using case-insensitive regex replacement.
    private static func removeFillerPhrases(_ text: String) -> String {
        var result = text

        // Sort by length descending so longer phrases are matched first
        let sorted = fillerPhrases.sorted { $0.count > $1.count }

        for phrase in sorted {
            // Match the phrase with optional surrounding commas and whitespace
            let escaped = NSRegularExpression.escapedPattern(for: phrase)
            let pattern = "(?:,\\s*)?\\b\(escaped)\\b(?:\\s*,)?"

            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                result = regex.stringByReplacingMatches(
                    in: result,
                    range: NSRange(result.startIndex..., in: result),
                    withTemplate: " "
                )
            }
        }

        return result
    }

    // MARK: - Step 2: Remove Single Filler Words

    /// Use NaturalLanguage tokenizer to identify word boundaries, then remove fillers.
    private static func removeFillerWords(_ text: String) -> String {
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text

        // Collect all word tokens with their ranges
        var tokens: [(range: Range<String.Index>, word: String)] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let word = String(text[range])
            tokens.append((range: range, word: word))
            return true
        }

        guard !tokens.isEmpty else { return text }

        // Identify sentence boundaries for context-dependent fillers
        let sentenceTokenizer = NLTokenizer(unit: .sentence)
        sentenceTokenizer.string = text
        var sentenceStarts: Set<String.Index> = []

        sentenceTokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let sentenceText = text[range]
            let trimmedStart = sentenceText.firstIndex(where: { !$0.isWhitespace && !$0.isNewline })
            if let start = trimmedStart {
                sentenceStarts.insert(start)
            }
            return true
        }

        // Build result by walking through the original text and skipping filler words
        var result = ""
        var lastEnd = text.startIndex

        for token in tokens {
            let lower = token.word.lowercased()

            let isFiller: Bool
            if sentenceStartOnlyFillers.contains(lower) {
                // Only remove if at sentence start
                isFiller = sentenceStarts.contains(token.range.lowerBound)
            } else {
                isFiller = singleFillerWords.contains(lower)
            }

            if isFiller {
                let before = text[lastEnd..<token.range.lowerBound]
                var afterEnd = token.range.upperBound

                // Skip trailing comma after filler if present
                if afterEnd < text.endIndex {
                    let remaining = text[afterEnd...]
                    if let firstNonSpace = remaining.firstIndex(where: { !$0.isWhitespace }) {
                        if text[firstNonSpace] == "," {
                            afterEnd = text.index(after: firstNonSpace)
                        }
                    }
                }

                // Don't add whitespace-only prefix (avoids double spaces)
                let trimmedBefore = String(before)
                if !trimmedBefore.allSatisfy({ $0.isWhitespace || $0 == "," }) {
                    result += trimmedBefore
                }

                lastEnd = afterEnd
            } else {
                result += text[lastEnd..<token.range.upperBound]
                lastEnd = token.range.upperBound
            }
        }

        // Append any remaining text after the last token
        if lastEnd < text.endIndex {
            result += text[lastEnd...]
        }

        return result
    }

    // MARK: - Step 3: Collapse Whitespace

    /// Collapse multiple spaces into one and multiple line breaks into at most two.
    private static func collapseWhitespace(_ text: String) -> String {
        var result = text

        // Collapse multiple spaces/tabs into single space
        if let regex = try? NSRegularExpression(pattern: "[ \\t]+", options: []) {
            result = regex.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: " "
            )
        }

        // Collapse 3+ newlines into double newline (preserve paragraph breaks)
        if let regex = try? NSRegularExpression(pattern: "\\n{3,}", options: []) {
            result = regex.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: "\n\n"
            )
        }

        // Remove spaces before punctuation
        if let regex = try? NSRegularExpression(pattern: "\\s+([.!?,;:])", options: []) {
            result = regex.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: "$1"
            )
        }

        // Ensure space after punctuation (if followed by a letter)
        if let regex = try? NSRegularExpression(pattern: "([.!?,;:])([A-Za-z])", options: []) {
            result = regex.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: "$1 $2"
            )
        }

        return result
    }

    // MARK: - Step 4: Fix Capitalization

    /// Capitalize the first letter after sentence-ending punctuation and at text start.
    private static func fixCapitalization(_ text: String) -> String {
        guard !text.isEmpty else { return text }

        var chars = Array(text)
        var capitalizeNext = true

        for i in 0..<chars.count {
            let char = chars[i]

            if capitalizeNext && char.isLetter {
                chars[i] = Character(char.uppercased())
                capitalizeNext = false
            } else if char == "." || char == "!" || char == "?" {
                capitalizeNext = true
            } else if char == "\n" {
                capitalizeNext = true
            } else if !char.isWhitespace {
                if capitalizeNext && !char.isLetter {
                    // Keep capitalizeNext true — skip non-letter chars like quotes
                } else {
                    capitalizeNext = false
                }
            }
        }

        return String(chars)
    }

    // MARK: - Step 5: Detect and Format Lists

    /// Detect spoken list patterns and format them as proper numbered/bulleted lists.
    ///
    /// Handles patterns like:
    /// - "first... second... third..."
    /// - "number one... number two..."
    /// - "one,... two,... three,..."
    /// - "point one... point two..."
    private static func formatLists(_ text: String) -> String {
        var result = text

        // Pattern: "first, ... second, ... third, ..." (ordinal sequence)
        let ordinals: [(pattern: String, number: Int)] = [
            ("first(?:ly)?", 1), ("second(?:ly)?", 2), ("third(?:ly)?", 3),
            ("fourth(?:ly)?", 4), ("fifth(?:ly)?", 5), ("sixth(?:ly)?", 6),
            ("seventh(?:ly)?", 7), ("eighth(?:ly)?", 8), ("ninth(?:ly)?", 9),
            ("tenth(?:ly)?", 10),
        ]

        // Check if text contains at least 2 sequential ordinals
        var ordinalMatches: [(range: Range<String.Index>, number: Int, content: String)] = []
        let lowered = result.lowercased()

        for (pattern, number) in ordinals {
            let fullPattern = "\\b\(pattern)[,:]?\\s+"
            if let regex = try? NSRegularExpression(pattern: fullPattern, options: .caseInsensitive),
               let match = regex.firstMatch(in: result, range: NSRange(result.startIndex..., in: result)),
               let range = Range(match.range, in: result) {
                // Find the content after this ordinal (up to the next ordinal or end)
                ordinalMatches.append((range: range, number: number, content: ""))
            }
        }

        // If we found 2+ sequential ordinals, format as numbered list
        if ordinalMatches.count >= 2 {
            // Sort by position in text
            ordinalMatches.sort { $0.range.lowerBound < $1.range.lowerBound }

            // Build formatted list
            var formatted = ""
            var preamble = String(result[result.startIndex..<ordinalMatches[0].range.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !preamble.isEmpty {
                formatted += preamble + "\n\n"
            }

            for i in 0..<ordinalMatches.count {
                let start = ordinalMatches[i].range.upperBound
                let end = (i + 1 < ordinalMatches.count)
                    ? ordinalMatches[i + 1].range.lowerBound
                    : result.endIndex

                let content = String(result[start..<end])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: ".,;"))
                    .trimmingCharacters(in: .whitespaces)

                if !content.isEmpty {
                    formatted += "\(ordinalMatches[i].number). \(content)\n"
                }
            }

            result = formatted.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Pattern: "number one... number two..." or "point one..."
        let numberWordPairs: [(pattern: String, num: String)] = [
            ("(?:number|point)\\s+one[,:]?\\s+", "1"),
            ("(?:number|point)\\s+two[,:]?\\s+", "2"),
            ("(?:number|point)\\s+three[,:]?\\s+", "3"),
            ("(?:number|point)\\s+four[,:]?\\s+", "4"),
            ("(?:number|point)\\s+five[,:]?\\s+", "5"),
        ]

        var numberMatches = 0
        for (pattern, _) in numberWordPairs {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
               regex.firstMatch(in: result, range: NSRange(result.startIndex..., in: result)) != nil {
                numberMatches += 1
            }
        }

        if numberMatches >= 2 {
            for (pattern, num) in numberWordPairs {
                if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                    result = regex.stringByReplacingMatches(
                        in: result,
                        range: NSRange(result.startIndex..., in: result),
                        withTemplate: "\n\(num). "
                    )
                }
            }
            // Clean up leading newline
            result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return result
    }
}

// MARK: - AICleanupService

/// On-device text cleanup service for transcribed audio.
///
/// Wraps `AITextProcessor` with async/MainActor-safe API for SwiftUI views.
/// Manages processing state (loading, errors) as `@Published` properties.
///
/// Future: An API-based cleanup path can be toggled via Settings (stubbed).
@MainActor
final class AICleanupService: ObservableObject {

    /// Whether cleanup is currently in progress.
    @Published var isProcessing = false

    /// Last error encountered during cleanup.
    @Published var lastError: String?

    // MARK: - Public API

    /// Clean up a raw transcription string.
    ///
    /// - Parameter rawText: The original transcribed text.
    /// - Returns: Cleaned text with fillers removed and formatting fixed.
    func cleanup(_ rawText: String) async -> String {
        isProcessing = true
        lastError = nil

        defer { isProcessing = false }

        // Run processing off main actor to avoid blocking UI
        let result = await Task.detached(priority: .userInitiated) {
            AITextProcessor.processText(rawText)
        }.value

        return result
    }
}
