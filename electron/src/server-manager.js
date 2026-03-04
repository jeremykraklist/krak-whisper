/**
 * ServerManager — Auto-start and manage whisper-server.exe and llama-server.exe.
 *
 * On app launch, checks if the servers are already running on their ports.
 * If not, spawns them from known paths. Provides graceful shutdown on app quit.
 */
const { spawn, execFile } = require('child_process');
const path = require('path');
const fs = require('fs');
const http = require('http');
const { app } = require('electron');

/** @typedef {{ name: string, port: number, process: import('child_process').ChildProcess | null, status: 'stopped' | 'starting' | 'running' | 'error', error?: string }} ServerInfo */

class ServerManager {
  constructor() {
    /** @type {ServerInfo} */
    this.whisperServer = {
      name: 'whisper-server',
      port: 8178,
      process: null,
      status: 'stopped',
    };

    /** @type {ServerInfo} */
    this.llamaServer = {
      name: 'llama-server',
      port: 8179,
      process: null,
      status: 'stopped',
    };

    /** @type {((status: object) => void)[]} */
    this._statusListeners = [];
  }

  /**
   * Register a callback for server status changes.
   * @param {(status: object) => void} callback
   */
  onStatusChange(callback) {
    this._statusListeners.push(callback);
  }

  /** Notify all listeners of current status */
  _notifyStatus() {
    const status = this.getStatus();
    for (const listener of this._statusListeners) {
      try { listener(status); } catch { /* ignore */ }
    }
  }

  /**
   * Get current server statuses.
   * @returns {{ whisper: { status: string, port: number, error?: string }, llama: { status: string, port: number, error?: string } }}
   */
  getStatus() {
    return {
      whisper: {
        status: this.whisperServer.status,
        port: this.whisperServer.port,
        error: this.whisperServer.error,
      },
      llama: {
        status: this.llamaServer.status,
        port: this.llamaServer.port,
        error: this.llamaServer.error,
      },
    };
  }

  /**
   * Start all servers that aren't already running.
   * @param {import('electron-store').default} store - Config store for model path
   */
  async startAll(store) {
    await Promise.all([
      this._ensureWhisperServer(store),
      this._ensureLlamaServer(),
    ]);
  }

  /**
   * Check if whisper-server is running, start if not.
   * @param {import('electron-store').default} store
   */
  async _ensureWhisperServer(store) {
    const alreadyRunning = await this._isPortListening(this.whisperServer.port);
    if (alreadyRunning) {
      console.log('[server-manager] whisper-server already running on port', this.whisperServer.port);
      this.whisperServer.status = 'running';
      this._notifyStatus();
      return;
    }

    const binaryPath = this._getServerBinaryPath('whisper-server.exe');
    if (!binaryPath || !fs.existsSync(binaryPath)) {
      console.log('[server-manager] whisper-server.exe not found, skipping');
      this.whisperServer.status = 'error';
      this.whisperServer.error = 'Binary not found';
      this._notifyStatus();
      return;
    }

    // Find the model file
    const modelName = store.get('model', 'medium.en');
    const modelFilename = `ggml-${modelName}.bin`;
    const modelsDir = path.join(app.getPath('userData'), 'models');
    const modelPath = path.join(modelsDir, modelFilename);

    if (!fs.existsSync(modelPath)) {
      console.log('[server-manager] Model not found at', modelPath);
      this.whisperServer.status = 'error';
      this.whisperServer.error = `Model ${modelName} not downloaded`;
      this._notifyStatus();
      return;
    }

    console.log('[server-manager] Starting whisper-server with model:', modelPath);
    this.whisperServer.status = 'starting';
    this._notifyStatus();

    try {
      const binDir = path.dirname(binaryPath);
      const logPath = path.join(app.getPath('userData'), 'whisper-server.log');

      // Set PATH so CUDA/whisper DLLs are found
      const env = { ...process.env };
      env.PATH = binDir + ';' + (env.PATH || '');

      const logStream = fs.createWriteStream(logPath, { flags: 'a' });

      this.whisperServer.process = spawn(binaryPath, [
        '--model', modelPath,
        '--host', '127.0.0.1',
        '--port', String(this.whisperServer.port),
        '--threads', '4',
      ], {
        cwd: binDir,
        env,
        stdio: ['ignore', 'pipe', 'pipe'],
        detached: false,
        windowsHide: true,
      });

      this.whisperServer.process.stdout.pipe(logStream);
      this.whisperServer.process.stderr.pipe(logStream);

      this.whisperServer.process.on('error', (err) => {
        console.error('[server-manager] whisper-server spawn error:', err.message);
        this.whisperServer.status = 'error';
        this.whisperServer.error = err.message;
        this.whisperServer.process = null;
        this._notifyStatus();
      });

      this.whisperServer.process.on('exit', (code) => {
        console.log('[server-manager] whisper-server exited with code:', code);
        if (this.whisperServer.status !== 'stopped') {
          this.whisperServer.status = 'error';
          this.whisperServer.error = `Exited with code ${code}`;
        }
        this.whisperServer.process = null;
        this._notifyStatus();
      });

      // Wait for the server to become ready (poll port)
      const ready = await this._waitForPort(this.whisperServer.port, 30000);
      if (ready) {
        console.log('[server-manager] whisper-server is ready');
        this.whisperServer.status = 'running';
      } else {
        console.error('[server-manager] whisper-server failed to start within timeout');
        this.whisperServer.status = 'error';
        this.whisperServer.error = 'Startup timeout (model loading may take time — check logs)';
      }
      this._notifyStatus();
    } catch (err) {
      console.error('[server-manager] Failed to start whisper-server:', err.message);
      this.whisperServer.status = 'error';
      this.whisperServer.error = err.message;
      this._notifyStatus();
    }
  }

