'use strict';

const { execFile } = require('child_process');
const path = require('path');
const fs = require('fs');
const log = require('electron-log');

/**
 * Audio recorder using platform-native tools.
 * On Windows: uses built-in PowerShell NAudio or ffmpeg.
 * Records 16kHz mono WAV (what whisper.cpp expects).
 */
class Recorder {
  constructor(tempDir) {
    this._tempDir = tempDir;
    this._process = null;
    this._outputPath = null;
    this._recording = false;
  }

  /**
   * Start recording audio to a temp WAV file.
   * Uses a PowerShell script on Windows that leverages NAudio or
   * falls back to a simple approach via the Web Audio API in the renderer.
   */
  async start() {
    if (this._recording) {
      throw new Error('Already recording');
    }

    this._outputPath = path.join(
      this._tempDir,
      `krakwhisper-${Date.now()}.wav`
    );

    this._recording = true;

    if (process.platform === 'win32') {
      await this._startWindowsRecording();
    } else {
      // On macOS/Linux, use sox if available, otherwise rely on renderer
      await this._startSoxRecording();
    }

    log.info(`Recording started: ${this._outputPath}`);
  }

  /**
   * Stop recording and return path to the WAV file.
   * @returns {Promise<string>} Path to recorded WAV file
   */
  async stop() {
    if (!this._recording) {
      throw new Error('Not recording');
    }

    this._recording = false;

    if (this._process) {
      // Send SIGTERM/SIGINT to stop the recording process
      if (process.platform === 'win32') {
        // On Windows, kill the process tree
        try {
          execFile('taskkill', ['/pid', String(this._process.pid), '/f', '/t']);
        } catch {
          this._process.kill();
        }
      } else {
        this._process.kill('SIGINT');
      }

      // Wait for process to finish
      await new Promise((resolve) => {
        const timeout = setTimeout(resolve, 3000);
        this._process.on('close', () => {
          clearTimeout(timeout);
          resolve();
        });
      });

      this._process = null;
    }

    if (!fs.existsSync(this._outputPath)) {
      throw new Error('Recording file not found');
    }

    log.info(`Recording stopped: ${this._outputPath}`);
    return this._outputPath;
  }

  /**
   * Write raw PCM audio data from the renderer (Web Audio API).
   * Called via IPC when using browser-based recording.
   * @param {Buffer} pcmData - Raw 16-bit PCM audio at 16kHz mono
   */
  writeFromRenderer(pcmData) {
    if (!this._outputPath) {
      this._outputPath = path.join(
        this._tempDir,
        `krakwhisper-${Date.now()}.wav`
      );
    }

    // Write WAV file from PCM data
    const wavHeader = this._createWavHeader(pcmData.length, 16000, 1, 16);
    const wavBuffer = Buffer.concat([wavHeader, pcmData]);
    fs.writeFileSync(this._outputPath, wavBuffer);

    return this._outputPath;
  }

