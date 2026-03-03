const { execFile } = require('child_process');
const path = require('path');
const fs = require('fs');
const os = require('os');

/**
 * WhisperEngine — Transcribes audio using the whisper-cli.exe binary.
 *
 * Uses the pre-built whisper.cpp CLI binary to transcribe WAV audio files.
 * The binary is bundled in `electron/bin/` along with required DLLs
 * (whisper.dll, ggml-cpu.dll).
 *
 * Usage: whisper-cli.exe -m <model.bin> -f <audio.wav> --no-gpu -t 8
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
   * @param {string} modelName - Name of the model to use (e.g. 'small.en')
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
      // Clean up temp files
      for (const tempFile of [wavPath, wavPath + '.txt']) {
        try {
          if (fs.existsSync(tempFile)) fs.unlinkSync(tempFile);
        } catch {
          // Ignore cleanup errors
        }
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
   * Run whisper-cli.exe and return transcribed text.
   * @param {string} wavPath - Path to WAV file
   * @param {string} modelPath - Path to model file
   * @returns {Promise<string>}
   */
  _runWhisper(wavPath, modelPath) {
    return new Promise((resolve, reject) => {
      const binaryPath = this._getWhisperBinaryPath();
      const binDir = path.dirname(binaryPath);

      if (!fs.existsSync(binaryPath)) {
        reject(new Error(
          `whisper-cli binary not found at ${binaryPath}. ` +
          'Please place whisper-cli.exe and its DLLs in the bin/ directory.'
        ));
        return;
      }

      // Use 8 threads and CPU-only mode (--no-gpu)
      const threadCount = Math.max(4, Math.min(os.cpus().length, 8));
      const args = [
        '-m', modelPath,
        '-f', wavPath,
        '--no-gpu',
        '-t', String(threadCount),
        '--no-timestamps',
        '-l', 'en',
      ];

      // Set PATH to include bin dir so DLLs are found
      const env = { ...process.env };
      if (process.platform === 'win32') {
        env.PATH = binDir + ';' + (env.PATH || '');
      }

      execFile(binaryPath, args, {
        timeout: 120000, // 2 minute timeout for larger models
        env,
        cwd: binDir, // Run from bin dir so DLLs are found
      }, (error, stdout, stderr) => {
        if (error) {
          reject(new Error(`Whisper transcription failed: ${error.message}\n${stderr || ''}`));
          return;
        }

        // whisper.cpp outputs text to stdout
        let text = stdout.trim();

        // Filter out whisper.cpp log lines (they start with timestamps like [00:00:00.000 --> ...])
        // and system info lines
        const lines = text.split('\n');
        const transcriptionLines = lines.filter((line) => {
          const trimmed = line.trim();
          // Skip empty lines and whisper.cpp metadata
          if (!trimmed) return false;
          if (trimmed.startsWith('whisper_')) return false;
          if (trimmed.startsWith('system_info:')) return false;
          if (trimmed.startsWith('main:')) return false;
          if (trimmed.startsWith('output_')) return false;
          return true;
        });

        // Remove timestamp prefixes like [00:00:00.000 --> 00:00:05.000]
        text = transcriptionLines
          .map((line) => line.replace(/^\s*\[\d{2}:\d{2}:\d{2}\.\d{3}\s*-->\s*\d{2}:\d{2}:\d{2}\.\d{3}\]\s*/, ''))
          .join(' ')
          .trim();

        // Also check for .txt output file
        const txtPath = wavPath + '.txt';
        if (fs.existsSync(txtPath)) {
          const fileText = fs.readFileSync(txtPath, 'utf-8').trim();
          if (!text && fileText) {
            text = fileText;
          }
        }

        resolve(text);
      });
    });
  }

  /**
   * Get path to the whisper-cli binary.
   * In development: electron/bin/whisper-cli.exe
   * In production: resources/bin/whisper-cli.exe
   * @returns {string}
   */
  _getWhisperBinaryPath() {
    const isDev = !require('electron').app.isPackaged;
    const binaryName = process.platform === 'win32' ? 'whisper-cli.exe' : 'whisper-cli';

    if (isDev) {
      return path.join(__dirname, '..', 'bin', binaryName);
    }

    return path.join(process.resourcesPath, 'bin', binaryName);
  }
}

module.exports = { WhisperEngine };
