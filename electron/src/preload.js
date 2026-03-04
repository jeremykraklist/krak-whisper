const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('krakwhisper', {
  // Settings
  getSettings: () => ipcRenderer.invoke('get-settings'),
  saveSettings: (settings) => ipcRenderer.invoke('save-settings', settings),

  // Recording
  getState: () => ipcRenderer.invoke('get-state'),
  toggleRecording: () => ipcRenderer.invoke('toggle-recording'),

  // Models
  getAvailableModels: () => ipcRenderer.invoke('get-available-models'),
  getDownloadedModels: () => ipcRenderer.invoke('get-downloaded-models'),
  downloadModel: (modelName) => ipcRenderer.invoke('download-model', modelName),
  deleteModel: (modelName) => ipcRenderer.invoke('delete-model', modelName),

  // Clipboard
  copyToClipboard: (text) => ipcRenderer.invoke('copy-to-clipboard', text),

  // Server management
  getServerStatus: () => ipcRenderer.invoke('get-server-status'),
  restartServers: () => ipcRenderer.invoke('restart-servers'),

  // Startup management
  getStartupEnabled: () => ipcRenderer.invoke('get-startup-enabled'),
  setStartupEnabled: (enabled) => ipcRenderer.invoke('set-startup-enabled', enabled),

  // Audio devices
  listAudioDevices: () => ipcRenderer.invoke('list-audio-devices'),
  getSelectedMic: () => ipcRenderer.invoke('get-selected-mic'),
  setSelectedMic: (mic) => ipcRenderer.invoke('set-selected-mic', mic),

  // Events from main process
  onStateUpdate: (callback) => ipcRenderer.on('state-update', (_e, data) => callback(data)),
  onTranscriptionResult: (callback) => ipcRenderer.on('transcription-result', (_e, text) => callback(text)),
  onStatusUpdate: (callback) => ipcRenderer.on('status-update', (_e, status) => callback(status)),
  onDownloadProgress: (callback) => ipcRenderer.on('download-progress', (_e, data) => callback(data)),
  onShowSetup: (callback) => ipcRenderer.on('show-setup', () => callback()),
  onError: (callback) => ipcRenderer.on('error', (_e, msg) => callback(msg)),
  onServerStatus: (callback) => ipcRenderer.on('server-status', (_e, status) => callback(status)),
});
