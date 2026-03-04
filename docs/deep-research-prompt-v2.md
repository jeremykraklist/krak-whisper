# Deep Research Prompt: iOS Keyboard Extension — Voice Input Implementation Patterns

**Target:** iOS 26.3 · Swift 6.2 · Xcode 26.2 · Minimum deployment iOS 18.0

---

I'm building a custom keyboard extension that needs voice-to-text. I already know every constraint (no mic access in extensions, memory caps, broken `openURL:` responder chain, `NSExtensionContext.open(url)` limited to Today widgets, Whisper too large for 42–45MB Jetsam limits). **Skip all constraint discussion. I need only working solutions.**

## What I Need

**Provide the 3 best implementation patterns for voice dictation from an iOS keyboard extension, ranked by reliability and UX quality.** For each approach, include:

1. **Architecture diagram** (which process records, which transcribes, how text returns to the keyboard)
2. **Concrete Swift code** for the critical handoff points (not pseudocode)
3. **Memory profile** — will it survive the keyboard Jetsam limit?
4. **iOS version compatibility** — does it work on iOS 18+, or only iOS 26?
5. **App Store review risk** — any private API or entitlement concerns?

## Specific Questions

### 1. Shipping App Reverse-Engineering
How do **GBoard** and **SwiftKey** implement their voice input buttons on iOS 26 *right now*? Specifically:
- Do they launch the containing app, record there, then return text via `UIPasteboard` / App Group `UserDefaults` / shared `FileManager` container?
- Do they use a **full-screen overlay** (`UIInputViewController.requestSupplementaryLexicon` pattern or similar) that triggers the system microphone permission prompt?
- Do they invoke the **system dictation** affordance (`UITextInputMode` or `dictationRecognitionLanguages`) rather than custom recording?
- Is there a `UIInputViewController` API that grants temporary mic access I'm missing?

### 2. iOS 26-Specific New Pathways
- **SpeechAnalyzer** (new WWDC 2025/26 API): Can it run inside an extension? Does it have the same mic restriction as `SFSpeechRecognizer`, or does it use a different entitlement model?
- **App Intents / Shortcuts integration**: Can the keyboard trigger a `LiveActivityIntent` or `AppIntent` that records audio in the main app and returns the transcript as the intent result — all without visibly switching apps?
- **ActivityKit / Live Activities**: Can a Live Activity started by the keyboard extension surface a mic-recording UI in the Dynamic Island or Lock Screen, bypassing the extension sandbox?
- **ControlWidget** (iOS 26): Can a Control Center widget trigger recording and pipe text back?

### 3. File-Based Transcription Inside the Extension
- Can `SFSpeechURLRecognitionRequest` transcribe a `.wav`/`.m4a` file that was recorded by the host app and placed in a shared App Group container — **entirely within the keyboard extension process**? What's the peak memory cost?
- If so, what's the latency for a 30-second clip on A17+ silicon with on-device recognition?

### 4. KeyboardKit 8.8+ Dictation
- What is KeyboardKit's **exact architecture** for their `DictationService`? Walk through the flow: keyboard tap → app switch → recording → transcription → text return.
- Do they use `UIPasteboard`, App Groups, deep links, or something else for the return path?
- What's the user-perceived UX (how many taps, does the app visibly open)?

### 5. User-Initiated App Launch from Extension
- Does `SwiftUI Link` with a custom URL scheme work inside `UIInputViewController` on iOS 26?
- Does `ASWebAuthenticationSession` work from a keyboard extension to open a web/app flow and return data?
- Can `UIApplication.shared.open(_:)` be accessed via any legitimate path in iOS 26 extensions?

## Output Format
Rank approaches **best-first**. For each: code snippets, architectural tradeoffs, and a boolean "ships on App Store today" verdict. If an approach requires iOS 26 only, flag it clearly.
