# KrakWhisper for Windows

Electron-based voice dictation app powered by [whisper.cpp](https://github.com/ggerganov/whisper.cpp). Local processing only — no cloud APIs, no subscriptions, full privacy.

## Features

- **System tray app** — lives in your taskbar, out of the way
- **Global hotkey** — `Ctrl+Shift+Space` to toggle recording (customizable)
- **Local transcription** — whisper.cpp runs entirely on your machine
- **Auto clipboard** — transcribed text is automatically copied
- **Multiple models** — choose tiny (fast) to small (accurate)
- **Model manager** — download/delete models from the settings UI

## Quick Start

```bash
# Install dependencies
npm install

# Run in development mode
npm run dev

# Build Windows installer
npm run build
```

## First Launch

1. KrakWhisper will open the Settings window on first launch
2. Download at least one model (recommended: **Base** for best balance)
3. Close the settings window — KrakWhisper runs in the system tray
4. Press `Ctrl+Shift+Space` to start/stop recording
5. Transcribed text is automatically copied to your clipboard

## Models

| Model | Size | Speed | Accuracy | Best For |
|-------|------|-------|----------|----------|
| Tiny | ~75 MB | ⚡⚡⚡ | ★★ | Quick notes, drafts |
| Base | ~142 MB | ⚡⚡ | ★★★ | General use (recommended) |
| Small | ~466 MB | ⚡ | ★★★★ | Detailed transcription |

English-only variants (`.en`) are also available for better English accuracy.

Models are downloaded from [HuggingFace](https://huggingface.co/ggerganov/whisper.cpp) and stored locally.

## Requirements

- Windows 10/11 (x64)
- Microphone
- ~200 MB disk space (app + base model)
- [whisper.cpp binary](https://github.com/ggerganov/whisper.cpp/releases) (downloaded automatically or placed in app data)

## Architecture

```text
electron/
├── src/
│   ├── main/           # Electron main process
│   │   ├── index.js    # App entry, IPC, lifecycle
│   │   ├── tray.js     # System tray management
│   │   ├── recorder.js # Audio recording (mic → WAV)
│   │   ├── whisper-service.js  # whisper.cpp integration
│   │   ├── model-manager.js    # Model download/management
│   │   └── settings.js         # Persistent settings (electron-store)
│   ├── preload/
│   │   └── index.js    # contextBridge API for renderer
│   └── renderer/
│       ├── index.html  # Settings UI
│       ├── styles.css  # Dark theme styles
│       └── renderer.js # UI logic
├── assets/             # Icons and resources
└── package.json        # Dependencies and build config
```

## Development

```bash
# Run with DevTools
npm run dev

# Build portable (no installer, for testing)
npm run build:dir

# Build NSIS installer
npm run build
```

## Tech Stack

- **Electron** v29 — cross-platform desktop framework
- **whisper.cpp** — C/C++ port of OpenAI's Whisper model
- **electron-builder** — packaging and distribution (NSIS installer)
- **electron-store** — persistent settings storage
- **electron-log** — structured logging

## License

MIT
