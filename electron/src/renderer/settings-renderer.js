// ─── DOM Elements ────────────────────────────────────────────────────
const modelSelect = document.getElementById('model-select');
const hotkeyInput = document.getElementById('hotkey-input');
const autoCopyCheckbox = document.getElementById('auto-copy');
const autoPasteCheckbox = document.getElementById('auto-paste');
const autoCleanupCheckbox = document.getElementById('auto-cleanup');
const showNotificationCheckbox = document.getElementById('show-notification');
const launchAtStartupCheckbox = document.getElementById('launch-at-startup');
const settingsForm = document.getElementById('settings-form');
const saveStatus = document.getElementById('save-status');

// Server status elements
const whisperStatusBadge = document.getElementById('whisper-status');
const llamaStatusBadge = document.getElementById('llama-status');
const whisperErrorEl = document.getElementById('whisper-error');
const llamaErrorEl = document.getElementById('llama-error');
const restartServersBtn = document.getElementById('restart-servers-btn');

// Keys that are NOT valid as the final key (modifier-only combos are invalid)
const MODIFIER_KEYS = new Set(['Control', 'Meta', 'Alt', 'Shift']);

// ─── Init ────────────────────────────────────────────────────────────
/** Initialize settings UI: load current settings, wire up event handlers. */
async function init() {
  const settings = await window.krakwhisper.getSettings();

  modelSelect.value = settings.model;
  hotkeyInput.value = settings.hotkey;
  autoCopyCheckbox.checked = settings.autoCopy;
  autoPasteCheckbox.checked = settings.autoPaste !== false;
  autoCleanupCheckbox.checked = settings.autoCleanup || false;
  showNotificationCheckbox.checked = settings.showNotification;
  launchAtStartupCheckbox.checked = settings.launchAtStartup || false;

  // Load server status
  await refreshServerStatus();

  // Handle startup toggle immediately (no need to save)
  launchAtStartupCheckbox.addEventListener('change', async () => {
    const desired = launchAtStartupCheckbox.checked;
    launchAtStartupCheckbox.disabled = true;
    try {
      const result = await window.krakwhisper.setStartupEnabled(desired);
      if (!result.success) {
        launchAtStartupCheckbox.checked = !desired;
        showSaveError(result.error || 'Failed to update startup setting');
      }
    } catch {
      launchAtStartupCheckbox.checked = !desired;
      showSaveError('Failed to update startup setting');
    } finally {
      launchAtStartupCheckbox.disabled = false;
    }
  });
}

// ─── Server Status ───────────────────────────────────────────────────
/** Fetch current server status from main process and update UI. */
async function refreshServerStatus() {
  try {
    const status = await window.krakwhisper.getServerStatus();
    updateServerUI(status);
  } catch {
    whisperStatusBadge.textContent = 'unknown';
    llamaStatusBadge.textContent = 'unknown';
  }
}

/** Update server status badges and error displays from a status object.
 * @param {object} status - Server status containing whisper and llama sub-objects.
 */
function updateServerUI(status) {
  if (status.whisper) {
    updateBadge(whisperStatusBadge, status.whisper.status);
    if (status.whisper.error && status.whisper.status === 'error') {
      whisperErrorEl.textContent = status.whisper.error;
      whisperErrorEl.style.display = 'block';
    } else {
      whisperErrorEl.style.display = 'none';
    }
  }

  if (status.llama) {
    updateBadge(llamaStatusBadge, status.llama.status);
    if (status.llama.error && status.llama.status === 'error') {
      llamaErrorEl.textContent = status.llama.error;
      llamaErrorEl.style.display = 'block';
    } else {
      llamaErrorEl.style.display = 'none';
    }
  }
}

/** Update a status badge element's text and CSS class.
 * @param {HTMLElement} element - Badge DOM element.
 * @param {string} status - Status string (stopped/starting/running/error).
 */
function updateBadge(element, status) {
  element.textContent = status;
  element.className = 'server-badge ' + status;
}

// Listen for server status updates from main process
window.krakwhisper.onServerStatus((status) => {
  updateServerUI(status);
});

// Restart servers button
restartServersBtn.addEventListener('click', async () => {
  restartServersBtn.disabled = true;
  restartServersBtn.textContent = '⏳ Restarting...';

  try {
    const result = await window.krakwhisper.restartServers();
    if (!result.success) {
      showSaveError(result.error || 'Failed to restart servers');
    }
  } catch (err) {
    showSaveError('Failed to restart servers');
  } finally {
    restartServersBtn.disabled = false;
    restartServersBtn.textContent = '🔄 Restart Servers';
    await refreshServerStatus();
  }
});

// ─── Hotkey Capture ──────────────────────────────────────────────────
hotkeyInput.addEventListener('keydown', (e) => {
  e.preventDefault();
  e.stopPropagation();

  const parts = [];
  if (e.ctrlKey || e.metaKey) parts.push('CommandOrControl');
  if (e.altKey) parts.push('Alt');
  if (e.shiftKey) parts.push('Shift');

  // Add the actual key (if it's not just a modifier)
  const key = e.key;
  if (!MODIFIER_KEYS.has(key)) {
    const normalizedKey = key === ' ' ? 'Space' : key.length === 1 ? key.toUpperCase() : key;
    parts.push(normalizedKey);

    if (parts.length >= 2) {
      hotkeyInput.value = parts.join('+');
    }
  }
});

// ─── Save ────────────────────────────────────────────────────────────
settingsForm.addEventListener('submit', async (e) => {
  e.preventDefault();

  // Validate hotkey has a non-modifier key
  const hotkey = hotkeyInput.value;
  const hotkeyParts = hotkey.split('+');
  const nonModifiers = hotkeyParts.filter((p) =>
    !['CommandOrControl', 'Alt', 'Shift', 'Control', 'Meta'].includes(p)
  );
  if (nonModifiers.length === 0) {
    showSaveError('Hotkey must include a non-modifier key');
    return;
  }

  const settings = {
    model: modelSelect.value,
    hotkey: hotkeyInput.value,
    autoCopy: autoCopyCheckbox.checked,
    autoPaste: autoPasteCheckbox.checked,
    autoCleanup: autoCleanupCheckbox.checked,
    showNotification: showNotificationCheckbox.checked,
  };

  const result = await window.krakwhisper.saveSettings(settings);

  if (result.success) {
    saveStatus.textContent = '✓ Settings saved!';
    saveStatus.style.color = '';
    setTimeout(() => { saveStatus.textContent = ''; }, 2000);
  } else {
    showSaveError(result.error || 'Failed to save');
  }
});

/** Display a save error message in the status area, auto-clearing after 4s.
 * @param {string} message - Error message to display.
 */
function showSaveError(message) {
  saveStatus.textContent = '✗ ' + message;
  saveStatus.style.color = '#e74c3c';
  setTimeout(() => {
    saveStatus.textContent = '';
    saveStatus.style.color = '';
  }, 4000);
}

// ─── Start ───────────────────────────────────────────────────────────
init();
