import Testing
@testable import KrakWhisper

// MARK: - AITextProcessor Tests

@Suite("AITextProcessor")
struct AITextProcessorTests {

    // MARK: - Filler Word Removal

    @Test("Removes basic filler words")
    func removesBasicFillers() {
        let input = "I was um thinking about uh the project"
        let result = AITextProcessor.processText(input)
        #expect(!result.contains(" um "))
        #expect(!result.contains(" uh "))
        #expect(result.contains("thinking"))
        #expect(result.contains("project"))
    }

    @Test("Removes repeated filler words")
    func removesRepeatedFillers() {
        let input = "So um uh basically I literally went to the store"
        let result = AITextProcessor.processText(input)
        #expect(!result.lowercased().contains(" um "))
        #expect(!result.lowercased().contains(" uh "))
        #expect(!result.lowercased().contains("basically"))
        #expect(!result.lowercased().contains("literally"))
        #expect(result.contains("went"))
        #expect(result.contains("store"))
    }

    @Test("Removes multi-word filler phrases")
    func removesFillerPhrases() {
        let input = "The project, you know, is going well"
        let result = AITextProcessor.processText(input)
        #expect(!result.lowercased().contains("you know"))
        #expect(result.contains("project"))
    }

    // MARK: - Whitespace Handling

    @Test("Collapses multiple spaces")
    func collapsesMultipleSpaces() {
        let input = "Hello    world   test"
        let result = AITextProcessor.processText(input)
        #expect(!result.contains("  "))
    }

    @Test("Collapses excessive newlines")
    func collapsesExcessiveNewlines() {
        let input = "First paragraph\n\n\n\n\nSecond paragraph"
        let result = AITextProcessor.processText(input)
        #expect(!result.contains("\n\n\n"))
    }

    // MARK: - Capitalization

    @Test("Capitalizes after sentence-ending punctuation")
    func capitalizesAfterPunctuation() {
        let input = "hello world. this is a test. another sentence."
        let result = AITextProcessor.processText(input)
        #expect(result.hasPrefix("Hello"))
        #expect(result.contains("This is"))
        #expect(result.contains("Another sentence"))
    }

    @Test("Capitalizes after question marks and exclamations")
    func capitalizesAfterQuestionAndExclamation() {
        let input = "is this working? yes it is! great news."
        let result = AITextProcessor.processText(input)
        #expect(result.contains("Is this"))
        #expect(result.contains("Yes it"))
        #expect(result.contains("Great news"))
    }

    // MARK: - Edge Cases

    @Test("Handles empty string")
    func handlesEmpty() {
        let result = AITextProcessor.processText("")
        #expect(result.isEmpty)
    }

    @Test("Handles whitespace-only string")
    func handlesWhitespaceOnly() {
        let result = AITextProcessor.processText("   \n  \n  ")
        #expect(result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    @Test("Preserves meaningful content")
    func preservesMeaningfulContent() {
        let input = "The meeting went well and we decided to proceed with option A."
        let result = AITextProcessor.processText(input)
        #expect(result.contains("meeting went"))
        #expect(result.contains("option A"))
    }

    @Test("Fixes space before punctuation")
    func fixesSpaceBeforePunctuation() {
        let input = "Hello world ."
        let result = AITextProcessor.processText(input)
        #expect(result.contains("world."))
        #expect(!result.contains("world ."))
    }

    // MARK: - Integration (full pipeline)

    @Test("Full cleanup pipeline works end-to-end")
    func fullPipeline() {
        let input = "So um I was, you know, thinking about uh basically the project.  and honestly it's uh going pretty well."
        let result = AITextProcessor.processText(input)

        // Fillers removed
        #expect(!result.lowercased().contains(" um "))
        #expect(!result.lowercased().contains(" uh "))
        #expect(!result.lowercased().contains("you know"))
        #expect(!result.lowercased().contains("basically"))
        #expect(!result.lowercased().contains("honestly"))

        // Content preserved
        #expect(result.contains("thinking"))
        #expect(result.contains("project"))

        // No double spaces
        #expect(!result.contains("  "))
    }
}
