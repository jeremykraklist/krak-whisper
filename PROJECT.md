# PROJECT.md — KrakWhisper

## Quick Start
- **Stack:** Swift + SwiftUI (iOS), Electron + Node.js (Windows), whisper.cpp (core engine)
- **Build (iOS):** `xcodebuild -project KrakWhisperApp.xcodeproj -scheme KrakWhisper -destination 'platform=iOS Simulator,name=iPhone 17 Pro'`
- **Build (Windows):** `cd electron && npm run build`
- **Test:** Build in simulator, run on device via TestFlight
- **Deploy iOS:** `build-testflight.sh` on MBA (100.99.168.22) — archives + uploads to App Store Connect

## What Is This?
Cross-platform local speech-to-text app. Replaces Whisper Flow subscription ($8/mo). Runs OpenAI's Whisper model entirely on-device — zero API calls, zero subscriptions, full privacy.

## Architecture
```
┌─────────────────────────────────┐
│         KrakWhisper App         │
├──────────┬──────────┬───────────┤
│  iOS UI  │ macOS UI │ Windows UI│
│(SwiftUI) │(SwiftUI) │(Electron) │
├──────────┴──────────┴───────────┤
│      Shared Whisper Engine      │
│   (whisper.cpp via SwiftWhisper)│
├─────────────────────────────────┤
│   Audio Capture (platform API)  │
└─────────────────────────────────┘
```

**Key iOS components:**
- **SwiftWhisper:** SPM package wrapping whisper.cpp C library
- **AudioCaptureService:** AVAudioEngine mic recording → WAV
- **WhisperTranscriptionService:** Loads GGML model, runs inference
- **ModelDownloadManager:** Downloads models from CDN on first launch
- **RecordingViewModel:** Main state machine for record/transcribe flow
- **KrakWhisperKeyboard:** App extension for system-wide voice dictation

## Phases
| Phase | Scope | Status |
|-------|-------|--------|
| Phase 1 | iOS MVP — record + transcribe + model download | ✅ Complete |
| Phase 2 | iOS polish — keyboard, AI cleanup, share, tags | 🔨 In progress |
| Phase 3 | On-device LLM (Qwen 3.5 2B) for text cleanup | 🔲 Not started |
| Phase 4 | Windows Electron port with CUDA | 🔲 Building env |
| Phase 5 | macOS menu bar app with global hotkey | 🔲 Not started |

## Phase 2 Issues (Current Sprint)
| Issue | Title | Status |
|-------|-------|--------|
| #19 | Keyboard Extension — system-wide dictation | ⚠️ Compiles but model loading broken (needs App Group) |
| #22 | Tags, titles, organization | 🔲 Not dispatched |
| #23 | Fastlane automated build | ✅ Done (shell script, not Fastlane) |
| #26 | On-device LLM with Qwen 3.5 2B | 🔲 Phase 3 |

## What's Deployed
- **TestFlight:** Latest build uploaded 2026-03-03 with:
  - Model selection fix (remembers Medium vs Base)
  - Share sheet + clipboard integration
  - AI text cleanup (filler word removal via NLP)
  - Keyboard extension (compiles, model not yet shared)
  - App icon (teal microphone)
  - Medium model support (1.5GB CDN download)

## Build Infrastructure
- **Build server:** MacBook Air at `jeremiahkrakowski@100.99.168.22`
- **Code repo (agents):** `/Users/clawdfamily/clawd-dev-team/projects/krak-whisper/` (Mac Mini)
- **Code repo (MBA):** `~/Projects/krak-whisper/` (synced via rsync)
- **Keychain unlock required:** `security unlock-keychain -p <pw> && security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k <pw>`
- **Team ID:** J4F36L43U9
- **Bundle ID:** com.jeremykrakowski.krakwhisper
- **CDN models:** `https://new.jeremiahkrakowski.com/models/ggml-{tiny,base,small,medium}.en.bin`

## Known Issues
1. Keyboard extension can't load Whisper model — needs App Group entitlement + model copy to shared container
2. `AICleanupService.swift` and `ClipboardService.swift` exist on disk but aren't in xcodeproj — inlined as workaround
3. `PROJECT.md` phases were out of date (fixed 2026-03-03)

## GitHub
- Repo: jeremykraklist/krak-whisper
- Project Board: #3 (https://github.com/users/jeremykraklist/projects/3)
- Slack: #software-dev-ops (C0AELU4T8JW)

## Key Decisions
- whisper.cpp via SwiftWhisper SPM package (not Python whisper)
- Local-only processing (no cloud APIs)
- Self-hosted models on Contabo CDN (HuggingFace redirects break URLSession)
- Separate .xcodeproj from Package.swift (Package.swift includes macOS targets that cause errors)
- Shell script (`build-testflight.sh`) over Fastlane for TestFlight deployment
- NLP-based cleanup first, Qwen 3.5 2B replaces it later (Phase 3)
- **Keyboard IPC (iOS 26):** Replaced broken `openMainApp()` responder-chain hack with `extensionContext?.open(url)` (primary) + SwiftUI `Link` fallback for URL opening. `SFSpeechRecognizer` is the primary transcription engine in `KeyboardRecordView` (on-device, zero model download), with on-device Whisper + Contabo API as fallbacks. App Group + Darwin notification IPC retained for state sharing between keyboard extension and main app. See `docs/keyboard-ipc-research.md`. (PR #47, Issue #42)
