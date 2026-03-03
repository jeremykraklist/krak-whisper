# KrakWhisper — Windows (Electron)

Local voice dictation for Windows using [whisper.cpp](https://github.com/ggerganov/whisper.cpp). Zero API calls, zero subscriptions, full privacy.

## Features

- **System tray app** with microphone icon — stays out of your way
- **Global hotkey** (Ctrl+Shift+W) to toggle recording from anywhere
- **whisper.cpp** for fast, local transcription — no internet needed
- **Auto-paste** transcribed text at cursor position (clipboard + Ctrl+V)
- **Model management** — download tiny, base, small, or medium models
- **Customizable settings** — model selection, hotkey, notification preferences
- **Installable .exe** via electron-builder (NSIS installer)

## Prerequisites

1. **Node.js 18+** — [Download](https://nodejs.org/)
2. **whisper.cpp binaries** — Pre-built at `C:\Users\jerem\Projects\whisper.cpp\build\bin\`
   - Required: `whisper-cli.exe`, `whisper.dll`, `ggml-cpu.dll`
   - Run `scripts/setup-bin.ps1` to copy them to `electron/bin/`
3. **FFmpeg** — [Download](https://ffmpeg.org/) and add to PATH (for audio recording)

## Getting Started

```powershell
# Copy whisper.cpp binaries to bin/
powershell -File scripts/setup-bin.ps1

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
│   ├── main.js              # Electron main process — tray, hotkeys, IPC, auto-paste
│   ├── preload.js            # Context bridge for secure renderer ↔ main comms
│   ├── audio-recorder.js     # Audio recording via ffmpeg/PowerShell
│   ├── whisper-engine.js     # whisper-cli.exe wrapper (--no-gpu, -t 8)
│   ├── model-manager.js      # Model download from CDN & management
│   └── renderer/
│       ├── index.html         # Main window UI
│       ├── settings.html      # Settings window UI
│       ├── styles.css         # Shared styles (dark theme)
│       ├── renderer.js        # Main window logic
│       └── settings-renderer.js # Settings window logic
├── assets/
│   ├── tray-icon.png          # System tray icon (idle)
│   └── tray-icon-recording.png # System tray icon (recording)
├── bin/                       # whisper.cpp binaries (not in git)
│   ├── whisper-cli.exe
│   ├── whisper.dll
│   └── ggml-cpu.dll
├── scripts/
│   └── setup-bin.ps1          # Copy whisper binaries from build dir
└── package.json
```

## How It Works

1. **Press Ctrl+Shift+W** (or click tray icon) to start recording
2. Audio is captured via ffmpeg as 16kHz mono WAV
3. **whisper-cli.exe** processes the WAV file locally using the selected model
4. Transcribed text is **auto-copied to clipboard** and **auto-pasted** at cursor position
5. A notification pops up with the transcription (optional)

## Models

Models are downloaded from CDN on first launch:

| Model | Size | Speed | Accuracy |
|-------|------|-------|----------|
| tiny.en | ~75 MB | ⚡ Fastest | Good for short phrases |
| base.en | ~142 MB | 🔵 Fast | Good balance |
| **small.en** | **~466 MB** | **🟡 Medium** | **Best balance (default)** |
| medium.en | ~1.5 GB | 🔴 Slower | Highest accuracy |

CDN: `https://new.jeremiahkrakowski.com/models/ggml-{model}.en.bin`

Models are stored in `%APPDATA%/krakwhisper-windows/models/`.

## Building

```powershell
# Windows NSIS installer
npm run build:nsis

# Windows portable executable
npm run build:portable
```

Output goes to `electron/dist/`.

## Whisper CLI Usage

```bash
whisper-cli.exe -m <model.bin> -f <audio.wav> --no-gpu -t 8
```

- Reads 16kHz mono PCM WAV files
- `--no-gpu` for CPU-only mode (CUDA driver mismatch on current hardware)
- `-t 8` for 8 threads

## License

MIT
