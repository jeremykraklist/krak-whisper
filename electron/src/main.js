const { app, BrowserWindow, Tray, Menu, globalShortcut, ipcMain, nativeImage, dialog, clipboard, Notification } = require('electron');
const { execFile } = require('child_process');
const path = require('path');
const Store = require('electron-store');
const { AudioRecorder } = require('./audio-recorder');
const { WhisperEngine } = require('./whisper-engine');
const { ModelManager } = require('./model-manager');
const { ServerManager } = require('./server-manager');
const { StartupManager } = require('./startup-manager');

/** @type {Store} */
const store = new Store({
  defaults: {
    model: 'medium.en',
    hotkey: 'CommandOrControl+Shift+W',
    autoCopy: true,
    autoPaste: true,
    autoCleanup: false,
    showNotification: true,
    launchAtStartup: false,
    firstLaunch: true,
  },
});

/** @type {BrowserWindow | null} */
let mainWindow = null;
/** @type {BrowserWindow | null} */
let settingsWindow = null;
/** @type {BrowserWindow | null} */
let widgetWindow = null;
/** @type {Tray | null} */
let tray = null;
/** @type {AudioRecorder} */
let recorder;
/** @type {WhisperEngine} */
let whisperEngine;
/** @type {ModelManager} */
let modelManager;
/** @type {ServerManager} */
let serverManager;
/** @type {StartupManager} */
let startupManager;
/** @type {boolean} */
let isRecording = false;
/** @type {boolean} */
let toggleInFlight = false;
/** @type {boolean} */
let isQuitting = false;

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
  serverManager = new ServerManager();
  startupManager = new StartupManager();

  // Forward server status changes to settings window and tray
  serverManager.onStatusChange((status) => {
    updateTrayMenu();
    if (settingsWindow && !settingsWindow.isDestroyed()) {
      settingsWindow.webContents.send('server-status', status);
    }
  });

  createTray();
  createWidget();
  registerHotkey();

  // Auto-start servers in background (don't block app launch)
  serverManager.startAll(store).catch((err) => {
    console.error('[main] Server auto-start error:', err.message);
  });

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

app.on('before-quit', async (e) => {
  if (!isQuitting) {
    isQuitting = true;
    e.preventDefault();

    console.log('[main] Graceful shutdown — killing servers...');
    try {
      if (serverManager && typeof serverManager.shutdown === 'function') {
        await serverManager.shutdown();
      }
    } catch (err) {
      console.error('[main] Server shutdown error:', err.message);
    }

    globalShortcut.unregisterAll();
    app.quit();
  }
});

app.on('will-quit', () => {
  globalShortcut.unregisterAll();
});

// ─── Floating Widget ─────────────────────────────────────────────────
function createWidget() {
  const { screen } = require('electron');
  const display = screen.getPrimaryDisplay();
  const savedX = store.get('widgetX', display.workArea.width - 80);
  const savedY = store.get('widgetY', display.workArea.height / 2);

  widgetWindow = new BrowserWindow({
    width: 64,
    height: 96, // Drag handle (16) + widget (56) + duration label (24)
    x: Math.round(savedX),
    y: Math.round(savedY),
    frame: false,
    transparent: true,
    alwaysOnTop: true,
    resizable: false,
    skipTaskbar: true,
    hasShadow: false,
    focusable: false, // CRITICAL: don't steal focus from target app
    webPreferences: {
      nodeIntegration: true,
      contextIsolation: false,
    },
  });

  widgetWindow.loadFile(path.join(__dirname, 'renderer', 'widget.html'));
  widgetWindow.setVisibleOnAllWorkspaces(true);

  // Save position when moved
  widgetWindow.on('moved', () => {
    if (widgetWindow) {
      const [x, y] = widgetWindow.getPosition();
      store.set('widgetX', x);
      store.set('widgetY', y);
    }
  });

  widgetWindow.on('closed', () => {
    widgetWindow = null;
  });
}

// Widget IPC
ipcMain.on('widget-toggle', () => {
  toggleRecording();
});

