const { execFile } = require('child_process');
const path = require('path');
const fs = require('fs');
const os = require('os');

/**
 * WhisperEngine — Transcribes audio using the whisper.cpp binary.
 *
 * Strategy: We ship a pre-built `whisper-cpp` binary (or build from source)
 * inside `electron/bin/`. The engine writes the audio buffer to a temp WAV file,
 * runs whisper.cpp CLI against it, and returns the transcribed text.
 *
 * For distribution, the whisper.cpp binary is bundled via electron-builder's
 * `extraResources` config. Users can also supply their own binary path.
 */
class WhisperEngine {
  /**
   * @param {import('./model-manager').ModelManager} modelManager
   */
  constructor(modelManager) {
    this.modelManager = modelManager;
  }

  /**
   * Transcribe a PCM audio buffer (16-bit, 16kHz, mono).
   * @param {Buffer} audioBuffer - Raw PCM audio data
   * @param {string} modelName - Name of the model to use (e.g. 'tiny.en')
   * @returns {Promise<string>} Transcribed text
   */
  async transcribe(audioBuffer, modelName) {
    const modelPath = this.modelManager.getModelPath(modelName);
    if (!modelPath) {
      throw new Error(`Model "${modelName}" not found. Please download it first.`);
    }

    // Write audio to temp WAV file
    const tempDir = os.tmpdir();
    const wavPath = path.join(tempDir, `krakwhisper-${Date.now()}.wav`);

    try {
      this._writeWav(wavPath, audioBuffer);
      const text = await this._runWhisper(wavPath, modelPath);
      return text;
    } finally {
      // Clean up temp file
      try {
        if (fs.existsSync(wavPath)) fs.unlinkSync(wavPath);
      } catch {
        // Ignore cleanup errors
      }
    }
  }

  /**
   * Write PCM audio data as a WAV file (16-bit, 16kHz, mono).
   * @param {string} filePath
   * @param {Buffer} pcmData
   */
  _writeWav(filePath, pcmData) {
    const sampleRate = 16000;
    const numChannels = 1;
    const bitsPerSample = 16;
    const byteRate = sampleRate * numChannels * (bitsPerSample / 8);
    const blockAlign = numChannels * (bitsPerSample / 8);
    const dataSize = pcmData.length;
    const headerSize = 44;

    const buffer = Buffer.alloc(headerSize + dataSize);

    // RIFF header
    buffer.write('RIFF', 0);
    buffer.writeUInt32LE(36 + dataSize, 4);
    buffer.write('WAVE', 8);

    // fmt chunk
    buffer.write('fmt ', 12);
    buffer.writeUInt32LE(16, 16); // chunk size
    buffer.writeUInt16LE(1, 20); // PCM format
    buffer.writeUInt16LE(numChannels, 22);
    buffer.writeUInt32LE(sampleRate, 24);
    buffer.writeUInt32LE(byteRate, 28);
    buffer.writeUInt16LE(blockAlign, 32);
    buffer.writeUInt16LE(bitsPerSample, 34);

    // data chunk
    buffer.write('data', 36);
    buffer.writeUInt32LE(dataSize, 40);
    pcmData.copy(buffer, headerSize);

    fs.writeFileSync(filePath, buffer);
  }

  /**
   * Run whisper.cpp binary and return transcribed text.
   * @param {string} wavPath - Path to WAV file
   * @param {string} modelPath - Path to model file
   * @returns {Promise<string>}
   */
  _runWhisper(wavPath, modelPath) {
    return new Promise((resolve, reject) => {
      const binaryPath = this._getWhisperBinaryPath();

      if (!fs.existsSync(binaryPath)) {
        reject(new Error(
          `whisper.cpp binary not found at ${binaryPath}. ` +
          'Please place the whisper-cpp binary in the bin/ directory.'
        ));
        return;
      }

      const args = [
        '--model', modelPath,
        '--file', wavPath,
        '--output-txt',
        '--no-timestamps',
        '--language', 'en',
        '--threads', String(Math.max(1, Math.min(os.cpus().length - 1, 4))),
      ];

      execFile(binaryPath, args, { timeout: 60000 }, (error, stdout, stderr) => {
        if (error) {
          reject(new Error(`Whisper transcription failed: ${error.message}\n${stderr}`));
          return;
        }

        // whisper.cpp outputs text to stdout, sometimes with leading/trailing whitespace
        const text = stdout.trim();

        // Also check for .txt output file (whisper.cpp sometimes writes to file)
        const txtPath = wavPath + '.txt';
        if (!text && fs.existsSync(txtPath)) {
          const fileText = fs.readFileSync(txtPath, 'utf-8').trim();
          try { fs.unlinkSync(txtPath); } catch { /* ignore */ }
          resolve(fileText);
          return;
        }

        resolve(text);
      });
    });
  }

  /**
   * Get path to the whisper.cpp binary.
   * In development: electron/bin/whisper-cpp.exe
   * In production: resources/bin/whisper-cpp.exe
   * @returns {string}
   */
  _getWhisperBinaryPath() {
    const isDev = !require('electron').app.isPackaged;
    const binaryName = process.platform === 'win32' ? 'whisper-cpp.exe' : 'whisper-cpp';

    if (isDev) {
      return path.join(__dirname, '..', 'bin', binaryName);
    }

    return path.join(process.resourcesPath, 'bin', binaryName);
  }
}

module.exports = { WhisperEngine };
