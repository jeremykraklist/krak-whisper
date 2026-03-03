/**
 * AudioRecorder — Records audio from the microphone.
 *
 * Platform recording strategy (in order of preference):
 *
 * Windows:
 *   1. ffmpeg (in bin/ dir or on PATH) — best quality
 *   2. PowerShell mciSendString — built-in Windows API, no deps needed
 *
 * macOS: sox/rec or ffmpeg
 * Linux: arecord or ffmpeg
 *
 * All output is 16kHz mono 16-bit signed integer WAV for whisper.cpp.
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
    /** @type {'ffmpeg' | 'mci' | 'sox' | 'arecord' | null} */
    this._recordingMethod = null;
    /** @type {string | null} Override mic device name */
    this._selectedMic = null;
  }

  /** Set the microphone device to use (null = auto-detect) */
  setMicrophone(deviceName) {
    this._selectedMic = deviceName || null;
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

    if (this._recordingMethod === 'mci') {
      // For MCI recording, we need to send the stop command via PowerShell
      await this._stopMciRecording();
    } else {
      // For ffmpeg/sox/arecord, kill the process
      const proc = this._process;
      this._process = null;

      if (proc) {
        const exitPromise = new Promise((resolve) => {
          proc.on('exit', () => resolve(undefined));
          setTimeout(() => {
            try { proc.kill('SIGKILL'); } catch { /* already dead */ }
            resolve(undefined);
          }, 3000);
        });

        if (process.platform === 'win32') {
          // For ffmpeg on Windows, send 'q' to stdin for graceful stop
          try {
            if (proc.stdin && proc.stdin.writable) {
              proc.stdin.write('q');
            }
          } catch { /* ignore */ }
          // Give it a moment to finalize the file
          await new Promise((r) => setTimeout(r, 500));
          try { proc.kill('SIGTERM'); } catch { /* ignore */ }
        } else {
          try { proc.kill('SIGINT'); } catch { /* ignore */ }
        }

        await exitPromise;
      }
    }

    this._recordingMethod = null;

    // Read and convert WAV file
    if (this._outputPath && fs.existsSync(this._outputPath)) {
      try {
        const wavData = fs.readFileSync(this._outputPath);

        // Check if the file is too small (no audio data)
        if (wavData.length < 100) {
          console.error('WAV file too small, likely no audio captured');
          return Buffer.alloc(0);
        }

        const decoded = wav.decode(wavData);

        // Convert Float32 channel data to 16-bit PCM Buffer
        const channelData = decoded.channelData[0]; // mono channel
        const pcmBuffer = Buffer.alloc(channelData.length * 2);
        for (let i = 0; i < channelData.length; i++) {
          const sample = Math.max(-1, Math.min(1, channelData[i]));
          pcmBuffer.writeInt16LE(Math.round(sample * 32767), i * 2);
        }

        // If the sample rate isn't 16kHz, whisper.cpp may not handle it well
        // but the WAV header will specify the correct rate
        if (decoded.sampleRate !== 16000) {
          console.warn(`Audio sample rate is ${decoded.sampleRate}Hz, expected 16000Hz. Whisper may still work.`);
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
   * Record on Windows using ffmpeg or built-in MCI (mciSendString).
   */
  async _startWindowsRecording() {
    // Strategy 1: Check for ffmpeg in bin/ directory (bundled with app)
    const binDir = this._getBinDir();
    const bundledFfmpeg = path.join(binDir, 'ffmpeg.exe');
    if (fs.existsSync(bundledFfmpeg)) {
      await this._startFfmpegRecording(bundledFfmpeg);
      return;
    }

    // Strategy 2: Check for ffmpeg on PATH
    const systemFfmpeg = await this._findExecutable('ffmpeg');
    if (systemFfmpeg) {
      await this._startFfmpegRecording(systemFfmpeg);
      return;
    }

    // Strategy 3: PowerShell with built-in Windows mciSendString API
    // No external deps needed — uses winmm.dll which is part of Windows
    await this._startMciRecording();
  }

  /**
   * Start recording with ffmpeg on Windows (dshow).
   * @param {string} ffmpegPath
   */
  async _startFfmpegRecording(ffmpegPath) {
    const deviceName = this._selectedMic || await this._getWindowsAudioDevice(ffmpegPath);
    this._recordingMethod = 'ffmpeg';
    console.log('[audio] Starting ffmpeg recording with device:', deviceName);
    console.log('[audio] Output path:', this._outputPath);

    this._process = spawn(ffmpegPath, [
      '-y',
      '-f', 'dshow',
      '-i', `audio=${deviceName}`,
      '-ar', '16000',
      '-ac', '1',
      '-sample_fmt', 's16',
      this._outputPath,
    ], {
      stdio: ['pipe', 'pipe', 'pipe'],
    });

    // Log ffmpeg stderr for debugging
    this._process.stderr.on('data', (data) => {
      const msg = data.toString().trim();
      if (msg && !msg.includes('configuration:') && !msg.includes('libav')) {
        console.log('[ffmpeg]', msg.substring(0, 200));
      }
    });

    this._process.on('error', (err) => {
      console.error('[audio] ffmpeg process error:', err.message);
    });

    // Wait a moment for ffmpeg to initialize
    await new Promise((resolve) => setTimeout(resolve, 500));
  }

  /**
   * Start recording with Windows MCI (built-in, no deps).
   * Uses mciSendString from winmm.dll — available on all Windows versions.
   */
  async _startMciRecording() {
    this._recordingMethod = 'mci';
    const escapedPath = this._outputPath.replace(/\\/g, '\\\\');

    const psScript = `
Add-Type @"
using System;
using System.Runtime.InteropServices;
using System.Text;

public class MciRecorder {
    [DllImport("winmm.dll", CharSet = CharSet.Unicode)]
    private static extern int mciSendString(string command, StringBuilder returnValue, int returnLength, IntPtr hwnd);

    public static string SendCommand(string command) {
        var sb = new StringBuilder(256);
        int result = mciSendString(command, sb, 256, IntPtr.Zero);
        if (result != 0) {
            var errSb = new StringBuilder(256);
            mciSendString("close recsound", errSb, 256, IntPtr.Zero);
            throw new Exception("MCI error " + result + " for command: " + command);
        }
        return sb.ToString();
    }
}
"@

[MciRecorder]::SendCommand("open new type waveaudio alias recsound")
[MciRecorder]::SendCommand("set recsound time format ms")
[MciRecorder]::SendCommand("set recsound bitspersample 16")
[MciRecorder]::SendCommand("set recsound samplespersec 16000")
[MciRecorder]::SendCommand("set recsound channels 1")
[MciRecorder]::SendCommand("record recsound")

Write-Host "MCI_RECORDING_STARTED"

# Keep the process alive until parent kills it or we receive stop signal
# The parent will run a separate PowerShell to stop+save
while ($true) { Start-Sleep -Seconds 60 }
`;

    this._process = spawn('powershell', ['-NoProfile', '-NonInteractive', '-Command', psScript], {
      stdio: ['pipe', 'pipe', 'pipe'],
    });

    // Wait for recording to start
    await new Promise((resolve, reject) => {
      let output = '';
      const timeout = setTimeout(() => {
        reject(new Error('MCI recording failed to start within 5 seconds'));
      }, 5000);

      this._process.stdout.on('data', (data) => {
        output += data.toString();
        if (output.includes('MCI_RECORDING_STARTED')) {
          clearTimeout(timeout);
          resolve();
        }
      });

      this._process.stderr.on('data', (data) => {
        const errText = data.toString();
        if (errText.includes('Exception') || errText.includes('error')) {
          clearTimeout(timeout);
          reject(new Error(`MCI recording error: ${errText}`));
        }
      });

      this._process.on('exit', (code) => {
        if (code !== 0) {
          clearTimeout(timeout);
          reject(new Error(`MCI recording process exited with code ${code}`));
        }
      });
    });
  }

  /**
   * Stop MCI recording and save the WAV file.
   */
  async _stopMciRecording() {
    const escapedPath = this._outputPath.replace(/\\/g, '\\\\');

    // Kill the recording process first
    if (this._process) {
      try { this._process.kill('SIGTERM'); } catch { /* ignore */ }
      this._process = null;
    }

    // Run a separate PowerShell to stop and save
    const psStopScript = `
Add-Type @"
using System;
using System.Runtime.InteropServices;
using System.Text;

public class MciStopper {
    [DllImport("winmm.dll", CharSet = CharSet.Unicode)]
    private static extern int mciSendString(string command, StringBuilder returnValue, int returnLength, IntPtr hwnd);

    public static void SendCommand(string command) {
        var sb = new StringBuilder(256);
        mciSendString(command, sb, 256, IntPtr.Zero);
    }
}
"@

[MciStopper]::SendCommand("stop recsound")
[MciStopper]::SendCommand("save recsound ${escapedPath}")
[MciStopper]::SendCommand("close recsound")
Write-Host "MCI_SAVED"
`;

    await new Promise((resolve, reject) => {
      execFile('powershell', ['-NoProfile', '-NonInteractive', '-Command', psStopScript], {
        timeout: 10000,
      }, (err, stdout, stderr) => {
        if (err) {
          console.error('MCI stop error:', err.message, stderr);
          // Don't reject — the file might still have been saved
        }
        resolve();
      });
    });

    // Give filesystem a moment to sync
    await new Promise((r) => setTimeout(r, 200));
  }

  /**
   * Enumerate Windows audio devices via ffmpeg.
   * @param {string} ffmpegPath
   * @returns {Promise<string>}
   */
  _getWindowsAudioDevice(ffmpegPath) {
    return new Promise((resolve) => {
      execFile(ffmpegPath, ['-list_devices', 'true', '-f', 'dshow', '-i', 'dummy'], {
        timeout: 5000,
      }, (_error, _stdout, stderr) => {
        const output = stderr || '';
        const lines = output.split('\n');

        // Strategy 1: Look for lines with (audio) suffix (newer ffmpeg)
        for (const line of lines) {
          if (line.includes('(audio)')) {
            const match = line.match(/"([^"]+)"/);
            if (match) {
              console.log('[audio] Found audio device:', match[1]);
              resolve(match[1]);
              return;
            }
          }
        }

        // Strategy 2: Look for "DirectShow audio devices" section (older ffmpeg)
        let inAudio = false;
        for (const line of lines) {
          if (line.includes('DirectShow audio devices')) {
            inAudio = true;
            continue;
          }
          if (inAudio && line.includes('"')) {
            const match = line.match(/"([^"]+)"/);
            if (match) {
              console.log('[audio] Found audio device (legacy):', match[1]);
              resolve(match[1]);
              return;
            }
          }
          if (inAudio && line.includes('DirectShow video devices')) {
            break;
          }
        }

        console.error('[audio] No audio device found! ffmpeg output:', output.substring(0, 500));
        resolve('Microphone');
      });
    });
  }

  /**
   * Record on macOS using sox/rec or ffmpeg.
   */
  async _startMacRecording() {
    const recPath = await this._findExecutable('rec') || await this._findExecutable('sox');

    if (recPath) {
      this._recordingMethod = 'sox';
      const args = recPath.includes('sox')
        ? ['-d', '-r', '16000', '-c', '1', '-b', '16', '-e', 'signed-integer', this._outputPath]
        : ['-r', '16000', '-c', '1', '-b', '16', '-e', 'signed-integer', this._outputPath];

      this._process = spawn(recPath, args, { stdio: 'pipe' });
      return;
    }

    const ffmpegPath = await this._findExecutable('ffmpeg');
    if (ffmpegPath) {
      this._recordingMethod = 'ffmpeg';
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
      this._recordingMethod = 'arecord';
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
      this._recordingMethod = 'ffmpeg';
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
   * Get the app's bin/ directory path.
   * @returns {string}
   */
  _getBinDir() {
    try {
      const isDev = !require('electron').app.isPackaged;
      if (isDev) {
        return path.join(__dirname, '..', 'bin');
      }
      return path.join(process.resourcesPath, 'bin');
    } catch {
      return path.join(__dirname, '..', 'bin');
    }
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
          resolve(stdout.trim().split('\n')[0].trim());
        }
      });
    });
  }
}

module.exports = { AudioRecorder };