ipcMain.on('widget-context-menu', () => {
  const contextMenu = Menu.buildFromTemplate([
    { label: `Model: ${store.get('model')}`, enabled: false },
    { type: 'separator' },
    { label: 'Settings', click: () => { createSettingsWindow(); } },
    { label: 'Hide Widget', click: () => { if (widgetWindow) widgetWindow.hide(); } },
    { type: 'separator' },
    { label: 'Quit', click: () => app.quit() },
  ]);
  if (widgetWindow) contextMenu.popup({ window: widgetWindow });
});

// Update widget state when recording state changes
function updateWidget(state) {
  if (widgetWindow && !widgetWindow.isDestroyed()) {
    widgetWindow.webContents.send('widget-state', state);
  }
}

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
  const serverStatus = serverManager ? serverManager.getStatus() : { whisper: { status: 'unknown' }, llama: { status: 'unknown' } };
  const whisperIcon = serverStatus.whisper.status === 'running' ? '🟢' : serverStatus.whisper.status === 'starting' ? '🟡' : '🔴';
  const llamaIcon = serverStatus.llama.status === 'running' ? '🟢' : serverStatus.llama.status === 'starting' ? '🟡' : '⚪';

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
    {
      label: `Auto-paste: ${store.get('autoPaste') ? 'On' : 'Off'}`,
      enabled: false,
    },
    { type: 'separator' },
    {
      label: `${whisperIcon} Whisper Server (${serverStatus.whisper.status})`,
      enabled: false,
    },
    {
      label: `${llamaIcon} Qwen LLM Server (${serverStatus.llama.status})`,
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
      label: 'About KrakWhisper',
      click: () => showAbout(),
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

// ─── About Dialog ────────────────────────────────────────────────────
function showAbout() {
  const serverStatus = serverManager ? serverManager.getStatus() : {};
  const whisperStatus = serverStatus.whisper ? serverStatus.whisper.status : 'unknown';
  const llamaStatus = serverStatus.llama ? serverStatus.llama.status : 'unknown';

  dialog.showMessageBox({
    type: 'info',
    title: 'About KrakWhisper',
    message: 'KrakWhisper',
    detail: [
      `Version: ${app.getVersion()}`,
      `Electron: ${process.versions.electron}`,
      `Node.js: ${process.versions.node}`,
      '',
      `Whisper Server: ${whisperStatus} (port 8178)`,
      `Qwen LLM Server: ${llamaStatus} (port 8179)`,
      '',
      'Local voice dictation powered by whisper.cpp',
      '© 2026 Jeremiah Krakowski',
    ].join('\n'),
    buttons: ['OK'],
  });
}

// ─── Windows ─────────────────────────────────────────────────────────

/**
 * Safely send a message to the main window.
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
    height: 640,
    resizable: true,
    title: 'KrakWhisper',
    icon: path.join(__dirname, '..', 'assets', 'tray-icon.png'),
    webPreferences: {
      preload: path.join(__dirname, 'preload.js'),
      contextIsolation: true,
      nodeIntegration: false,
    },
  });

  mainWindow.loadFile(path.join(__dirname, 'renderer', 'index.html'));

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
    width: 500,
    height: 700,
    resizable: true,
    title: 'KrakWhisper Settings',
    icon: path.join(__dirname, '..', 'assets', 'tray-icon.png'),
    webPreferences: {
      preload: path.join(__dirname, 'preload.js'),
      contextIsolation: true,
      nodeIntegration: false,
    },
  });

  settingsWindow.loadFile(path.join(__dirname, 'renderer', 'settings.html'));

  settingsWindow.on('closed', () => {
    settingsWindow = null;
  });
}

// ─── Auto-paste ──────────────────────────────────────────────────────

/**
 * Simulate Ctrl+V keypress to paste from clipboard at cursor position.
 * Uses PowerShell + System.Windows.Forms.SendKeys on Windows.
 */
function simulatePaste() {
  if (process.platform !== 'win32') return;

  // Use PowerShell script with Win32 keybd_event for OS-level Ctrl+V.
  // Falls back to WScript.Shell SendKeys if that fails.
  // Must wait for clipboard to settle before simulating the keystroke.
  setTimeout(() => {
    const scriptPath = path.join(app.getPath('userData'), 'paste.ps1');

    // Ensure the paste script exists in a writable location
    const scriptContent = [
      'Add-Type -TypeDefinition @"',
      'using System;',
      'using System.Runtime.InteropServices;',
      'public class KBSim {',
      '  [DllImport("user32.dll")] public static extern void keybd_event(byte bVk, byte bScan, uint dwFlags, UIntPtr dwExtraInfo);',
      '  public const byte VK_CONTROL = 0x11;',
      '  public const byte VK_V = 0x56;',
      '  public const uint KEYEVENTF_KEYUP = 0x0002;',
      '  public static void Paste() {',
      '    keybd_event(VK_CONTROL, 0, 0, UIntPtr.Zero);',
      '    keybd_event(VK_V, 0, 0, UIntPtr.Zero);',
      '    System.Threading.Thread.Sleep(50);',
      '    keybd_event(VK_V, 0, KEYEVENTF_KEYUP, UIntPtr.Zero);',
      '    keybd_event(VK_CONTROL, 0, KEYEVENTF_KEYUP, UIntPtr.Zero);',
      '  }',
      '}',
      '"@',
      '[KBSim]::Paste()',
    ].join('\r\n');

    const fs = require('fs');
    try {
      fs.writeFileSync(scriptPath, scriptContent, 'utf-8');
    } catch (e) {
      console.error('Failed to write paste script:', e.message);
    }

    console.log('[paste] Attempting keybd_event paste via', scriptPath);
    execFile('powershell', [
      '-NoProfile',
      '-NonInteractive',
      '-ExecutionPolicy', 'Bypass',
      '-File', scriptPath,
    ], {
      timeout: 8000,
    }, (err, stdout, stderr) => {
      if (err) {
        console.error('[paste] keybd_event failed:', err.message, stderr);
        // Fallback 1: WScript.Shell SendKeys — works from any context
        console.log('[paste] Trying WScript.Shell fallback...');
        const fallback = `(New-Object -ComObject WScript.Shell).SendKeys('^v')`;
        execFile('powershell', ['-NoProfile', '-NonInteractive', '-Command', fallback], {
          timeout: 5000,
        }, (err2, stdout2, stderr2) => {
          if (err2) {
            console.error('[paste] WScript.Shell also failed:', err2.message, stderr2);
            // Fallback 2: System.Windows.Forms.SendKeys
            const fallback2 = `Add-Type -AssemblyName System.Windows.Forms; [System.Windows.Forms.SendKeys]::SendWait('^v')`;
            execFile('powershell', ['-NoProfile', '-NonInteractive', '-Command', fallback2], {
              timeout: 5000,
            }, (err3) => {
              if (err3) console.error('[paste] All paste methods failed:', err3.message);
            });
          }
        });
      } else {
        console.log('[paste] keybd_event paste succeeded');
      }
    });
  }, 500);
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
  updateWidget('recording');
  broadcastState();

  try {
    // Apply selected microphone before recording
    const selectedMic = store.get('microphone', '');
    if (selectedMic) recorder.setMicrophone(selectedMic);
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
  updateWidget('transcribing');
  broadcastState();

  try {
    const audioBuffer = await recorder.stop();
    if (!audioBuffer || audioBuffer.length === 0) {
      updateWidget('idle');
      broadcastResult('(No audio captured)');
      return;
    }

    broadcastStatus('Transcribing...');

    const modelName = store.get('model');
    const text = await whisperEngine.transcribe(audioBuffer, modelName);

    if (text && text.trim()) {
      const trimmed = text.trim();
      console.log('[transcription] Result:', trimmed.substring(0, 100));

      // Auto-copy to clipboard
      if (store.get('autoCopy')) {
        clipboard.writeText(trimmed);
        console.log('[transcription] Copied to clipboard');
      } else {
        console.log('[transcription] autoCopy is OFF, skipping clipboard');
      }

      // Auto-paste at cursor position
      if (store.get('autoPaste') && store.get('autoCopy')) {
        console.log('[transcription] Auto-paste enabled, simulating Ctrl+V');
        simulatePaste();
      } else {
        console.log('[transcription] autoPaste:', store.get('autoPaste'), 'autoCopy:', store.get('autoCopy'));
      }

      broadcastResult(trimmed);
      updateWidget('done');

      if (store.get('showNotification')) {
        new Notification({
          title: 'KrakWhisper',
          body: trimmed.length > 100 ? trimmed.substring(0, 100) + '...' : trimmed,
        }).show();
      }
    } else {
      broadcastResult('(No speech detected)');
      updateWidget('idle');
    }
  } catch (err) {
    broadcastResult(`Error: ${err.message}`);
    updateWidget('idle');
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
 * Register the global hotkey.
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
    autoPaste: store.get('autoPaste'),
    autoCleanup: store.get('autoCleanup'),
    showNotification: store.get('showNotification'),
    launchAtStartup: startupManager.isEnabled(),
  };
});

ipcMain.handle('save-settings', (_event, settings) => {
  const previousHotkey = store.get('hotkey');

  if (settings.model) store.set('model', settings.model);
  if (typeof settings.autoCopy === 'boolean') store.set('autoCopy', settings.autoCopy);
  if (typeof settings.autoPaste === 'boolean') store.set('autoPaste', settings.autoPaste);
  if (typeof settings.autoCleanup === 'boolean') store.set('autoCleanup', settings.autoCleanup);
  if (typeof settings.showNotification === 'boolean') store.set('showNotification', settings.showNotification);

  // Handle hotkey change
  if (settings.hotkey) {
    store.set('hotkey', settings.hotkey);
    const registered = registerHotkey();
    if (!registered) {
      store.set('hotkey', previousHotkey);
      registerHotkey();
      return { success: false, error: `Hotkey "${settings.hotkey}" could not be registered. It may be in use by another application.` };
    }
  }

  updateTrayMenu();
  return { success: true };
});

ipcMain.handle('get-state', () => {
  return { isRecording, model: store.get('model') };
});

ipcMain.handle('toggle-recording', async () => {
  try {
    await toggleRecording();
    return { success: true };
  } catch (err) {
    return { success: false, error: err.message };
  }
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

// ─── Server Management IPC ───────────────────────────────────────────
ipcMain.handle('get-server-status', () => {
  return serverManager.getStatus();
});

ipcMain.handle('restart-servers', async () => {
  try {
    await serverManager.shutdown();
    await serverManager.startAll(store);
    return { success: true };
  } catch (err) {
    return { success: false, error: err.message };
  }
});

// ─── Startup Management IPC ─────────────────────────────────────────
ipcMain.handle('get-startup-enabled', () => {
  return startupManager.isEnabled();
});

ipcMain.handle('set-startup-enabled', async (_event, enabled) => {
  return startupManager.setEnabled(enabled);
});

// ─── Microphone Selection ────────────────────────────────────────────
ipcMain.handle('list-audio-devices', async () => {
  const ffmpegPath = path.join(__dirname, '..', 'bin', 'ffmpeg.exe');
  if (!require('fs').existsSync(ffmpegPath)) return [];
  
  return new Promise((resolve) => {
    execFile(ffmpegPath, ['-list_devices', 'true', '-f', 'dshow', '-i', 'dummy'], {
      timeout: 5000,
    }, (_error, _stdout, stderr) => {
      const output = stderr || '';
      const lines = output.split('\n');
      const devices = [];
      let inAudio = false;
      for (const line of lines) {
        if (line.includes('DirectShow audio devices')) { inAudio = true; continue; }
        if (inAudio && line.includes('DirectShow video devices')) break;
        if (inAudio && line.includes(']  "')) {
          const match = line.match(/"([^"]+)"/);
          if (match) devices.push(match[1]);
        }
      }
      resolve(devices);
    });
  });
});

ipcMain.handle('get-selected-mic', () => store.get('microphone', ''));
ipcMain.handle('set-selected-mic', (_event, mic) => { store.set('microphone', mic); });
