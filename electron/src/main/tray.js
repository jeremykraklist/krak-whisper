'use strict';

const { Tray, Menu, nativeImage } = require('electron');
const path = require('path');

class TrayManager {
  /**
   * @param {object} opts
   * @param {() => void} opts.onToggleRecording
   * @param {() => void} opts.onOpenSettings
   * @param {() => void} opts.onQuit
   * @param {(name: string) => string} opts.getAssetPath
   */
  constructor({ onToggleRecording, onOpenSettings, onQuit, getAssetPath }) {
    this._onToggleRecording = onToggleRecording;
    this._onOpenSettings = onOpenSettings;
    this._onQuit = onQuit;
    this._getAssetPath = getAssetPath;
    this._recording = false;
    this._transcribing = false;

    // Create tray icon (16x16 for tray)
    this._idleIcon = this._createIcon('mic-off.png');
    this._recordingIcon = this._createIcon('mic-on.png');

    this._tray = new Tray(this._idleIcon);
    this._tray.setToolTip('KrakWhisper — Click to toggle recording');

    this._tray.on('click', () => {
      this._onToggleRecording();
    });

    this._updateContextMenu();
  }

  _createIcon(filename) {
    try {
      const iconPath = this._getAssetPath(filename);
      const icon = nativeImage.createFromPath(iconPath);
      return icon.resize({ width: 16, height: 16 });
    } catch {
      // Fallback: create a simple colored icon
      return nativeImage.createEmpty();
    }
  }

  _updateContextMenu() {
    const statusLabel = this._transcribing
      ? '⏳ Transcribing...'
      : this._recording
        ? '🔴 Recording...'
        : '⏹️ Idle';

    const menu = Menu.buildFromTemplate([
      { label: 'KrakWhisper', type: 'normal', enabled: false },
      { type: 'separator' },
      { label: statusLabel, type: 'normal', enabled: false },
      {
        label: this._recording ? 'Stop Recording' : 'Start Recording',
        click: () => this._onToggleRecording(),
      },
      { type: 'separator' },
      { label: 'Settings...', click: () => this._onOpenSettings() },
      { type: 'separator' },
      { label: 'Quit KrakWhisper', click: () => this._onQuit() },
    ]);

    this._tray.setContextMenu(menu);
  }

  setRecording(recording) {
    this._recording = recording;
    this._tray.setImage(recording ? this._recordingIcon : this._idleIcon);
    this._tray.setToolTip(
      recording ? 'KrakWhisper — Recording... (click to stop)' : 'KrakWhisper — Click to toggle recording'
    );
    this._updateContextMenu();
  }

  setTranscribing(transcribing) {
    this._transcribing = transcribing;
    this._tray.setToolTip(transcribing ? 'KrakWhisper — Transcribing...' : 'KrakWhisper — Idle');
    this._updateContextMenu();
  }

  destroy() {
    if (this._tray) {
      this._tray.destroy();
      this._tray = null;
    }
  }
}

module.exports = { TrayManager };
