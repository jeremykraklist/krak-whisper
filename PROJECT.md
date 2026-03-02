# PROJECT.md — KrakWhisper

## Quick Start
- **Stack:** Swift + SwiftUI (macOS/iOS), Electron + Node.js (Windows), whisper.cpp (core engine)
- **Build (macOS):** `swift build` or Xcode
- **Build (Windows):** `cd electron && npm run build`
- **Test:** `swift test` (macOS), `npm test` (Windows)
- **Deploy:** App Store (iOS/macOS), GitHub Releases (Windows)

## What Is This?
Cross-platform local speech-to-text app. Replaces Whisper Flow subscription. Runs OpenAI's Whisper model entirely on-device — zero API calls, zero subscriptions, full privacy.

## Architecture
```
┌─────────────────────────────────┐
│         KrakWhisper App         │
├──────────┬──────────┬───────────┤
│ macOS UI │  iOS UI  │ Windows UI│
│ (SwiftUI)│(SwiftUI) │(Electron) │
├──────────┴──────────┴───────────┤
│      Shared Whisper Engine      │
│      (whisper.cpp via C FFI)    │
├─────────────────────────────────┤
│   Audio Capture (platform API)  │
└─────────────────────────────────┘
```

**Key components:**
- **WhisperEngine:** C bridge to whisper.cpp, handles model loading + inference
- **AudioCapture:** Platform-native mic recording (AVAudioEngine on Apple, Web Audio on Electron)
- **TranscriptionView:** Main UI — live text display, start/stop, model picker
- **GlobalHotkey:** System-wide keyboard shortcut to toggle recording

## Phases
| Phase | Scope | Status |
|-------|-------|--------|
| Phase 1 | macOS MVP — hotkey + transcribe + clipboard | 🔲 Not started |
| Phase 2 | iOS companion app (shared engine) | 🔲 Not started |
| Phase 3 | Windows Electron port | 🔲 Not started |
| Phase 4 | Polish — settings, auto-update, model downloads | 🔲 Not started |

## Active Work
- Current sprint: Phase 1 — macOS MVP
- Assigned agents: (pending dispatch)
- Key branches: (pending)

## GitHub
- Repo: jeremykraklist/krak-whisper
- Project Board: #3 (https://github.com/users/jeremykraklist/projects/3)
- Slack: #software-dev-ops (C0AELU4T8JW)

## Key Decisions
- whisper.cpp as engine (not Python whisper — too slow, needs Python runtime)
- Local-only processing (no cloud APIs)
- Swift Package Manager for Apple platforms
- Electron for Windows (vs native Win32) — faster dev, good enough perf
- Model files downloaded on first launch (not bundled — too large)
