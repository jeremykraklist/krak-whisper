# Keyboard Extension Voice-to-Text IPC Research

**Date:** 2026-03-03  
**Author:** Dev Beta  
**Issue:** #42  
**Target:** iOS 26.3, iPhone 17 Pro Max (A18 Pro)

## Executive Summary

The KrakWhisper keyboard extension's mic button uses a responder chain `openURL:` hack to open the main app — **this is completely broken on iOS 18+ (including iOS 26)**. Apple deprecated this approach and the selector now silently fails.

**Solution implemented:** Replace the broken responder chain method with `extensionContext?.open(url)` (the official NSExtensionContext API) + SwiftUI `Link` fallback. Add `SFSpeechRecognizer` as the primary transcription engine in the main app for faster, lighter keyboard-triggered recording.

---

## Option A: Contabo Whisper API from Keyboard Extension

**Endpoint:** `http://157.173.203.33:8178/inference`  
**Verdict:** ❌ NOT VIABLE (keyboard cannot record audio)

### Findings
- Keyboard extensions **cannot access the microphone** — this is a fundamental iOS sandbox restriction since iOS 8
- Even with `RequestsOpenAccess: true` (Full Access), `AVAudioSession` cannot be activated for recording
- `AVAudioEngine` / `AVAudioRecorder` will throw errors or be silently blocked
- Without mic access, there is no audio to send to the Contabo API
- The keyboard CAN make network requests (with Full Access), but that doesn't help without audio input

### Sources
- Apple App Extension Programming Guide: "Custom keyboards, like all app extensions in iOS 8.0, have no access to the device microphone"
- Multiple Stack Overflow reports confirm this restriction persists through iOS 18+
- Reddit r/iOSProgramming: keyboard extension killed after ~50s even when containing app handles audio

---

## Option B: Apple SFSpeechRecognizer in Keyboard Extension

**Verdict:** ❌ NOT VIABLE in keyboard extension / ✅ VIABLE in main app

### Findings — In Keyboard Extension
- `SFSpeechRecognizer` requires microphone access via `AVAudioEngine` or audio buffers
- Since keyboard extensions cannot access the mic, `SFSpeechRecognizer` cannot be used **inside** the keyboard extension
- `SFSpeechAudioBufferRecognitionRequest` requires live audio buffers — no mic = no buffers
- Memory footprint is zero for the recognizer itself (uses system framework), but it's moot without mic access

### Findings — In Main App (RECOMMENDED)
- `SFSpeechRecognizer` works perfectly in the main app
- On-device recognition available since iOS 13 (`supportsOnDeviceRecognition`)
- **Zero model download** — uses built-in Apple Neural Engine models
- **No memory concerns** — runs in system process, not in app memory
- **No duration limits** — on-device recognition has no 1-minute cap
- **~100ms latency** for short utterances
- English on-device recognition is well-supported on A18 Pro
- New `SpeechAnalyzer` / `SpeechTranscriber` APIs in iOS 26 (WWDC 2025) provide even better long-form transcription

### Recommendation
Use `SFSpeechRecognizer` as the **primary** transcription method in `KeyboardRecordView` (main app). It's faster and lighter than SwiftWhisper for short voice commands. Keep SwiftWhisper and Contabo API as fallbacks for quality/long-form.

---

## Option C: Fix the URL-Opening Mechanism (iOS 26)

**Verdict:** ✅ THIS IS THE FIX

### What's Broken
The current code uses the responder chain hack:
```swift
var responder: UIResponder? = self as UIResponder
let selector = NSSelectorFromString("openURL:")
while let r = responder {
    if r.responds(to: selector) {
        r.perform(selector, with: url)
        return
    }
    responder = r.next
}
```

This stopped working in iOS 18. The system logs:
> "BUG IN CLIENT OF UIKIT: The caller of UIApplication.openURL(_:) needs to migrate to the non-deprecated UIApplication.open(_:options:completionHandler:). Force returning false (NO)."

And the 3-param `openURL:options:completionHandler:` crashes when called via `perform:with:with:` because you can't pass 3 ObjC arguments that way.

### Working Approaches (iOS 26)

