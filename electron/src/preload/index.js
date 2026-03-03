'use strict';

const { contextBridge, ipcRenderer } = require('electron');

/**
 * Expose a safe API to the renderer via contextBridge.
 * No direct Node.js access in the renderer.
 */
contextBridge.exposeInMainWorld('krakwhisper', {
  // Settings
  getSettings: () => ipcRenderer.invoke('get-settings'),
  setSetting: (key, value) => ipcRenderer.invoke('set-setting', key, value),

  // Models
  getModels: () => ipcRenderer.invoke('get-models'),
  downloadModel: (modelName) => ipcRenderer.invoke('download-model', modelName),
  deleteModel: (modelName) => ipcRenderer.invoke('delete-model', modelName),

  // Recording
  getRecordingState: () => ipcRenderer.invoke('get-recording-state'),
  toggleRecording: () => ipcRenderer.invoke('toggle-recording'),

  // Events from main process
  onDownloadProgress: (callback) => {
    ipcRenderer.on('download-progress', (_event, data) => callback(data));
  },
  onTranscriptionResult: (callback) => {
    ipcRenderer.on('transcription-result', (_event, text) => callback(text));
  },

  // Cleanup
  removeAllListeners: () => {
    ipcRenderer.removeAllListeners('download-progress');
    ipcRenderer.removeAllListeners('transcription-result');
  },
});
