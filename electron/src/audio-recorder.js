/**
 * AudioRecorder — Records audio from the microphone using Electron's desktopCapturer
 * or the Web Audio API in the renderer process.
 *
 * Since we need raw PCM for whisper.cpp (16-bit, 16kHz, mono), this module
 * coordinates between the main process and a hidden recorder window that
 * accesses the microphone via the Web Audio API.
 *
 * For simplicity in v1, we use a child process approach with a platform-native
 * audio recorder (SoX/rec command or PowerShell on Windows).
 */
const { execFile, spawn } = require('child_process');
const path = require('path');
const fs = require('fs');
const os = require('os');

class AudioRecorder {
  constructor() {
    /** @type {import('child_process').ChildProcess | null} */
    this._process = null;
    /** @type {string | null} */
    this._outputPath = null;
    this._isRecording = false;
  }

  /**
   * Start recording audio from the default microphone.
   * @returns {Promise<void>}
   */
  async start() {
    if (this._isRecording) {
      throw new Error('Already recording');
    }

    const tempDir = os.tmpdir();
    this._outputPath = path.join(tempDir, `krakwhisper-rec-${Date.now()}.wav`);

    if (process.platform === 'win32') {
      await this._startWindowsRecording();
    } else if (process.platform === 'darwin') {
      await this._startMacRecording();
    } else {
      await this._startLinuxRecording();
    }

    this._isRecording = true;
  }

  /**
   * Stop recording and return the raw PCM audio buffer (16-bit, 16kHz, mono).
   * @returns {Promise<Buffer>}
   */
  async stop() {
    if (!this._isRecording) {
      throw new Error('Not recording');
    }

    this._isRecording = false;

    // Send termination signal
    if (this._process) {
      if (process.platform === 'win32') {
        // For PowerShell, we write a stop signal
        this._process.kill('SIGTERM');
      } else {
        // For sox/rec, SIGINT triggers graceful stop
        this._process.kill('SIGINT');
      }

      // Wait for process to finish
      await new Promise((resolve) => {
        const timeout = setTimeout(() => {
          if (this._process) this._process.kill('SIGKILL');
          resolve(undefined);
        }, 3000);

        if (this._process) {
          this._process.on('exit', () => {
            clearTimeout(timeout);
            resolve(undefined);
          });
        } else {
          clearTimeout(timeout);
          resolve(undefined);
        }
      });

      this._process = null;
    }

    // Read and convert to PCM
    if (this._outputPath && fs.existsSync(this._outputPath)) {
      const wavData = fs.readFileSync(this._outputPath);
      try { fs.unlinkSync(this._outputPath); } catch { /* ignore */ }
      // Extract PCM data (skip 44-byte WAV header)
      if (wavData.length > 44) {
        return wavData.subarray(44);
      }
    }

    return Buffer.alloc(0);
  }

  /**
   * Record on Windows using PowerShell and NAudio or ffmpeg.
   * Falls back to a simple PowerShell script if ffmpeg isn't available.
   */
  async _startWindowsRecording() {
    // Try ffmpeg first (commonly available)
    const ffmpegPath = await this._findExecutable('ffmpeg');
    if (ffmpegPath) {
      this._process = spawn(ffmpegPath, [
        '-f', 'dshow',
        '-i', 'audio=default',
        '-ar', '16000',
        '-ac', '1',
        '-sample_fmt', 's16',
        '-y',
        this._outputPath,
      ], { stdio: 'pipe' });
      return;
    }

    // Fallback: PowerShell with .NET audio capture
    const psScript = `
      Add-Type -AssemblyName System.Speech
      Add-Type -AssemblyName NAudio -ErrorAction SilentlyContinue

      $waveIn = New-Object NAudio.Wave.WaveInEvent
      $waveIn.WaveFormat = New-Object NAudio.Wave.WaveFormat(16000, 16, 1)
      $writer = New-Object NAudio.Wave.WaveFileWriter("${this._outputPath.replace(/\\/g, '\\\\')}", $waveIn.WaveFormat)

      $waveIn.add_DataAvailable({
        param($sender, $e)
        $writer.Write($e.Buffer, 0, $e.BytesRecorded)
      })

      $waveIn.StartRecording()

      # Wait for signal to stop (parent process will kill us)
      while ($true) { Start-Sleep -Seconds 1 }
    `;

    this._process = spawn('powershell', ['-Command', psScript], { stdio: 'pipe' });
  }

  /**
   * Record on macOS using sox/rec.
   */
  async _startMacRecording() {
    // Use sox's rec command
    const recPath = await this._findExecutable('rec') || await this._findExecutable('sox');

    if (recPath) {
      const args = recPath.includes('sox')
        ? ['-d', '-r', '16000', '-c', '1', '-b', '16', '-e', 'signed-integer', this._outputPath]
        : ['-r', '16000', '-c', '1', '-b', '16', '-e', 'signed-integer', this._outputPath];

      this._process = spawn(recPath, args, { stdio: 'pipe' });
      return;
    }

    // Fallback: ffmpeg
    const ffmpegPath = await this._findExecutable('ffmpeg');
    if (ffmpegPath) {
      this._process = spawn(ffmpegPath, [
        '-f', 'avfoundation',
        '-i', ':default',
        '-ar', '16000',
        '-ac', '1',
        '-sample_fmt', 's16',
        '-y',
        this._outputPath,
      ], { stdio: 'pipe' });
      return;
    }

    throw new Error('No audio recording tool found. Please install sox or ffmpeg.');
  }

  /**
   * Record on Linux using arecord or ffmpeg.
   */
  async _startLinuxRecording() {
    const arecordPath = await this._findExecutable('arecord');
    if (arecordPath) {
      this._process = spawn(arecordPath, [
        '-f', 'S16_LE',
        '-r', '16000',
        '-c', '1',
        this._outputPath,
      ], { stdio: 'pipe' });
      return;
    }

    const ffmpegPath = await this._findExecutable('ffmpeg');
    if (ffmpegPath) {
      this._process = spawn(ffmpegPath, [
        '-f', 'pulse',
        '-i', 'default',
        '-ar', '16000',
        '-ac', '1',
        '-sample_fmt', 's16',
        '-y',
        this._outputPath,
      ], { stdio: 'pipe' });
      return;
    }

    throw new Error('No audio recording tool found. Please install alsa-utils or ffmpeg.');
  }

  /**
   * Find an executable on the system PATH.
   * @param {string} name
   * @returns {Promise<string | null>}
   */
  _findExecutable(name) {
    return new Promise((resolve) => {
      const cmd = process.platform === 'win32' ? 'where' : 'which';
      execFile(cmd, [name], (error, stdout) => {
        if (error || !stdout.trim()) {
          resolve(null);
        } else {
          resolve(stdout.trim().split('\n')[0]);
        }
      });
    });
  }
}

module.exports = { AudioRecorder };
