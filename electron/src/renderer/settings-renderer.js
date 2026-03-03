// ─── DOM Elements ────────────────────────────────────────────────────
const modelSelect = document.getElementById('model-select');
const hotkeyInput = document.getElementById('hotkey-input');
const autoCopyCheckbox = document.getElementById('auto-copy');
const showNotificationCheckbox = document.getElementById('show-notification');
const settingsForm = document.getElementById('settings-form');
const saveStatus = document.getElementById('save-status');

// ─── Electron key → accelerator mapping ──────────────────────────────
const KEY_MAP = {
  Control: 'CommandOrControl',
  Meta: 'CommandOrControl',
  Alt: 'Alt',
  Shift: 'Shift',
};

// ─── Init ────────────────────────────────────────────────────────────
async function init() {
  const settings = await window.krakwhisper.getSettings();

  modelSelect.value = settings.model;
  hotkeyInput.value = settings.hotkey;
  autoCopyCheckbox.checked = settings.autoCopy;
  showNotificationCheckbox.checked = settings.showNotification;
}

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
  if (!['Control', 'Meta', 'Alt', 'Shift'].includes(key)) {
    // Normalize key names for Electron accelerator format
    const normalizedKey = key === ' ' ? 'Space' : key.length === 1 ? key.toUpperCase() : key;
    parts.push(normalizedKey);
  }

  if (parts.length > 1) {
    hotkeyInput.value = parts.join('+');
  }
});

// ─── Save ────────────────────────────────────────────────────────────
settingsForm.addEventListener('submit', async (e) => {
  e.preventDefault();

  const settings = {
    model: modelSelect.value,
    hotkey: hotkeyInput.value,
    autoCopy: autoCopyCheckbox.checked,
    showNotification: showNotificationCheckbox.checked,
  };

  const result = await window.krakwhisper.saveSettings(settings);

  if (result.success) {
    saveStatus.textContent = '✓ Settings saved!';
    setTimeout(() => { saveStatus.textContent = ''; }, 2000);
  } else {
    saveStatus.textContent = '✗ Failed to save';
    saveStatus.style.color = '#e74c3c';
    setTimeout(() => {
      saveStatus.textContent = '';
      saveStatus.style.color = '';
    }, 2000);
  }
});

// ─── Start ───────────────────────────────────────────────────────────
init();
