'use strict';

const { execFile } = require('child_process');
const path = require('path');
const fs = require('fs');
const log = require('electron-log');

/**
 * WhisperService wraps whisper.cpp binary for local transcription.
 * Downloads the whisper.cpp binary on first use and runs transcription
 * as a subprocess.
 */
class WhisperService {
  constructor(userDataPath) {
    this._userDataPath = userDataPath;
    this._binDir = path.join(userDataPath, 'whisper-bin');
    this._modelPath = null;

    // Ensure bin directory exists
    fs.mkdirSync(this._binDir, { recursive: true });
  }

  /**
   * Set the model file path for transcription.
   * @param {string} modelPath
   */
  setModelPath(modelPath) {
    this._modelPath = modelPath;
  }

  /**
   * Get the path to the whisper.cpp binary.
   * @returns {string}
   */
  getBinaryPath() {
    if (process.platform === 'win32') {
      return path.join(this._binDir, 'main.exe');
    }
    return path.join(this._binDir, 'main');
  }

  /**
   * Check if whisper.cpp binary is available.
   * @returns {boolean}
   */
  isBinaryAvailable() {
    return fs.existsSync(this.getBinaryPath());
  }

  /**
   * Get the download URL for whisper.cpp release binary.
   * @returns {{ url: string, filename: string }}
   */
  getBinaryDownloadInfo() {
    // whisper.cpp provides pre-built binaries via GitHub Releases.
    // Users should download the appropriate binary for their platform
    // and place it in the whisper-bin directory.
    const version = 'v1.5.4';
    const base = `https://github.com/ggerganov/whisper.cpp/releases/download/${version}`;

    if (process.platform === 'win32') {
      return {
        url: `${base}/whisper-bin-x64.zip`,
        filename: 'whisper-bin-x64.zip',
      };
    } else if (process.platform === 'darwin') {
      return {
        url: `${base}/whisper-bin-x64.zip`,
        filename: 'whisper-bin-x64.zip',
      };
    }

    return {
      url: `${base}/whisper-bin-x64.zip`,
      filename: 'whisper-bin-x64.zip',
    };
  }

  /**
   * Get instructions for manual binary setup.
   * @returns {string}
   */
  getBinarySetupInstructions() {
    const info = this.getBinaryDownloadInfo();
    return (
      `whisper.cpp binary not found.\n\n` +
      `To set up:\n` +
      `1. Download from: ${info.url}\n` +
      `2. Extract the archive\n` +
      `3. Place the binary (main.exe or main) in:\n` +
      `   ${this._binDir}\n\n` +
      `Alternatively, build whisper.cpp from source:\n` +
      `https://github.com/ggerganov/whisper.cpp#build`
    );
  }

  /**
   * Transcribe an audio file using whisper.cpp.
   * @param {string} audioPath - Path to WAV file (16kHz mono 16-bit)
   * @returns {Promise<string>} Transcribed text
   */
  async transcribe(audioPath) {
    if (!this._modelPath) {
      throw new Error('No model path set. Download a model first.');
    }

    if (!fs.existsSync(this._modelPath)) {
      throw new Error(`Model file not found: ${this._modelPath}`);
    }

    if (!fs.existsSync(audioPath)) {
      throw new Error(`Audio file not found: ${audioPath}`);
    }

    const binaryPath = this.getBinaryPath();

    // If whisper.cpp binary isn't available, try using whisper-node or fallback
    if (!this.isBinaryAvailable()) {
      log.warn('whisper.cpp binary not found, attempting npm-based transcription');
      return this._transcribeWithNodeFallback(audioPath);
    }

    return new Promise((resolve, reject) => {
      const args = [
        '-m', this._modelPath,
        '-f', audioPath,
        '--no-timestamps',
        '--output-txt',
        '-l', 'en',
        '--threads', String(Math.max(1, Math.floor(require('os').cpus().length / 2))),
      ];

      log.info(`Running whisper.cpp: ${binaryPath} ${args.join(' ')}`);

      execFile(binaryPath, args, {
        timeout: 120000, // 2 minute timeout
        maxBuffer: 10 * 1024 * 1024,
        cwd: this._binDir,
      }, (error, stdout, stderr) => {
        if (error) {
          log.error('whisper.cpp error:', error.message);
          log.error('stderr:', stderr);
          reject(new Error(`Transcription failed: ${error.message}`));
          return;
        }

        // whisper.cpp outputs text to stdout
        const text = stdout
          .split('\n')
          .filter((line) => !line.startsWith('[') && line.trim())
          .join(' ')
          .trim();

        log.info(`Transcription result (${text.length} chars)`);
        resolve(text);
      });
    });
  }

  /**
   * Fallback transcription using node-based approach.
   * This attempts to use the whisper-node npm package.
   */
  async _transcribeWithNodeFallback(audioPath) {
    try {
      // Try to require whisper-node at runtime
      const whisper = require('whisper-node');
      const result = await whisper(audioPath, {
        modelName: path.basename(this._modelPath),
        modelPath: path.dirname(this._modelPath),
      });

      if (Array.isArray(result)) {
        return result.map((r) => r.speech).join(' ').trim();
      }

      return String(result).trim();
    } catch (err) {
      log.error('Node fallback transcription failed:', err.message);
      throw new Error(
        'Transcription unavailable. Please ensure whisper.cpp binary is installed. ' +
        'Download from: https://github.com/ggerganov/whisper.cpp/releases'
      );
    }
  }
}

module.exports = { WhisperService };
