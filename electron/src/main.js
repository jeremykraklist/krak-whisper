const { app, BrowserWindow, Tray, Menu, globalShortcut, ipcMain, nativeImage, dialog, clipboard, Notification } = require('electron');
const path = require('path');
const Store = require('electron-store');
const { AudioRecorder } = require('./audio-recorder');
const { WhisperEngine } = require('./whisper-engine');
const { ModelManager } = require('./model-manager');

/** @type {Store} */
const store = new Store({
  defaults: {
    model: 'tiny.en',
    hotkey: 'CommandOrControl+Shift+Space',
    autoCopy: true,
    showNotification: true,
    firstLaunch: true,
  },
});

/** @type {BrowserWindow | null} */
let mainWindow = null;
/** @type {BrowserWindow | null} */
let settingsWindow = null;
/** @type {Tray | null} */
let tray = null;
/** @type {AudioRecorder} */
let recorder;
/** @type {WhisperEngine} */
let whisperEngine;
/** @type {ModelManager} */
let modelManager;
/** @type {boolean} */
let isRecording = false;
/** @type {boolean} */
let toggleInFlight = false;

// ─── Single instance lock ────────────────────────────────────────────
const gotLock = app.requestSingleInstanceLock();
if (!gotLock) {
  app.quit();
}

app.on('second-instance', () => {
  if (mainWindow) {
    if (mainWindow.isMinimized()) mainWindow.restore();
    mainWindow.focus();
  }
});

// ─── App lifecycle ───────────────────────────────────────────────────
app.whenReady().then(async () => {
  recorder = new AudioRecorder();
  modelManager = new ModelManager();
  whisperEngine = new WhisperEngine(modelManager);

  createTray();
  registerHotkey();

  // Check if first launch — trigger model download
  if (store.get('firstLaunch')) {
    store.set('firstLaunch', false);
    createMainWindow();
    sendToMainWindow('show-setup');
  }
});

app.on('window-all-closed', (e) => {
  // Don't quit — we live in the tray
  e.preventDefault?.();
});

app.on('will-quit', () => {
  globalShortcut.unregisterAll();
});

// ─── Tray ────────────────────────────────────────────────────────────
function createTray() {
  const iconPath = path.join(__dirname, '..', 'assets', 'tray-icon.png');
  const icon = nativeImage.createFromPath(iconPath).resize({ width: 16, height: 16 });
  tray = new Tray(icon);
  tray.setToolTip('KrakWhisper — Click to toggle recording');
  updateTrayMenu();

  tray.on('click', () => {
    toggleRecording();
  });
}

function updateTrayMenu() {
  const hotkey = store.get('hotkey');
  const contextMenu = Menu.buildFromTemplate([
    {
      label: isRecording ? '⏹ Stop Recording' : '🎙 Start Recording',
      click: () => toggleRecording(),
    },
    { type: 'separator' },
    {
      label: `Model: ${store.get('model')}`,
      enabled: false,
    },
    {
      label: `Hotkey: ${hotkey}`,
      enabled: false,
    },
    { type: 'separator' },
    {
      label: 'Open KrakWhisper',
      click: () => createMainWindow(),
    },
    {
      label: 'Settings',
      click: () => createSettingsWindow(),
    },
    {
      label: 'Download Models',
      click: () => {
        createMainWindow();
        sendToMainWindow('show-setup');
      },
    },
    { type: 'separator' },
    {
      label: 'Quit KrakWhisper',
      click: () => {
        app.quit();
      },
    },
  ]);
  tray.setContextMenu(contextMenu);
}

// ─── Windows ─────────────────────────────────────────────────────────

/**
 * Safely send a message to the main window, handling the race where
 * the page may or may not have finished loading yet.
 * @param {string} channel
 * @param {*} [data]
 */
function sendToMainWindow(channel, data) {
  if (!mainWindow) return;
  const wc = mainWindow.webContents;

  if (wc.isLoading()) {
    wc.once('did-finish-load', () => {
      if (mainWindow) {
        mainWindow.webContents.send(channel, data);
      }
    });
  } else {
    wc.send(channel, data);
  }
}

function createMainWindow() {
  if (mainWindow) {
    mainWindow.focus();
    return;
  }

  mainWindow = new BrowserWindow({
    width: 480,
    height: 600,
    resizable: true,
    title: 'KrakWhisper',
    webPreferences: {
      preload: path.join(__dirname, 'preload.js'),
      contextIsolation: true,
      nodeIntegration: false,
    },
  });

  mainWindow.loadFile(path.join(__dirname, '..', 'src', 'renderer', 'index.html'));

  mainWindow.on('closed', () => {
    mainWindow = null;
  });
}

function createSettingsWindow() {
  if (settingsWindow) {
    settingsWindow.focus();
    return;
  }

  settingsWindow = new BrowserWindow({
    width: 420,
    height: 500,
    resizable: false,
    title: 'KrakWhisper Settings',
    webPreferences: {
      preload: path.join(__dirname, 'preload.js'),
      contextIsolation: true,
      nodeIntegration: false,
    },
  });

  settingsWindow.loadFile(path.join(__dirname, '..', 'src', 'renderer', 'settings.html'));

  settingsWindow.on('closed', () => {
    settingsWindow = null;
  });
}

