/**
 * AudioRecorder — Records audio from the microphone.
 *
 * Uses platform-native recording tools (ffmpeg, sox, arecord, PowerShell)
 * to capture audio as a WAV file, then returns raw PCM data for whisper.cpp.
 */
const { execFile, spawn } = require('child_process');
const path = require('path');
const fs = require('fs');
const os = require('os');
const wav = require('node-wav');

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

    // Capture ref before clearing
    const proc = this._process;
    this._process = null;

    if (proc) {
      // Attach exit listener BEFORE sending kill signal to avoid race
      const exitPromise = new Promise((resolve) => {
        proc.on('exit', () => resolve(undefined));
        // Safety timeout in case exit never fires
        setTimeout(() => {
          try { proc.kill('SIGKILL'); } catch { /* already dead */ }
          resolve(undefined);
        }, 3000);
      });

      // Send termination signal
      if (process.platform === 'win32') {
        try { proc.kill('SIGTERM'); } catch { /* ignore */ }
      } else {
        // For sox/rec, SIGINT triggers graceful stop
        try { proc.kill('SIGINT'); } catch { /* ignore */ }
      }

      await exitPromise;
    }

    // Read WAV file and parse with node-wav for correct PCM extraction
    if (this._outputPath && fs.existsSync(this._outputPath)) {
      try {
        const wavData = fs.readFileSync(this._outputPath);
        const decoded = wav.decode(wavData);

        // Convert Float32 channel data to 16-bit PCM Buffer
        // whisper.cpp expects 16kHz mono 16-bit signed integer
        const channelData = decoded.channelData[0]; // mono channel
        const pcmBuffer = Buffer.alloc(channelData.length * 2);
        for (let i = 0; i < channelData.length; i++) {
          const sample = Math.max(-1, Math.min(1, channelData[i]));
          pcmBuffer.writeInt16LE(Math.round(sample * 32767), i * 2);
        }
        return pcmBuffer;
      } catch (err) {
        console.error('Failed to decode WAV file:', err.message);
        return Buffer.alloc(0);
      } finally {
        try { fs.unlinkSync(this._outputPath); } catch { /* ignore */ }
      }
    }

    return Buffer.alloc(0);
  }

  /**
   * Record on Windows using ffmpeg (with device enumeration) or PowerShell.
   */
  async _startWindowsRecording() {
    const ffmpegPath = await this._findExecutable('ffmpeg');
    if (ffmpegPath) {
      // Enumerate audio devices to find the default microphone
      const deviceName = await this._getWindowsAudioDevice(ffmpegPath);
      this._process = spawn(ffmpegPath, [
        '-f', 'dshow',
        '-i', `audio=${deviceName}`,
        '-ar', '16000',
        '-ac', '1',
        '-sample_fmt', 's16',
        '-y',
        this._outputPath,
      ], { stdio: 'pipe' });
      return;
    }

    // Fallback: PowerShell with .NET audio capture (requires NAudio)
    const psScript = `
      try {
        Add-Type -AssemblyName NAudio
      } catch {
        Write-Error "NAudio assembly not found. Please install NAudio or use ffmpeg for audio recording."
        exit 1
      }

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
   * Enumerate Windows audio devices via ffmpeg and return the first microphone name.
   * Falls back to 'Microphone' if enumeration fails.
   * @param {string} ffmpegPath
   * @returns {Promise<string>}
   */
  _getWindowsAudioDevice(ffmpegPath) {
    return new Promise((resolve) => {
      execFile(ffmpegPath, ['-list_devices', 'true', '-f', 'dshow', '-i', 'dummy'], {
        timeout: 5000,
      }, (_error, _stdout, stderr) => {
        // ffmpeg prints device list to stderr
        const output = stderr || '';
        const lines = output.split('\n');
        let inAudio = false;
        for (const line of lines) {
          if (line.includes('DirectShow audio devices')) {
            inAudio = true;
            continue;
          }
          if (inAudio && line.includes(']  "')) {
            // Extract device name from line like: [dshow @ ...] "Microphone (Realtek Audio)"
            const match = line.match(/"([^"]+)"/);
            if (match) {
              resolve(match[1]);
              return;
            }
          }
          // Stop if we hit video devices section
          if (inAudio && line.includes('DirectShow video devices')) {
            break;
          }
        }
        // Fallback
        resolve('Microphone');
      });
    });
  }

  /**
   * Record on macOS using sox/rec.
   */
  async _startMacRecording() {
    const recPath = await this._findExecutable('rec') || await this._findExecutable('sox');

    if (recPath) {
      const args = recPath.includes('sox')
        ? ['-d', '-r', '16000', '-c', '1', '-b', '16', '-e', 'signed-integer', this._outputPath]
        : ['-r', '16000', '-c', '1', '-b', '16', '-e', 'signed-integer', this._outputPath];

      this._process = spawn(recPath, args, { stdio: 'pipe' });
      return;
    }

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
