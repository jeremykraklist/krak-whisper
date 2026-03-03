'use strict';

const Store = require('electron-store');

const DEFAULTS = {
  model: 'base',
  hotkey: 'Ctrl+Shift+Space',
  language: 'en',
  autoClipboard: true,
  showNotification: true,
  launchOnStartup: false,
};

class SettingsManager {
  constructor() {
    this._store = new Store({
      name: 'krakwhisper-settings',
      defaults: DEFAULTS,
    });
  }

  /**
   * Get a setting value.
   * @param {string} key
   * @param {*} defaultValue
   * @returns {*}
   */
  get(key, defaultValue) {
    return this._store.get(key, defaultValue ?? DEFAULTS[key]);
  }

  /**
   * Set a setting value.
   * @param {string} key
   * @param {*} value
   */
  set(key, value) {
    this._store.set(key, value);
  }

  /**
   * Get all settings.
   * @returns {object}
   */
  getAll() {
    return {
      model: this.get('model'),
      hotkey: this.get('hotkey'),
      language: this.get('language'),
      autoClipboard: this.get('autoClipboard'),
      showNotification: this.get('showNotification'),
      launchOnStartup: this.get('launchOnStartup'),
    };
  }

  /**
   * Reset all settings to defaults.
   */
  reset() {
    this._store.clear();
  }
}

module.exports = { SettingsManager };
