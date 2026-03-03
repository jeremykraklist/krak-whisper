const fs = require('fs');
const path = require('path');
const https = require('https');
const http = require('http');
const { app } = require('electron');

/**
 * @typedef {Object} ModelInfo
 * @property {string} name
 * @property {string} filename
 * @property {string} url
 * @property {number} size - Approximate size in MB
 */

/** Maximum number of HTTP redirects to follow */
const MAX_REDIRECTS = 5;

/** Download timeout in ms (10 minutes for large models) */
const DOWNLOAD_TIMEOUT_MS = 10 * 60 * 1000;

/** CDN base URL for model downloads */
const CDN_BASE = 'https://new.jeremiahkrakowski.com/models';

/** Allowed download hosts for security */
const ALLOWED_HOSTS = ['new.jeremiahkrakowski.com', 'jeremiahkrakowski.com'];

/** @type {ModelInfo[]} */
const AVAILABLE_MODELS = [
  {
    name: 'tiny.en',
    filename: 'ggml-tiny.en.bin',
    url: `${CDN_BASE}/ggml-tiny.en.bin`,
    size: 75,
  },
  {
    name: 'base.en',
    filename: 'ggml-base.en.bin',
    url: `${CDN_BASE}/ggml-base.en.bin`,
    size: 142,
  },
  {
    name: 'small.en',
    filename: 'ggml-small.en.bin',
    url: `${CDN_BASE}/ggml-small.en.bin`,
    size: 466,
  },
  {
    name: 'medium.en',
    filename: 'ggml-medium.en.bin',
    url: `${CDN_BASE}/ggml-medium.en.bin`,
    size: 1500,
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
   * Download a model from HuggingFace with redirect handling and timeouts.
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

      // Overall download timeout
      const overallTimeout = setTimeout(() => {
        reject(new Error(`Download timed out after ${DOWNLOAD_TIMEOUT_MS / 1000}s`));
      }, DOWNLOAD_TIMEOUT_MS);

      /**
       * Follow redirects manually with a redirect counter.
       * @param {string} url
       * @param {number} redirectCount
       */
      const download = (url, redirectCount = 0) => {
        if (redirectCount > MAX_REDIRECTS) {
          clearTimeout(overallTimeout);
          reject(new Error(`Too many redirects (>${MAX_REDIRECTS})`));
          return;
        }

        // Validate URL format (allow redirects to any host — CDN may redirect)
        try {
          new URL(url);
        } catch {
          clearTimeout(overallTimeout);
          reject(new Error(`Invalid redirect URL: ${url}`));
          return;
        }

        const client = url.startsWith('https') ? https : http;

        const req = client.get(url, { timeout: 30000 }, (response) => {
          // Handle redirects
          if (response.statusCode >= 300 && response.statusCode < 400 && response.headers.location) {
            response.resume(); // Drain the response
            download(response.headers.location, redirectCount + 1);
            return;
          }

          if (response.statusCode !== 200) {
            clearTimeout(overallTimeout);
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
              clearTimeout(overallTimeout);
              // Rename temp file to final name (atomic on most filesystems)
              try {
                fs.renameSync(tempPath, localPath);
                resolve(localPath);
              } catch (err) {
                reject(new Error(`Failed to save model: ${err.message}`));
              }
            });
          });

          file.on('error', (err) => {
            clearTimeout(overallTimeout);
            try {
              if (fs.existsSync(tempPath)) fs.unlinkSync(tempPath);
            } catch {
              // Ignore cleanup errors
            }
            reject(err);
          });
        });

        req.on('error', (err) => {
          clearTimeout(overallTimeout);
          reject(err);
        });

        req.on('timeout', () => {
          req.destroy(new Error('Connection timed out'));
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
