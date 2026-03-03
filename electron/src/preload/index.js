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

  // Events from main process — return disposer functions for cleanup
  onDownloadProgress: (callback) => {
    const handler = (_event, data) => callback(data);
    ipcRenderer.on('download-progress', handler);
    return () => ipcRenderer.removeListener('download-progress', handler);
  },
  onTranscriptionResult: (callback) => {
    const handler = (_event, text) => callback(text);
    ipcRenderer.on('transcription-result', handler);
    return () => ipcRenderer.removeListener('transcription-result', handler);
  },
});
