'use strict';

/**
 * KrakWhisper Settings Renderer
 * Communicates with main process via the krakwhisper bridge API.
 */

const api = window.krakwhisper;

// DOM Elements
const statusDot = document.getElementById('status-dot');
const statusText = document.getElementById('status-text');
const recordBtn = document.getElementById('record-btn');
const modelsList = document.getElementById('models-list');
const modelSelect = document.getElementById('model-select');
const hotkeyInput = document.getElementById('hotkey-input');
const autoClipboard = document.getElementById('auto-clipboard');
const showNotification = document.getElementById('show-notification');
const launchStartup = document.getElementById('launch-startup');
const transcriptionSection = document.getElementById('transcription-section');
const transcriptionText = document.getElementById('transcription-text');

let isRecording = false;
let downloadingModels = new Set();

// ─── Initialize ────────────────────────────────────────────────

async function init() {
  await loadSettings();
  await loadModels();
  await updateRecordingState();
  setupEventListeners();
}

// ─── Settings ──────────────────────────────────────────────────

async function loadSettings() {
  const settings = await api.getSettings();

  hotkeyInput.value = settings.hotkey || 'Ctrl+Shift+Space';
  autoClipboard.checked = settings.autoClipboard !== false;
  showNotification.checked = settings.showNotification !== false;
  launchStartup.checked = settings.launchOnStartup === true;
}

// ─── Models ────────────────────────────────────────────────────

async function loadModels() {
  const models = await api.getModels();
  const settings = await api.getSettings();

  // Populate model selector (only downloaded models)
  modelSelect.innerHTML = '';
  const downloadedModels = models.filter((m) => m.downloaded);

  if (downloadedModels.length === 0) {
    const opt = document.createElement('option');
    opt.textContent = 'No models downloaded';
    opt.disabled = true;
    modelSelect.appendChild(opt);
  } else {
    downloadedModels.forEach((model) => {
      const opt = document.createElement('option');
      opt.value = model.name;
      opt.textContent = model.label;
      opt.selected = model.name === settings.model;
      modelSelect.appendChild(opt);
    });
  }

  // Render model cards
  modelsList.innerHTML = '';
  models.forEach((model) => {
    const card = document.createElement('div');
    card.className = 'model-card';
    card.id = `model-${model.name}`;

    const info = document.createElement('div');
    info.className = 'model-info';

    const name = document.createElement('div');
    name.className = 'model-name';
    name.textContent = model.label;

    const desc = document.createElement('div');
    desc.className = 'model-desc';
    desc.textContent = model.description;

    info.appendChild(name);
    info.appendChild(desc);

    const actions = document.createElement('div');
    actions.className = 'model-actions';

    if (model.downloaded) {
      const badge = document.createElement('span');
      badge.className = 'model-badge';
      badge.textContent = '✓ Ready';
      actions.appendChild(badge);

      const deleteBtn = document.createElement('button');
      deleteBtn.className = 'btn btn-outline btn-sm';
      deleteBtn.textContent = '🗑️';
      deleteBtn.title = 'Delete model';
      deleteBtn.onclick = () => deleteModel(model.name);
      actions.appendChild(deleteBtn);
    } else if (downloadingModels.has(model.name)) {
      const progress = document.createElement('div');
      progress.className = 'progress-bar';
      const fill = document.createElement('div');
      fill.className = 'progress-fill';
      fill.id = `progress-${model.name}`;
      fill.style.width = '0%';
      progress.appendChild(fill);
      actions.appendChild(progress);
    } else {
      const dlBtn = document.createElement('button');
      dlBtn.className = 'btn btn-primary btn-sm';
      dlBtn.textContent = '⬇ Download';
      dlBtn.onclick = () => downloadModel(model.name);
      actions.appendChild(dlBtn);
    }

    card.appendChild(info);
    card.appendChild(actions);
    modelsList.appendChild(card);
  });
}

async function downloadModel(modelName) {
  downloadingModels.add(modelName);
  await loadModels(); // Re-render to show progress bar

  const result = await api.downloadModel(modelName);

  downloadingModels.delete(modelName);

  if (result.success) {
    await loadModels(); // Re-render to show as downloaded
  } else {
    alert(`Download failed: ${result.error}`);
    await loadModels();
  }
}

async function deleteModel(modelName) {
  if (!confirm(`Delete the "${modelName}" model? You'll need to re-download it.`)) {
    return;
  }

  const result = await api.deleteModel(modelName);
  if (result.success) {
    await loadModels();
  } else {
    alert(`Delete failed: ${result.error}`);
  }
}

// ─── Recording ─────────────────────────────────────────────────

async function updateRecordingState() {
  isRecording = await api.getRecordingState();
  updateStatusUI();
}

function updateStatusUI() {
  statusDot.className = 'status-dot';

  if (isRecording) {
    statusDot.classList.add('recording');
    statusText.textContent = 'Recording...';
    recordBtn.textContent = '⏹ Stop Recording';
    recordBtn.classList.add('btn-danger');
    recordBtn.classList.remove('btn-primary');
  } else {
    statusDot.classList.add('idle');
    statusText.textContent = 'Idle';
    recordBtn.textContent = '🎤 Start Recording';
    recordBtn.classList.add('btn-primary');
    recordBtn.classList.remove('btn-danger');
  }
}

// ─── Event Listeners ───────────────────────────────────────────

function setupEventListeners() {
  // Record button
  recordBtn.addEventListener('click', async () => {
    await api.toggleRecording();
    isRecording = !isRecording;
    updateStatusUI();
  });

  // Model selection
  modelSelect.addEventListener('change', () => {
    api.setSetting('model', modelSelect.value);
  });

  // Hotkey input — capture key combination
  hotkeyInput.addEventListener('keydown', (e) => {
    e.preventDefault();
    e.stopPropagation();

    const parts = [];
    if (e.ctrlKey) parts.push('Ctrl');
    if (e.altKey) parts.push('Alt');
    if (e.shiftKey) parts.push('Shift');
    if (e.metaKey) parts.push('Super');

    // Only accept if there's a non-modifier key
    const key = e.key;
    if (!['Control', 'Alt', 'Shift', 'Meta'].includes(key)) {
      parts.push(key === ' ' ? 'Space' : key.length === 1 ? key.toUpperCase() : key);
      const hotkey = parts.join('+');
      hotkeyInput.value = hotkey;
      api.setSetting('hotkey', hotkey);
    }
  });

  // Checkboxes
  autoClipboard.addEventListener('change', () => {
    api.setSetting('autoClipboard', autoClipboard.checked);
  });

  showNotification.addEventListener('change', () => {
    api.setSetting('showNotification', showNotification.checked);
  });

  launchStartup.addEventListener('change', () => {
    api.setSetting('launchOnStartup', launchStartup.checked);
  });

  // Listen for download progress
  api.onDownloadProgress(({ modelName, progress }) => {
    const fill = document.getElementById(`progress-${modelName}`);
    if (fill) {
      fill.style.width = `${progress}%`;
    }
  });

  // Listen for transcription results
  api.onTranscriptionResult((text) => {
    transcriptionSection.style.display = 'block';
    transcriptionText.textContent = text;
    isRecording = false;
    updateStatusUI();
  });
}

// ─── Boot ──────────────────────────────────────────────────────

document.addEventListener('DOMContentLoaded', init);
