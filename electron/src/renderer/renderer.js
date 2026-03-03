// ─── DOM Elements ────────────────────────────────────────────────────
const recordBtn = document.getElementById('record-btn');
const recordIcon = document.getElementById('record-icon');
const recordStatus = document.getElementById('record-status');
const transcriptionOutput = document.getElementById('transcription-output');
const copyBtn = document.getElementById('copy-btn');
const clearBtn = document.getElementById('clear-btn');
const modelIndicator = document.getElementById('model-indicator');
const hotkeyIndicator = document.getElementById('hotkey-indicator');
const setupPanel = document.getElementById('setup-panel');
const mainPanel = document.getElementById('main-panel');
const modelListEl = document.getElementById('model-list');

/** @type {string[]} */
let transcriptionHistory = [];

// ─── Init ────────────────────────────────────────────────────────────
async function init() {
  const state = await window.krakwhisper.getState();
  const settings = await window.krakwhisper.getSettings();

  updateRecordingUI(state.isRecording);
  modelIndicator.textContent = `Model: ${settings.model}`;
  hotkeyIndicator.textContent = `Hotkey: ${settings.hotkey}`;

  // Load models for setup panel
  await loadModels();
}

// ─── Recording ───────────────────────────────────────────────────────
recordBtn.addEventListener('click', async () => {
  await window.krakwhisper.toggleRecording();
});

function updateRecordingUI(isRecording) {
  if (isRecording) {
    recordBtn.classList.add('recording');
    recordIcon.textContent = '⏹';
    recordStatus.textContent = 'Recording... click to stop';
    recordStatus.classList.add('recording');
  } else {
    recordBtn.classList.remove('recording');
    recordIcon.textContent = '🎙';
    recordStatus.textContent = 'Press to record';
    recordStatus.classList.remove('recording');
  }
}

// ─── Transcription Display ───────────────────────────────────────────
function showTranscription(text) {
  transcriptionHistory.push(text);

  // Build display
  transcriptionOutput.innerHTML = '';
  transcriptionHistory.forEach((entry) => {
    const p = document.createElement('p');
    p.textContent = entry;
    transcriptionOutput.appendChild(p);
  });

  // Scroll to bottom
  transcriptionOutput.scrollTop = transcriptionOutput.scrollHeight;

  // Enable buttons
  copyBtn.disabled = false;
  clearBtn.disabled = false;
}

copyBtn.addEventListener('click', async () => {
  const text = transcriptionHistory.join('\n');
  await window.krakwhisper.copyToClipboard(text);
  copyBtn.textContent = '✅ Copied!';
  setTimeout(() => { copyBtn.textContent = '📋 Copy to Clipboard'; }, 2000);
});

clearBtn.addEventListener('click', () => {
  transcriptionHistory = [];
  transcriptionOutput.innerHTML = '<p class="placeholder">Transcribed text will appear here...</p>';
  copyBtn.disabled = true;
  clearBtn.disabled = true;
});

// ─── Model Setup ─────────────────────────────────────────────────────
async function loadModels() {
  const models = await window.krakwhisper.getAvailableModels();
  modelListEl.innerHTML = '';

  models.forEach((model) => {
    const card = document.createElement('div');
    card.className = 'model-card';
    card.id = `model-card-${model.name.replace('.', '-')}`;

    const info = document.createElement('div');
    info.className = 'model-info';
    info.innerHTML = `
      <h3>${model.name}</h3>
      <span class="model-size">~${model.size} MB</span>
    `;

    const actions = document.createElement('div');
    actions.className = 'model-actions';

    if (model.downloaded) {
      const badge = document.createElement('span');
      badge.className = 'badge';
      badge.textContent = '✓ Downloaded';
      actions.appendChild(badge);

      const deleteBtn = document.createElement('button');
      deleteBtn.className = 'btn btn-danger';
      deleteBtn.textContent = '🗑';
      deleteBtn.title = 'Delete model';
      deleteBtn.addEventListener('click', async () => {
        const result = await window.krakwhisper.deleteModel(model.name);
        if (result.success) await loadModels();
      });
      actions.appendChild(deleteBtn);
    } else {
      const downloadBtn = document.createElement('button');
      downloadBtn.className = 'btn btn-primary';
      downloadBtn.textContent = '⬇ Download';
      downloadBtn.addEventListener('click', async () => {
        downloadBtn.disabled = true;
        downloadBtn.textContent = 'Downloading...';

        // Add progress bar
        const progressBar = document.createElement('div');
        progressBar.className = 'progress-bar';
        const progressFill = document.createElement('div');
        progressFill.className = 'progress-bar-fill';
        progressFill.id = `progress-${model.name.replace('.', '-')}`;
        progressBar.appendChild(progressFill);
        actions.insertBefore(progressBar, downloadBtn);

        const result = await window.krakwhisper.downloadModel(model.name);
        if (result.success) {
          await loadModels();
        } else {
          downloadBtn.disabled = false;
          downloadBtn.textContent = '⬇ Retry';
          progressBar.remove();
        }
      });
      actions.appendChild(downloadBtn);
    }

    card.appendChild(info);
    card.appendChild(actions);
    modelListEl.appendChild(card);
  });
}

// ─── IPC Event Listeners ─────────────────────────────────────────────
window.krakwhisper.onStateUpdate((state) => {
  updateRecordingUI(state.isRecording);
  if (state.model) {
    modelIndicator.textContent = `Model: ${state.model}`;
  }
});

window.krakwhisper.onTranscriptionResult((text) => {
  recordStatus.textContent = 'Press to record';
  recordStatus.classList.remove('recording');
  showTranscription(text);
});

window.krakwhisper.onStatusUpdate((status) => {
  recordStatus.textContent = status;
});

window.krakwhisper.onDownloadProgress((data) => {
  const progressEl = document.getElementById(`progress-${data.model.replace('.', '-')}`);
  if (progressEl) {
    progressEl.style.width = `${data.progress}%`;
  }
});

window.krakwhisper.onShowSetup(() => {
  setupPanel.classList.remove('hidden');
  loadModels();
});

window.krakwhisper.onError((msg) => {
  recordStatus.textContent = msg;
  recordStatus.classList.remove('recording');
});

// ─── Start ───────────────────────────────────────────────────────────
init();