  /**
   * Check if llama-server is running, start if not.
   */
  async _ensureLlamaServer() {
    const alreadyRunning = await this._isPortListening(this.llamaServer.port);
    if (alreadyRunning) {
      console.log('[server-manager] llama-server already running on port', this.llamaServer.port);
      this.llamaServer.status = 'running';
      this._notifyStatus();
      return;
    }

    // llama-server.exe could be in bin/ or in a known external path
    const binaryPath = this._findLlamaServer();
    if (!binaryPath) {
      console.log('[server-manager] llama-server.exe not found, skipping');
      this.llamaServer.status = 'stopped';
      this.llamaServer.error = 'Binary not found (optional)';
      this._notifyStatus();
      return;
    }

    // Find the Qwen model
    const modelPath = this._findQwenModel(binaryPath);
    if (!modelPath) {
      console.log('[server-manager] Qwen model not found, skipping llama-server');
      this.llamaServer.status = 'error';
      this.llamaServer.error = 'Qwen model not found';
      this._notifyStatus();
      return;
    }

    console.log('[server-manager] Starting llama-server with model:', modelPath);
    this.llamaServer.status = 'starting';
    this._notifyStatus();

    try {
      const binDir = path.dirname(binaryPath);
      const logPath = path.join(app.getPath('userData'), 'llama-server.log');
      const logStream = fs.createWriteStream(logPath, { flags: 'a' });

      const env = { ...process.env };
      env.PATH = binDir + ';' + (env.PATH || '');

      this.llamaServer.process = spawn(binaryPath, [
        '--model', modelPath,
        '--host', '127.0.0.1',
        '--port', String(this.llamaServer.port),
        '--n-gpu-layers', '99',
        '--ctx-size', '2048',
      ], {
        cwd: binDir,
        env,
        stdio: ['ignore', 'pipe', 'pipe'],
        detached: false,
        windowsHide: true,
      });

      this.llamaServer.process.stdout.pipe(logStream);
      this.llamaServer.process.stderr.pipe(logStream);

      this.llamaServer.process.on('error', (err) => {
        console.error('[server-manager] llama-server spawn error:', err.message);
        this.llamaServer.status = 'error';
        this.llamaServer.error = err.message;
        this.llamaServer.process = null;
        this._notifyStatus();
      });

      this.llamaServer.process.on('exit', (code) => {
        console.log('[server-manager] llama-server exited with code:', code);
        if (this.llamaServer.status !== 'stopped') {
          this.llamaServer.status = 'error';
          this.llamaServer.error = `Exited with code ${code}`;
        }
        this.llamaServer.process = null;
        this._notifyStatus();
      });

      // Wait for ready
      const ready = await this._waitForPort(this.llamaServer.port, 30000);
      if (ready) {
        console.log('[server-manager] llama-server is ready');
        this.llamaServer.status = 'running';
      } else {
        console.error('[server-manager] llama-server failed to start within timeout');
        this.llamaServer.status = 'error';
        this.llamaServer.error = 'Startup timeout';
      }
      this._notifyStatus();
    } catch (err) {
      console.error('[server-manager] Failed to start llama-server:', err.message);
      this.llamaServer.status = 'error';
      this.llamaServer.error = err.message;
      this._notifyStatus();
    }
  }

  /**
   * Find the whisper-server or llama-server binary path.
   * Checks bin/ (bundled) then resourcesPath (packaged).
   * @param {string} binaryName
   * @returns {string | null}
   */
  _getServerBinaryPath(binaryName) {
    const isDev = !app.isPackaged;
    if (isDev) {
      const devPath = path.join(__dirname, '..', 'bin', binaryName);
      if (fs.existsSync(devPath)) return devPath;
    } else {
      const prodPath = path.join(process.resourcesPath, 'bin', binaryName);
      if (fs.existsSync(prodPath)) return prodPath;
    }
    return null;
  }

  /**
   * Find llama-server.exe — check bin/, resourcesPath, and known external paths.
   * @returns {string | null}
   */
  _findLlamaServer() {
    // Check bundled first
    const bundled = this._getServerBinaryPath('llama-server.exe');
    if (bundled) return bundled;

    // Check known external paths (Jeremiah's setup)
    const knownPaths = [
      path.join(process.env.USERPROFILE || '', 'Projects', 'llama-cpp', 'bin', 'llama-server.exe'),
      path.join(process.env.LOCALAPPDATA || '', 'llama-cpp', 'bin', 'llama-server.exe'),
    ];

    for (const p of knownPaths) {
      if (fs.existsSync(p)) return p;
    }

    return null;
  }

