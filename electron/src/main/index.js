'use strict';

const { app, BrowserWindow, globalShortcut, ipcMain, clipboard, dialog } = require('electron');
const path = require('path');
const log = require('electron-log');
const { TrayManager } = require('./tray');
const { Recorder } = require('./recorder');
const { WhisperService } = require('./whisper-service');
const { ModelManager } = require('./model-manager');
const { SettingsManager } = require('./settings');

// Prevent multiple instances
const gotTheLock = app.requestSingleInstanceLock();
if (!gotTheLock) {
  app.quit();
}

log.initialize({ preload: true });
log.info('KrakWhisper starting...');

/** @type {BrowserWindow | null} */
let settingsWindow = null;

/** @type {TrayManager | null} */
let trayManager = null;

/** @type {Recorder | null} */
let recorder = null;

/** @type {WhisperService | null} */
let whisperService = null;

/** @type {ModelManager | null} */
let modelManager = null;

/** @type {SettingsManager | null} */
let settings = null;

/** @type {boolean} */
let isRecording = false;

function getAssetPath(filename) {
  if (app.isPackaged) {
    return path.join(process.resourcesPath, 'assets', filename);
  }
  return path.join(__dirname, '..', '..', 'assets', filename);
}

function createSettingsWindow() {
  if (settingsWindow) {
    settingsWindow.focus();
    return;
  }

  settingsWindow = new BrowserWindow({
    width: 500,
    height: 600,
    resizable: false,
    maximizable: false,
    minimizable: false,
    fullscreenable: false,
    title: 'KrakWhisper Settings',
    icon: getAssetPath('icon.png'),
    webPreferences: {
      preload: path.join(__dirname, '..', 'preload', 'index.js'),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: false,
    },
  });

  settingsWindow.loadFile(path.join(__dirname, '..', 'renderer', 'index.html'));
  settingsWindow.setMenuBarVisibility(false);

  settingsWindow.on('closed', () => {
    settingsWindow = null;
  });
}

async function toggleRecording() {
  if (!whisperService) {
    log.error('WhisperService not initialized');
    return;
  }

  if (isRecording) {
    // Stop recording
    isRecording = false;
    trayManager?.setRecording(false);
    log.info('Stopping recording...');

    try {
      const audioPath = await recorder.stop();
      log.info(`Audio saved to: ${audioPath}`);

      // Transcribe
      trayManager?.setTranscribing(true);
      const text = await whisperService.transcribe(audioPath);
      trayManager?.setTranscribing(false);

      if (text && text.trim()) {
        const normalizedText = text.trim();
        if (settings.get('autoClipboard', true)) {
          clipboard.writeText(normalizedText);
          log.info(`Transcription copied to clipboard (${normalizedText.length} chars)`);
        } else {
          log.info(`Transcription completed (${normalizedText.length} chars)`);
        }

        // Notify renderer if settings window is open
        if (settingsWindow) {
          settingsWindow.webContents.send('transcription-result', normalizedText);
        }
      } else {
        log.warn('Empty transcription result');
      }
    } catch (err) {
      log.error('Transcription failed:', err.message);
      trayManager?.setTranscribing(false);
    }
  } else {
    // Start recording
    const currentModel = settings.get('model', 'base');

    if (!modelManager.isModelDownloaded(currentModel)) {
      log.warn(`Model "${currentModel}" not downloaded yet`);
      dialog.showMessageBox({
        type: 'warning',
        title: 'Model Not Ready',
        message: `The "${currentModel}" model hasn't been downloaded yet. Please open Settings and download a model first.`,
        buttons: ['Open Settings', 'OK'],
      }).then(({ response }) => {
        if (response === 0) createSettingsWindow();
      });
      return;
    }

    const modelPath = modelManager.getModelPath(currentModel);
    whisperService.setModelPath(modelPath);
    isRecording = true;
    trayManager?.setRecording(true);
    log.info('Starting recording...');

    try {
      await recorder.start();
    } catch (err) {
      log.error('Failed to start recording:', err.message);
      isRecording = false;
      trayManager?.setRecording(false);
    }
  }
}

function registerHotkey() {
  const hotkey = settings.get('hotkey', 'Ctrl+Shift+Space');

  // Unregister all first
  globalShortcut.unregisterAll();

  const registered = globalShortcut.register(hotkey, () => {
    log.info(`Hotkey "${hotkey}" pressed`);
    toggleRecording();
  });

  if (registered) {
    log.info(`Global hotkey registered: ${hotkey}`);
  } else {
    log.error(`Failed to register hotkey: ${hotkey}`);
  }
}

function setupIPC() {
  ipcMain.handle('get-settings', () => {
    return settings.getAll();
  });

  ipcMain.handle('set-setting', (_event, key, value) => {
    settings.set(key, value);

    if (key === 'hotkey') {
      registerHotkey();
    }

    return true;
  });

  ipcMain.handle('get-models', () => {
    return modelManager.getAvailableModels();
  });

  ipcMain.handle('download-model', async (_event, modelName) => {
    try {
      await modelManager.downloadModel(modelName, (progress) => {
        if (settingsWindow) {
          settingsWindow.webContents.send('download-progress', { modelName, progress });
        }
      });
      return { success: true };
    } catch (err) {
      log.error(`Model download failed: ${err.message}`);
      return { success: false, error: err.message };
    }
  });

  ipcMain.handle('delete-model', async (_event, modelName) => {
    try {
      await modelManager.deleteModel(modelName);
      return { success: true };
    } catch (err) {
      return { success: false, error: err.message };
    }
  });

  ipcMain.handle('get-recording-state', () => {
    return isRecording;
  });

  ipcMain.handle('toggle-recording', () => {
    toggleRecording();
  });
}

app.on('ready', async () => {
  log.info('App ready');

  // Hide dock icon on macOS (tray-only app)
  if (process.platform === 'darwin') {
    app.dock.hide();
  }

  // Initialize settings
  settings = new SettingsManager();

  // Initialize model manager
  modelManager = new ModelManager(app.getPath('userData'));

  // Initialize whisper service
  whisperService = new WhisperService(app.getPath('userData'));

  // Initialize recorder
  recorder = new Recorder(app.getPath('temp'));

  // Create tray
  trayManager = new TrayManager({
    onToggleRecording: () => toggleRecording(),
    onOpenSettings: () => createSettingsWindow(),
    onQuit: () => app.quit(),
    getAssetPath,
  });

  // Register hotkey
  registerHotkey();

  // Setup IPC handlers
  setupIPC();

  // Check if any model is downloaded, if not show settings
  const models = modelManager.getAvailableModels();
  const hasAnyModel = models.some((m) => m.downloaded);
  if (!hasAnyModel) {
    log.info('No models found, opening settings for first-time setup');
    createSettingsWindow();
  }

  log.info('KrakWhisper initialized successfully');
});

app.on('will-quit', () => {
  globalShortcut.unregisterAll();
  if (isRecording && recorder) {
    recorder.stop().catch(() => {});
  }
});

app.on('window-all-closed', () => {
  // Don't quit — we're a tray app
});

// Handle second instance
app.on('second-instance', () => {
  createSettingsWindow();
});
