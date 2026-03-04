/**
 * StartupManager — Manage Windows Startup folder shortcut.
 *
 * Creates/removes a .lnk shortcut in the user's Startup folder
 * to auto-launch KrakWhisper on Windows login.
 */
const { execFile } = require('child_process');
const path = require('path');
const fs = require('fs');
const { app } = require('electron');

class StartupManager {
  constructor() {
    this._startupDir = path.join(
      process.env.APPDATA || '',
      'Microsoft', 'Windows', 'Start Menu', 'Programs', 'Startup'
    );
    this._shortcutName = 'KrakWhisper.lnk';
  }

  /**
   * Get the full path to the startup shortcut.
   * @returns {string}
   */
  getShortcutPath() {
    return path.join(this._startupDir, this._shortcutName);
  }

  /**
   * Check if the startup shortcut exists.
   * @returns {boolean}
   */
  isEnabled() {
    if (process.platform !== 'win32') return false;
    return fs.existsSync(this.getShortcutPath());
  }

  /**
   * Add KrakWhisper to Windows startup.
   * @returns {Promise<{ success: boolean, error?: string }>}
   */
  async enable() {
    if (process.platform !== 'win32') {
      return { success: false, error: 'Only supported on Windows' };
    }

    try {
      // Determine the target — either the packaged exe or the dev launcher
      const targetPath = this._getTargetPath();
      const workingDir = path.dirname(targetPath);
      const iconPath = this._getIconPath();

      // Use PowerShell to create a proper .lnk shortcut
      const shortcutPath = this.getShortcutPath().replace(/'/g, "''");
      const escapedTarget = targetPath.replace(/'/g, "''");
      const escapedWorkDir = workingDir.replace(/'/g, "''");
      const escapedIcon = iconPath ? iconPath.replace(/'/g, "''") : '';

      let psScript = `
$ws = New-Object -ComObject WScript.Shell
$shortcut = $ws.CreateShortcut('${shortcutPath}')
$shortcut.TargetPath = '${escapedTarget}'
$shortcut.WorkingDirectory = '${escapedWorkDir}'
$shortcut.Description = 'KrakWhisper - Local Voice Dictation'
`;
      if (escapedIcon) {
        psScript += `$shortcut.IconLocation = '${escapedIcon}'\n`;
      }
      psScript += '$shortcut.Save()\n';

      await this._runPowerShell(psScript);
      console.log('[startup-manager] Startup shortcut created at:', this.getShortcutPath());
      return { success: true };
    } catch (err) {
      console.error('[startup-manager] Failed to create startup shortcut:', err.message);
      return { success: false, error: err.message };
    }
  }

  /**
   * Remove KrakWhisper from Windows startup.
   * @returns {Promise<{ success: boolean, error?: string }>}
   */
  async disable() {
    if (process.platform !== 'win32') {
      return { success: false, error: 'Only supported on Windows' };
    }

    try {
      const shortcutPath = this.getShortcutPath();
      if (fs.existsSync(shortcutPath)) {
        fs.unlinkSync(shortcutPath);
        console.log('[startup-manager] Startup shortcut removed');
      }
      return { success: true };
    } catch (err) {
      console.error('[startup-manager] Failed to remove startup shortcut:', err.message);
      return { success: false, error: err.message };
    }
  }

  /**
   * Toggle startup on/off.
   * @param {boolean} enabled
   * @returns {Promise<{ success: boolean, error?: string }>}
   */
  async setEnabled(enabled) {
    return enabled ? this.enable() : this.disable();
  }

  /**
   * Get the executable path for the shortcut target.
   * @returns {string}
   */
  _getTargetPath() {
    if (app.isPackaged) {
      // In production, point to the installed exe
      return process.execPath;
    }

    // In dev mode, create a .vbs launcher that runs electron
    const electronDir = path.join(__dirname, '..');
    const vbsPath = path.join(electronDir, 'KrakWhisper.vbs');

    // If a VBS launcher exists, use it
    if (fs.existsSync(vbsPath)) {
      return vbsPath;
    }

    // Fallback: direct electron path
    return process.execPath;
  }

  /**
   * Get the icon path for the shortcut.
   * @returns {string | null}
   */
  _getIconPath() {
    if (app.isPackaged) {
      // The packaged exe has an embedded icon
      return process.execPath;
    }

    // In dev, try to find an .ico file
    const icoPath = path.join(__dirname, '..', 'assets', 'icon.ico');
    return fs.existsSync(icoPath) ? icoPath : null;
  }

  /**
   * Run a PowerShell script.
   * @param {string} script
   * @returns {Promise<string>}
   */
  _runPowerShell(script) {
    return new Promise((resolve, reject) => {
      execFile('powershell', [
        '-NoProfile',
        '-NonInteractive',
        '-ExecutionPolicy', 'Bypass',
        '-Command', script,
      ], { timeout: 10000 }, (err, stdout, stderr) => {
        if (err) {
          reject(new Error(`PowerShell error: ${err.message}\n${stderr || ''}`));
        } else {
          resolve(stdout);
        }
      });
    });
  }
}

module.exports = { StartupManager };