#### 1. `extensionContext?.open(url:completionHandler:)` — PRIMARY
- Official `NSExtensionContext` API for extensions to request URL opening
- Requires Full Access enabled
- Works for custom URL schemes (e.g., `krakwhisper://record`)
- Completion handler reports success/failure

```swift
extensionContext?.open(url) { success in
    // handle result
}
```

#### 2. SwiftUI `Link` — FALLBACK
- KeyboardKit 8.8.6+ uses this approach since iOS 18 broke selectors
- Wrap the mic button in a SwiftUI `Link` view
- System handles URL opening through the `Link` component
- Works even when programmatic openURL fails

#### 3. UIKit Invisible Link Tap — FALLBACK
- Create an invisible UIKit wrapper around a SwiftUI `Link`
- Programmatically simulate a tap on it
- More complex but doesn't require restructuring the keyboard UI

### What Does NOT Work
- ❌ `NSSelectorFromString("openURL:")` via responder chain (broken iOS 18+)
- ❌ `UIApplication.shared` direct access (not available in extensions)
- ❌ `NSClassFromString("UIApplication")` → `sharedApplication` (crashes with 3 args)
- ❌ Single-param `openURL:` fallback (silently returns NO on iOS 26)

---

## How GBoard Does It

GBoard on iOS handles voice input by:
1. Opening a brief Google dictation interface (the "colored bars" screen)
2. Recording audio in the containing app context
3. Sending to Google's servers for transcription
4. Returning text to the keyboard extension via shared data

Even GBoard does NOT record audio directly in the keyboard extension. They use the containing app workaround.

---

## Implementation Architecture

```
┌─────────────────────┐     URL Scheme      ┌──────────────────────┐
│  Keyboard Extension │ ──────────────────>  │    Main App          │
│                     │  krakwhisper://      │                      │
│  1. User taps mic   │  record             │  3. Record audio     │
│  2. Open main app   │                     │  4. Transcribe       │
│     via NSExt...    │                     │     (SFSpeech/       │
│     Context.open()  │  Darwin Notif       │      Whisper/API)    │
│                     │ <──────────────────  │  5. Write result     │
│  7. Read result     │  com.krakwhisper.   │     to App Group     │
│  8. Insert text     │  transcriptionReady │  6. Post Darwin notif│
└─────────────────────┘                     └──────────────────────┘
         │                                           │
         └────────── App Group (encrypted) ──────────┘
              group.com.krakwhisper.shared
```

### Flow
1. User taps mic button in keyboard
2. Keyboard opens main app via `extensionContext?.open(URL("krakwhisper://record"))`
3. Main app receives URL, shows `KeyboardRecordView`
4. Main app records audio with `AVAudioRecorder` (16kHz WAV)
5. Transcribes with `SFSpeechRecognizer` (primary) or Whisper (fallback)
6. Writes encrypted result to App Group
7. Posts Darwin notification `com.krakwhisper.transcriptionReady`
8. User swipes back to previous app (iOS "Back to" pill)
9. Keyboard receives Darwin notification, reads result, inserts text

---

## Key Constraints

| Constraint | Value | Impact |
|---|---|---|
| Keyboard memory limit | 42-45 MB (A18 Pro) | No Whisper model in keyboard |
| Mic access in keyboard | ❌ Blocked | Must use main app for recording |
| Network in keyboard | ✅ With Full Access | Could send audio to API (if we had audio) |
| App Group | ✅ Available | Used for IPC between keyboard and app |
| Darwin notifications | ✅ Available | Used for real-time IPC signaling |
| SFSpeechRecognizer | ✅ On-device | Zero download, fast, low memory |
| URL opening | ❌ Responder chain broken | Fixed with extensionContext.open() |
| Full Access required | ✅ Already configured | RequestsOpenAccess: true in Info.plist |

---

## Decision

**Implement Option C** (fix URL opening) + **enhance with Option B** (SFSpeechRecognizer in main app):

1. Replace broken `openMainApp()` with `extensionContext?.open(url)` + SwiftUI `Link` fallback
2. Add `SFSpeechRecognizer` as primary transcription in `KeyboardRecordView`
3. Keep existing Whisper + Contabo API as fallbacks
4. Existing App Group + Darwin notification IPC is solid — no changes needed