  async _startWindowsRecording() {
    // PowerShell script to record audio using .NET System.Media
    // Falls back to ffmpeg if available
    const escapedOutputPath = this._outputPath
      .replace(/'/g, "''")
      .replace(/\\/g, '\\\\');
    const psScript = `
      $outputPath = '${escapedOutputPath}'
      
      # Try ffmpeg first (most reliable)
      $ffmpeg = Get-Command ffmpeg -ErrorAction SilentlyContinue
      if ($ffmpeg) {
        & ffmpeg -y -f dshow -i audio="Microphone" -ar 16000 -ac 1 -acodec pcm_s16le $outputPath
        exit
      }
      
      # Fallback: use Windows Audio Session API via PowerShell
      Add-Type -AssemblyName System.Speech
      Write-Host "RECORDING_STARTED"
      
      # Simple approach: record using .NET
      $waveIn = New-Object NAudio.Wave.WaveInEvent
      $waveIn.WaveFormat = New-Object NAudio.Wave.WaveFormat(16000, 16, 1)
      $writer = New-Object NAudio.Wave.WaveFileWriter($outputPath, $waveIn.WaveFormat)
      
      $waveIn.add_DataAvailable({
        param($sender, $e)
        $writer.Write($e.Buffer, 0, $e.BytesRecorded)
      })
      
      $waveIn.StartRecording()
      
      # Wait until killed
      while ($true) { Start-Sleep -Seconds 1 }
    `.trim();

    return new Promise((resolve, reject) => {
      let settled = false;

      this._process = execFile(
        'powershell.exe',
        ['-NoProfile', '-Command', psScript],
        { timeout: 0 },
        (error) => {
          // Process was killed to stop recording - that's expected
          if (error && error.killed) return;
          if (error) log.warn('PowerShell recording ended:', error.message);
        }
      );

      this._process.on('spawn', () => {
        // Process started successfully
        if (!settled) {
          settled = true;
          resolve();
        }
      });

      this._process.on('error', (err) => {
        if (!settled) {
          settled = true;
          reject(new Error(`Failed to start PowerShell recording: ${err.message}`));
        }
      });

      this._process.stdout?.on('data', (data) => {
        if (data.toString().includes('RECORDING_STARTED') && !settled) {
          settled = true;
          resolve();
        }
      });

      // Fallback timeout in case spawn event doesn't fire
      setTimeout(() => {
        if (!settled) {
          settled = true;
          resolve();
        }
      }, 2000);
    });
  }

  async _startSoxRecording() {
    // Use sox (rec command) on macOS/Linux
    return new Promise((resolve, reject) => {
      let settled = false;

      this._process = execFile(
        'rec',
        [
          '-r', '16000',     // 16kHz sample rate
          '-c', '1',         // Mono
          '-b', '16',        // 16-bit
          '-e', 'signed',    // Signed integer
          this._outputPath,
        ],
        { timeout: 0 },
        (error) => {
          if (error && error.killed) return;
          if (error) {
            log.warn('sox recording ended:', error.message);
          }
        }
      );

      this._process.on('spawn', () => {
        if (!settled) {
          settled = true;
          resolve();
        }
      });

      this._process.on('error', (err) => {
        if (!settled) {
          settled = true;
          reject(new Error(`Failed to start sox recording: ${err.message}`));
        }
      });

      this._process.stderr?.on('data', (data) => {
        log.info(`sox: ${data}`);
      });

      // Fallback timeout
      setTimeout(() => {
        if (!settled) {
          settled = true;
          resolve();
        }
      }, 1000);
    });
  }

  /**
   * Create a WAV file header.
   * @param {number} dataLength - Length of PCM data in bytes
   * @param {number} sampleRate - Sample rate in Hz
   * @param {number} numChannels - Number of channels
   * @param {number} bitsPerSample - Bits per sample
   * @returns {Buffer}
   */
  _createWavHeader(dataLength, sampleRate, numChannels, bitsPerSample) {
    const byteRate = sampleRate * numChannels * (bitsPerSample / 8);
    const blockAlign = numChannels * (bitsPerSample / 8);
    const header = Buffer.alloc(44);

    // RIFF header
    header.write('RIFF', 0);
    header.writeUInt32LE(36 + dataLength, 4);
    header.write('WAVE', 8);

    // fmt subchunk
    header.write('fmt ', 12);
    header.writeUInt32LE(16, 16);           // Subchunk1Size (PCM)
    header.writeUInt16LE(1, 20);            // AudioFormat (PCM = 1)
    header.writeUInt16LE(numChannels, 22);
    header.writeUInt32LE(sampleRate, 24);
    header.writeUInt32LE(byteRate, 28);
    header.writeUInt16LE(blockAlign, 32);
    header.writeUInt16LE(bitsPerSample, 34);

    // data subchunk
    header.write('data', 36);
    header.writeUInt32LE(dataLength, 40);

    return header;
  }
}

module.exports = { Recorder };