// ─── Recording ───────────────────────────────────────────────────────
async function toggleRecording() {
  if (toggleInFlight) return;
  toggleInFlight = true;

  try {
    if (isRecording) {
      await stopRecording();
    } else {
      await startRecording();
    }
  } finally {
    toggleInFlight = false;
  }
}

async function startRecording() {
  const modelName = store.get('model');
  const modelReady = await modelManager.isModelDownloaded(modelName);
  if (!modelReady) {
    createMainWindow();
    sendToMainWindow('show-setup');
    sendToMainWindow('error', `Model "${modelName}" not downloaded. Please download it first.`);
    return;
  }

  isRecording = true;
  updateTrayMenu();
  updateTrayIcon(true);
  broadcastState();

  try {
    await recorder.start();
  } catch (err) {
    isRecording = false;
    updateTrayMenu();
    updateTrayIcon(false);
    broadcastState();
    dialog.showErrorBox('Recording Error', `Failed to start recording: ${err.message}`);
  }
}

async function stopRecording() {
  isRecording = false;
  updateTrayMenu();
  updateTrayIcon(false);
  broadcastState();

  try {
    const audioBuffer = await recorder.stop();
    if (!audioBuffer || audioBuffer.length === 0) {
      broadcastResult('(No audio captured)');
      return;
    }

    broadcastStatus('Transcribing...');

    const modelName = store.get('model');
    const text = await whisperEngine.transcribe(audioBuffer, modelName);

    if (text && text.trim()) {
      const trimmed = text.trim();
      if (store.get('autoCopy')) {
        clipboard.writeText(trimmed);
      }
      broadcastResult(trimmed);

      if (store.get('showNotification')) {
        new Notification({
          title: 'KrakWhisper',
          body: trimmed.length > 100 ? trimmed.substring(0, 100) + '...' : trimmed,
        }).show();
      }
    } else {
      broadcastResult('(No speech detected)');
    }
  } catch (err) {
    broadcastResult(`Error: ${err.message}`);
  }
}

function updateTrayIcon(recording) {
  if (!tray) return;
  const iconName = recording ? 'tray-icon-recording.png' : 'tray-icon.png';
  const iconPath = path.join(__dirname, '..', 'assets', iconName);
  const icon = nativeImage.createFromPath(iconPath).resize({ width: 16, height: 16 });
  tray.setImage(icon);
}

function broadcastState() {
  const state = { isRecording, model: store.get('model') };
  if (mainWindow) mainWindow.webContents.send('state-update', state);
}

function broadcastResult(text) {
  if (mainWindow) mainWindow.webContents.send('transcription-result', text);
}

function broadcastStatus(status) {
  if (mainWindow) mainWindow.webContents.send('status-update', status);
}

// ─── Hotkey ──────────────────────────────────────────────────────────

/**
 * Register the global hotkey. Returns true if registration succeeded.
 * @returns {boolean}
 */
function registerHotkey() {
  const hotkey = store.get('hotkey');
  globalShortcut.unregisterAll();
  try {
    const success = globalShortcut.register(hotkey, () => {
      toggleRecording();
    });
    if (!success) {
      console.error(`Failed to register hotkey "${hotkey}" — may be in use by another app.`);
    }
    return success;
  } catch (err) {
    console.error(`Failed to register hotkey "${hotkey}":`, err.message);
    return false;
  }
}

// ─── IPC Handlers ────────────────────────────────────────────────────
ipcMain.handle('get-settings', () => {
  return {
    model: store.get('model'),
    hotkey: store.get('hotkey'),
    autoCopy: store.get('autoCopy'),
    showNotification: store.get('showNotification'),
  };
});

ipcMain.handle('save-settings', (_event, settings) => {
  if (settings.model) store.set('model', settings.model);
  if (typeof settings.autoCopy === 'boolean') store.set('autoCopy', settings.autoCopy);
  if (typeof settings.showNotification === 'boolean') store.set('showNotification', settings.showNotification);

  // Handle hotkey change — validate and report registration result
  if (settings.hotkey) {
    store.set('hotkey', settings.hotkey);
    const registered = registerHotkey();
    if (!registered) {
      return { success: false, error: `Hotkey "${settings.hotkey}" could not be registered. It may be in use by another application.` };
    }
  }

  updateTrayMenu();
  return { success: true };
});

ipcMain.handle('get-state', () => {
  return { isRecording, model: store.get('model') };
});

ipcMain.handle('toggle-recording', () => {
  toggleRecording();
});

ipcMain.handle('get-available-models', () => {
  return modelManager.getAvailableModels();
});

ipcMain.handle('get-downloaded-models', async () => {
  return modelManager.getDownloadedModels();
});

ipcMain.handle('download-model', async (_event, modelName) => {
  try {
    await modelManager.downloadModel(modelName, (progress) => {
      if (mainWindow) {
        mainWindow.webContents.send('download-progress', { model: modelName, progress });
      }
    });
    return { success: true };
  } catch (err) {
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

ipcMain.handle('copy-to-clipboard', (_event, text) => {
  clipboard.writeText(text);
  return { success: true };
});
