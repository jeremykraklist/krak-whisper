# KrakWhisper — Windows (Electron)

Local voice dictation for Windows using [whisper.cpp](https://github.com/ggerganov/whisper.cpp). Zero API calls, zero subscriptions, full privacy.

## Features

- **System tray app** with microphone icon — stays out of your way
- **Global hotkey** (Ctrl+Shift+Space) to toggle recording from anywhere
- **whisper.cpp** for fast, local transcription — no internet needed
- **Auto-copy** transcribed text to clipboard
- **Model management** — download tiny.en, base.en, or small.en models on first launch
- **Customizable settings** — model selection, hotkey, notification preferences

## Prerequisites

1. **Node.js 18+** — [Download](https://nodejs.org/)
2. **whisper.cpp binary** — Place the compiled `whisper-cpp.exe` in `electron/bin/`
   - Build from source: https://github.com/ggerganov/whisper.cpp#build
   - Or download a pre-built release
3. **Audio recording tool** (one of):
   - [FFmpeg](https://ffmpeg.org/) (recommended) — add to PATH
   - [SoX](https://sox.sourceforge.net/) — add to PATH

## Getting Started

```bash
# Install dependencies
cd electron
npm install

# Run in development
npm start

# Build Windows installer
npm run build
```

## Architecture

```
electron/
├── src/
│   ├── main.js              # Electron main process — tray, hotkeys, IPC
│   ├── preload.js            # Context bridge for secure renderer ↔ main comms
│   ├── audio-recorder.js     # Platform audio recording (ffmpeg/sox/PowerShell)
│   ├── whisper-engine.js     # whisper.cpp CLI wrapper
│   ├── model-manager.js      # Model download & management
│   └── renderer/
│       ├── index.html         # Main window UI
│       ├── settings.html      # Settings window UI
│       ├── styles.css         # Shared styles
│       ├── renderer.js        # Main window logic
│       └── settings-renderer.js # Settings window logic
├── assets/
│   ├── tray-icon.png          # System tray icon (idle)
│   └── tray-icon-recording.png # System tray icon (recording)
├── bin/
│   └── .gitkeep               # Place whisper-cpp.exe here
└── package.json
```

## How It Works

1. **Press hotkey** (Ctrl+Shift+Space) or click tray icon to start recording
2. Audio is captured via ffmpeg/sox and saved as 16kHz mono WAV
3. **whisper.cpp** processes the WAV file locally using the selected model
4. Transcribed text is **auto-copied to clipboard** and shown in the app window
5. A notification pops up with the transcription (optional)

## Models

Models are downloaded from HuggingFace on first launch:

| Model | Size | Speed | Accuracy |
|-------|------|-------|----------|
| tiny.en | ~75 MB | ⚡ Fastest | Good for short phrases |
| base.en | ~142 MB | 🔵 Fast | Good balance |
| small.en | ~466 MB | 🟡 Medium | Best accuracy |

Models are stored in `%APPDATA%/krakwhisper-windows/models/`.

## Building

```bash
# Windows NSIS installer
npm run build:nsis

# Windows portable executable
npm run build:portable
```

Output goes to `electron/dist/`.

## License

MIT
