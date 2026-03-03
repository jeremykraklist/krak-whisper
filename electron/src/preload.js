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

  // Events from main process
  onStateUpdate: (callback) => ipcRenderer.on('state-update', (_e, data) => callback(data)),
  onTranscriptionResult: (callback) => ipcRenderer.on('transcription-result', (_e, text) => callback(text)),
  onStatusUpdate: (callback) => ipcRenderer.on('status-update', (_e, status) => callback(status)),
  onDownloadProgress: (callback) => ipcRenderer.on('download-progress', (_e, data) => callback(data)),
  onShowSetup: (callback) => ipcRenderer.on('show-setup', () => callback()),
  onError: (callback) => ipcRenderer.on('error', (_e, msg) => callback(msg)),
});