  /**
   * Find the Qwen model GGUF file.
   * @param {string} llamaBinaryPath
   * @returns {string | null}
   */
  _findQwenModel(llamaBinaryPath) {
    // Check relative to llama-server (../models/)
    const modelsDir = path.join(path.dirname(llamaBinaryPath), '..', 'models');
    if (fs.existsSync(modelsDir)) {
      const files = fs.readdirSync(modelsDir);
      const qwenModel = files.find((f) => f.includes('qwen') && f.endsWith('.gguf'));
      if (qwenModel) return path.join(modelsDir, qwenModel);
    }

    // Check app userData models dir
    const appModelsDir = path.join(app.getPath('userData'), 'models');
    if (fs.existsSync(appModelsDir)) {
      const files = fs.readdirSync(appModelsDir);
      const qwenModel = files.find((f) => f.includes('qwen') && f.endsWith('.gguf'));
      if (qwenModel) return path.join(appModelsDir, qwenModel);
    }

    return null;
  }

  /**
   * Check if a port is listening.
   * @param {number} port
   * @returns {Promise<boolean>}
   */
  _isPortListening(port) {
    return new Promise((resolve) => {
      const req = http.get(`http://127.0.0.1:${port}/`, { timeout: 2000 }, (res) => {
        res.resume();
        resolve(true);
      });
      req.on('error', () => resolve(false));
      req.on('timeout', () => {
        req.destroy();
        resolve(false);
      });
    });
  }

  /**
   * Wait for a port to become available.
   * @param {number} port
   * @param {number} timeoutMs
   * @returns {Promise<boolean>}
   */
  async _waitForPort(port, timeoutMs) {
    const start = Date.now();
    while (Date.now() - start < timeoutMs) {
      if (await this._isPortListening(port)) return true;
      await new Promise((r) => setTimeout(r, 1000));
    }
    return false;
  }

  /**
   * Kill all managed server processes.
   * @returns {Promise<void>}
   */
  async shutdown() {
    console.log('[server-manager] Shutting down servers...');
    const promises = [];

    if (this.whisperServer.process) {
      this.whisperServer.status = 'stopped';
      promises.push(this._killProcess(this.whisperServer));
    }

    if (this.llamaServer.process) {
      this.llamaServer.status = 'stopped';
      promises.push(this._killProcess(this.llamaServer));
    }

    // Also kill orphaned server processes by port — only if we spawned them
    if (process.platform === 'win32') {
      if (this.whisperServer.process) {
        promises.push(this._killProcessByPort(this.whisperServer.port, 'whisper-server.exe'));
      }
      if (this.llamaServer.process) {
        promises.push(this._killProcessByPort(this.llamaServer.port, 'llama-server.exe'));
      }
    }

    await Promise.allSettled(promises);
    console.log('[server-manager] Shutdown complete');
  }

  /**
   * Kill a managed process gracefully, then force after timeout.
   * @param {ServerInfo} serverInfo
   * @returns {Promise<void>}
   */
  _killProcess(serverInfo) {
    return new Promise((resolve) => {
      const proc = serverInfo.process;
      if (!proc) { resolve(); return; }

      const forceKillTimer = setTimeout(() => {
        try { proc.kill('SIGKILL'); } catch { /* ignore */ }
        resolve();
      }, 5000);

      proc.once('exit', () => {
        clearTimeout(forceKillTimer);
        serverInfo.process = null;
        resolve();
      });

      try {
        proc.kill('SIGTERM');
      } catch {
        clearTimeout(forceKillTimer);
        serverInfo.process = null;
        resolve();
      }
    });
  }

  /**
   * Kill a process listening on a specific port (Windows taskkill).
   * Only kills if the process name matches expectedName to avoid killing unrelated processes.
   * @param {number} port
   * @param {string} expectedName
   * @returns {Promise<void>}
   */
  _killProcessByPort(port, expectedName) {
    return new Promise((resolve) => {
      // Use netstat to find PID, then taskkill
      execFile('cmd', ['/c', `netstat -ano | findstr :${port} | findstr LISTENING`], {
        timeout: 5000,
      }, (err, stdout) => {
        if (err || !stdout.trim()) { resolve(); return; }

        // Parse PID from netstat output
        const lines = stdout.trim().split('\n');
        for (const line of lines) {
          const parts = line.trim().split(/\s+/);
          const pid = parts[parts.length - 1];
          if (pid && /^\d+$/.test(pid)) {
            // Verify the process name before killing
            execFile('tasklist', ['/FI', `PID eq ${pid}`, '/FO', 'CSV', '/NH'], {
              timeout: 3000,
            }, (err2, stdout2) => {
              if (!err2 && stdout2.toLowerCase().includes(expectedName.toLowerCase())) {
                execFile('taskkill', ['/PID', pid, '/F'], { timeout: 3000 }, () => resolve());
              } else {
                resolve();
              }
            });
            return;
          }
        }
        resolve();
      });
    });
  }
}

module.exports = { ServerManager };
