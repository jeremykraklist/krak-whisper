'use strict';

const https = require('https');
const http = require('http');
const fs = require('fs');
const path = require('path');
const log = require('electron-log');

/**
 * Available whisper.cpp models with HuggingFace download URLs.
 */
const MODELS = {
  tiny: {
    name: 'tiny',
    label: 'Tiny (~75 MB)',
    description: 'Fastest, lowest accuracy. Good for quick notes.',
    size: '75 MB',
    sizeBytes: 75 * 1024 * 1024,
    filename: 'ggml-tiny.bin',
    url: 'https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-tiny.bin',
  },
  'tiny.en': {
    name: 'tiny.en',
    label: 'Tiny English (~75 MB)',
    description: 'Fastest, English-only optimized.',
    size: '75 MB',
    sizeBytes: 75 * 1024 * 1024,
    filename: 'ggml-tiny.en.bin',
    url: 'https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-tiny.en.bin',
  },
  base: {
    name: 'base',
    label: 'Base (~142 MB)',
    description: 'Good balance of speed and accuracy. Recommended.',
    size: '142 MB',
    sizeBytes: 142 * 1024 * 1024,
    filename: 'ggml-base.bin',
    url: 'https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.bin',
  },
  'base.en': {
    name: 'base.en',
    label: 'Base English (~142 MB)',
    description: 'Good balance, English-only optimized.',
    size: '142 MB',
    sizeBytes: 142 * 1024 * 1024,
    filename: 'ggml-base.en.bin',
    url: 'https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.en.bin',
  },
  small: {
    name: 'small',
    label: 'Small (~466 MB)',
    description: 'High accuracy, slower. Best for detailed transcription.',
    size: '466 MB',
    sizeBytes: 466 * 1024 * 1024,
    filename: 'ggml-small.bin',
    url: 'https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.bin',
  },
  'small.en': {
    name: 'small.en',
    label: 'Small English (~466 MB)',
    description: 'High accuracy, English-only optimized.',
    size: '466 MB',
    sizeBytes: 466 * 1024 * 1024,
    filename: 'ggml-small.en.bin',
    url: 'https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.en.bin',
  },
};

class ModelManager {
  constructor(userDataPath) {
    this._modelsDir = path.join(userDataPath, 'models');
    fs.mkdirSync(this._modelsDir, { recursive: true });
  }

  /**
   * Get all available models with their download status.
   * @returns {Array<{ name: string, label: string, description: string, size: string, downloaded: boolean, path: string }>}
   */
  getAvailableModels() {
    return Object.values(MODELS).map((model) => {
      const modelPath = path.join(this._modelsDir, model.filename);
      const downloaded = fs.existsSync(modelPath);

      return {
        name: model.name,
        label: model.label,
        description: model.description,
        size: model.size,
        downloaded,
        path: modelPath,
      };
    });
  }

  /**
   * Get the file path for a specific model.
   * @param {string} modelName
   * @returns {string}
   */
  getModelPath(modelName) {
    const model = MODELS[modelName];
    if (!model) {
      throw new Error(`Unknown model: ${modelName}`);
    }
    return path.join(this._modelsDir, model.filename);
  }

  /**
   * Check if a model is downloaded.
   * @param {string} modelName
   * @returns {boolean}
   */
  isModelDownloaded(modelName) {
    const model = MODELS[modelName];
    if (!model) return false;
    return fs.existsSync(path.join(this._modelsDir, model.filename));
  }

  /**
   * Download a model from HuggingFace.
   * @param {string} modelName
   * @param {(progress: number) => void} onProgress - Progress callback (0-100)
   * @returns {Promise<string>} Path to downloaded model
   */
  async downloadModel(modelName, onProgress) {
    const model = MODELS[modelName];
    if (!model) {
      throw new Error(`Unknown model: ${modelName}`);
    }

    const outputPath = path.join(this._modelsDir, model.filename);
    const tempPath = `${outputPath}.tmp`;

    log.info(`Downloading model "${modelName}" from ${model.url}`);

    return new Promise((resolve, reject) => {
      const download = (url, redirectCount = 0) => {
        if (redirectCount > 5) {
          reject(new Error('Too many redirects'));
          return;
        }

        const client = url.startsWith('https') ? https : http;

        const req = client.get(url, {
          headers: {
            'User-Agent': 'KrakWhisper/0.1.0',
          },
        }, (res) => {
          // Handle redirects
          if (res.statusCode >= 300 && res.statusCode < 400 && res.headers.location) {
            log.info(`Redirect (${res.statusCode}) -> ${res.headers.location}`);
            download(res.headers.location, redirectCount + 1);
            return;
          }

          if (res.statusCode !== 200) {
            reject(new Error(`Download failed: HTTP ${res.statusCode}`));
            return;
          }

          const totalSize = parseInt(res.headers['content-length'], 10) || model.sizeBytes;
          let downloadedSize = 0;

          const fileStream = fs.createWriteStream(tempPath);

          res.on('data', (chunk) => {
            downloadedSize += chunk.length;
            const progress = Math.round((downloadedSize / totalSize) * 100);
            if (onProgress) onProgress(progress);
          });

          res.pipe(fileStream);

          fileStream.on('finish', () => {
            fileStream.close();
            // Rename temp file to final
            fs.renameSync(tempPath, outputPath);
            log.info(`Model "${modelName}" downloaded to ${outputPath}`);
            resolve(outputPath);
          });

          fileStream.on('error', (err) => {
            // Clean up temp file
            try { fs.unlinkSync(tempPath); } catch { /* ignore */ }
            reject(err);
          });
        });

        req.on('error', (err) => {
          try { fs.unlinkSync(tempPath); } catch { /* ignore */ }
          reject(err);
        });

        req.setTimeout(30000, () => {
          req.destroy();
          reject(new Error('Download timeout'));
        });
      };

      download(model.url);
    });
  }

  /**
   * Delete a downloaded model.
   * @param {string} modelName
   */
  async deleteModel(modelName) {
    const model = MODELS[modelName];
    if (!model) {
      throw new Error(`Unknown model: ${modelName}`);
    }

    const modelPath = path.join(this._modelsDir, model.filename);
    if (fs.existsSync(modelPath)) {
      fs.unlinkSync(modelPath);
      log.info(`Model "${modelName}" deleted`);
    }
  }
}

module.exports = { ModelManager };
