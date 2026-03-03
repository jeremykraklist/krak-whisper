const fs = require('fs');
const path = require('path');
const https = require('https');
const { app } = require('electron');

/**
 * @typedef {Object} ModelInfo
 * @property {string} name
 * @property {string} filename
 * @property {string} url
 * @property {number} size - Approximate size in MB
 */

/** @type {ModelInfo[]} */
const AVAILABLE_MODELS = [
  {
    name: 'tiny.en',
    filename: 'ggml-tiny.en.bin',
    url: 'https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-tiny.en.bin',
    size: 75,
  },
  {
    name: 'base.en',
    filename: 'ggml-base.en.bin',
    url: 'https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.en.bin',
    size: 142,
  },
  {
    name: 'small.en',
    filename: 'ggml-small.en.bin',
    url: 'https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.en.bin',
    size: 466,
  },
];

class ModelManager {
  constructor() {
    this.modelsDir = path.join(app.getPath('userData'), 'models');
    this._ensureModelsDir();
  }

  _ensureModelsDir() {
    if (!fs.existsSync(this.modelsDir)) {
      fs.mkdirSync(this.modelsDir, { recursive: true });
    }
  }

  /**
   * Get list of all available models with their download status.
   * @returns {Array<ModelInfo & { downloaded: boolean, localPath: string }>}
   */
  getAvailableModels() {
    return AVAILABLE_MODELS.map((model) => ({
      ...model,
      downloaded: this._isDownloaded(model.filename),
      localPath: path.join(this.modelsDir, model.filename),
    }));
  }

  /**
   * Get list of downloaded model names.
   * @returns {Promise<string[]>}
   */
  async getDownloadedModels() {
    return AVAILABLE_MODELS
      .filter((m) => this._isDownloaded(m.filename))
      .map((m) => m.name);
  }

  /**
   * Check if a model is downloaded.
   * @param {string} modelName
   * @returns {Promise<boolean>}
   */
  async isModelDownloaded(modelName) {
    const model = AVAILABLE_MODELS.find((m) => m.name === modelName);
    if (!model) return false;
    return this._isDownloaded(model.filename);
  }

  /**
   * Get the local path for a model.
   * @param {string} modelName
   * @returns {string | null}
   */
  getModelPath(modelName) {
    const model = AVAILABLE_MODELS.find((m) => m.name === modelName);
    if (!model) return null;
    const localPath = path.join(this.modelsDir, model.filename);
    return fs.existsSync(localPath) ? localPath : null;
  }

  /**
   * Download a model from HuggingFace.
   * @param {string} modelName
   * @param {(progress: number) => void} onProgress - Progress callback (0-100)
   * @returns {Promise<string>} Local path to downloaded model
   */
  downloadModel(modelName, onProgress) {
    return new Promise((resolve, reject) => {
      const model = AVAILABLE_MODELS.find((m) => m.name === modelName);
      if (!model) {
        reject(new Error(`Unknown model: ${modelName}`));
        return;
      }

      const localPath = path.join(this.modelsDir, model.filename);
      const tempPath = localPath + '.download';

      // Follow redirects manually
      const download = (url) => {
        https.get(url, (response) => {
          // Handle redirects
          if (response.statusCode >= 300 && response.statusCode < 400 && response.headers.location) {
            download(response.headers.location);
            return;
          }

          if (response.statusCode !== 200) {
            reject(new Error(`Download failed with status ${response.statusCode}`));
            return;
          }

          const totalSize = parseInt(response.headers['content-length'] || '0', 10);
          let downloadedSize = 0;
          const file = fs.createWriteStream(tempPath);

          response.on('data', (chunk) => {
            downloadedSize += chunk.length;
            if (totalSize > 0 && onProgress) {
              onProgress(Math.round((downloadedSize / totalSize) * 100));
            }
          });

          response.pipe(file);

          file.on('finish', () => {
            file.close(() => {
              // Rename temp file to final name
              fs.renameSync(tempPath, localPath);
              resolve(localPath);
            });
          });

          file.on('error', (err) => {
            fs.unlinkSync(tempPath).catch(() => {});
            reject(err);
          });
        }).on('error', (err) => {
          reject(err);
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
    const model = AVAILABLE_MODELS.find((m) => m.name === modelName);
    if (!model) throw new Error(`Unknown model: ${modelName}`);

    const localPath = path.join(this.modelsDir, model.filename);
    if (fs.existsSync(localPath)) {
      fs.unlinkSync(localPath);
    }
  }

  /**
   * @param {string} filename
   * @returns {boolean}
   */
  _isDownloaded(filename) {
    const localPath = path.join(this.modelsDir, filename);
    return fs.existsSync(localPath);
  }
}

module.exports = { ModelManager, AVAILABLE_MODELS };
