const { app, BrowserWindow, Tray, Menu, globalShortcut, ipcMain, nativeImage, dialog, clipboard, Notification } = require('electron');
const { execFile } = require('child_process');
const path = require('path');
const fs = require('fs');
const Store = require('electron-store');
const { AudioRecorder } = require('./audio-recorder');
const { WhisperEngine } = require('./whisper-engine');
const { ModelManager } = require('./model-manager');

/** @type {Store} */
const store = new Store({
  defaults: {
    model: 'medium.en',
    hotkey: 'CommandOrControl+Shift+W',
    autoCopy: true,
    autoPaste: true,
    showNotification: true,
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
/** @type {boolean} */
let isRecording = false;
/** @type {boolean} */
let toggleInFlight = false;
/** @type {string | null} HWND of the foreground window captured before recording */
let lastForegroundHwnd = null;

// ─── Helper path resolution ─────────────────────────────────────────

/**
 * Get the path to a helper executable in the bin directory.
 * @param {string} name - e.g. 'paste-helper.exe'
 * @returns {string}
 */
function getHelperPath(name) {
  return path.join(__dirname, '..', 'bin', name);
}

/**
 * Capture the HWND of the current foreground window.
 * Uses native get-foreground.exe if available; falls back to PowerShell.
 * @returns {Promise<string|null>} Decimal HWND string, or null on failure.
 */
async function captureTargetWindow() {
  return new Promise((resolve) => {
    const helperPath = getHelperPath('get-foreground.exe');
    if (fs.existsSync(helperPath)) {
      execFile(helperPath, { timeout: 1000 }, (err, stdout) => {
        if (err) {
          console.error('[paste] get-foreground.exe failed:', err.message);
          resolve(null);
        } else {
          const hwnd = stdout.trim();
          console.log('[paste] Captured HWND via native helper:', hwnd);
          resolve(hwnd || null);
        }
      });
    } else {
      // Fallback: PowerShell (slower but works without native helper)
      execFile('powershell', ['-NoProfile', '-NonInteractive', '-Command',
        '(Add-Type -MemberDefinition \'[DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();\' -Name W -Namespace U -PassThru)::GetForegroundWindow().ToInt64()'
      ], { timeout: 2000 }, (err, stdout) => {
        if (err) {
          console.error('[paste] PowerShell HWND capture failed:', err.message);
          resolve(null);
        } else {
          const hwnd = stdout.trim().split('\n').pop().trim();
          console.log('[paste] Captured HWND via PowerShell:', hwnd);
          resolve(hwnd || null);
        }
      });
    }
  });
}

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
  createWidget();
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

// Capture foreground HWND on widget mousedown (before click steals focus)
ipcMain.on('capture-foreground', async () => {
  const hwnd = await captureTargetWindow();
  if (hwnd) {
    lastForegroundHwnd = hwnd;
  }
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
    width: 440,
    height: 560,
    resizable: false,
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
 * Simulate Ctrl+V paste using hybrid cascade approach.
 * Primary: native paste-helper.exe (fast, ~50ms)
 * Fallback: PowerShell keybd_event + WScript.Shell + SendKeys
 *
 * @param {string} text - The text to paste (used by native helper for clipboard write + Ctrl+V)
 */
function simulatePaste(text) {
  if (process.platform !== 'win32') return;

  const helperPath = getHelperPath('paste-helper.exe');
  const hwnd = lastForegroundHwnd || '0';

  if (fs.existsSync(helperPath)) {
    // Fast native path: paste-helper.exe handles clipboard write + focus restore + Ctrl+V
    console.log('[paste] Using native paste-helper, HWND:', hwnd);
    execFile(helperPath, [hwnd, text], { timeout: 3000 }, (err, stdout, stderr) => {
      if (err) {
        console.error('[paste] Native helper failed:', stderr || err.message);
        console.log('[paste] Falling back to PowerShell...');
        simulatePasteFallback();
      } else {
        console.log('[paste] Native paste succeeded');
      }
    });
  } else {
    console.log('[paste] paste-helper.exe not found, using PowerShell fallback');
    simulatePasteFallback();
  }
}

/**
 * PowerShell fallback paste — used when native paste-helper.exe is unavailable.
 * Cascade: keybd_event → WScript.Shell SendKeys → System.Windows.Forms.SendKeys
 */
function simulatePasteFallback() {
  setTimeout(() => {
    const scriptPath = path.join(app.getPath('userData'), 'paste.ps1');

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

    try {
      fs.writeFileSync(scriptPath, scriptContent, 'utf-8');
    } catch (e) {
      console.error('Failed to write paste script:', e.message);
    }

    console.log('[paste] Fallback: attempting keybd_event paste via', scriptPath);
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
        console.log('[paste] Trying WScript.Shell fallback...');
        const fallback = `(New-Object -ComObject WScript.Shell).SendKeys('^v')`;
        execFile('powershell', ['-NoProfile', '-NonInteractive', '-Command', fallback], {
          timeout: 5000,
        }, (err2, stdout2, stderr2) => {
          if (err2) {
            console.error('[paste] WScript.Shell also failed:', err2.message, stderr2);
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
  }, 50); // Reduced from 500ms — clipboard is already written at this point
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
        simulatePaste(trimmed);
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
    const success = globalShortcut.register(hotkey, async () => {
      // Capture HWND immediately — foreground is still the target app
      lastForegroundHwnd = await captureTargetWindow();
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
    showNotification: store.get('showNotification'),
  };
});

ipcMain.handle('save-settings', (_event, settings) => {
  const previousHotkey = store.get('hotkey');

  if (settings.model) store.set('model', settings.model);
  if (typeof settings.autoCopy === 'boolean') store.set('autoCopy', settings.autoCopy);
  if (typeof settings.autoPaste === 'boolean') store.set('autoPaste', settings.autoPaste);
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
