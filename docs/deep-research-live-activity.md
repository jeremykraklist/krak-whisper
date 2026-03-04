# Deep Research Prompt: iOS Live Activity Widget for Voice Recording

Copy this into Gemini Deep Research, ChatGPT Deep Research, or Claude:

---

## Research Question

How can an iOS app implement a **Live Activity (Dynamic Island + Lock Screen widget)** that allows users to **start and stop audio recording from anywhere on the device** — without opening the full app?

I'm building a voice-to-text app similar to **Whisper Flow** (whisperflow.com). The app uses on-device Whisper for transcription. I need the user to be able to:

1. Start a voice recording from the **Lock Screen widget** or **Dynamic Island** without opening the full app
2. See a **recording timer** in the Dynamic Island while recording
3. **Stop recording** by tapping the Dynamic Island or Lock Screen widget
4. Have the app **transcribe in the background** and deliver the result (via clipboard, notification, or keyboard auto-insert)

## Specific Technical Questions

1. **Can a Live Activity start an audio recording in the background?** What APIs are involved? Does the app need to be running in the background already, or can ActivityKit wake it?

2. **What background modes are required?** I already have `audio` and `processing` in UIBackgroundModes. What else?

3. **How does the interaction work?** When the user taps a "Record" button on the Live Activity, what happens technically? Does it:
   - Send a deep link to the app?
   - Use App Intents?
   - Use a button action that triggers background work?

4. **Can the Live Activity have interactive buttons?** iOS 16.1+ Live Activities are non-interactive, but iOS 17+ added interactive buttons. What's the current state on iOS 18/26?

5. **How does Whisper Flow do it?** Based on any available information, reverse engineering, or documentation — how does Whisper Flow implement their "record from anywhere" feature? Do they use Live Activities, Control Center widgets, or something else?

6. **Control Center widget alternative:** iOS 18 introduced customizable Control Center. Can I add a "Record" toggle there? How does that interact with background audio recording?

7. **App Intents + Shortcuts:** Can I create a Siri Shortcut that starts background recording without opening the app UI? What about `ForegroundContinuableIntent` vs regular `AppIntent`?

8. **Keyboard extension integration:** I have a custom keyboard extension. Can the keyboard trigger a Live Activity that then controls recording? Or is there a way for the keyboard to communicate with an always-running Live Activity?

## Context

- **Platform:** iOS 17+ (targeting iOS 18/26)
- **Device:** iPhone 17 Pro Max with Dynamic Island
- **Audio:** Using AVAudioRecorder with 16kHz mono PCM
- **Transcription:** On-device Whisper (SwiftWhisper library)
- **IPC:** Darwin notifications + App Group file sharing between keyboard extension and main app
- **Current state:** We have a working keyboard extension that types + a mic button. The mic button currently opens the main app for recording because keyboard extensions can't access the microphone. We want to eliminate the app switch entirely.

## What I Need

1. **Architecture diagram** of how Live Activities + background recording should be wired together
2. **Code examples** (Swift/SwiftUI) for:
   - Setting up the Live Activity with interactive Record/Stop buttons
   - Starting background audio recording when the Live Activity button is tapped
   - Updating the Live Activity with recording duration
   - Ending the Live Activity when transcription is complete
3. **Known limitations** and gotchas (battery, Apple review, iOS restrictions)
4. **Alternative approaches** if Live Activities can't trigger background recording (Control Center, Shortcuts, etc.)
5. **Real-world examples** of apps that successfully do background recording triggered from widgets/Live Activities

## Priority

Focus on **what actually works in production** (App Store approved), not theoretical possibilities. I need practical, implementable solutions with code.

---
