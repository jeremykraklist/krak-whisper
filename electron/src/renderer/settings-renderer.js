// ─── DOM Elements ────────────────────────────────────────────────────
const modelSelect = document.getElementById('model-select');
const hotkeyInput = document.getElementById('hotkey-input');
const autoCopyCheckbox = document.getElementById('auto-copy');
const showNotificationCheckbox = document.getElementById('show-notification');
const settingsForm = document.getElementById('settings-form');
const saveStatus = document.getElementById('save-status');

// Keys that are NOT valid as the final key (modifier-only combos are invalid)
const MODIFIER_KEYS = new Set(['Control', 'Meta', 'Alt', 'Shift']);

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
  if (!MODIFIER_KEYS.has(key)) {
    // Normalize key names for Electron accelerator format
    const normalizedKey = key === ' ' ? 'Space' : key.length === 1 ? key.toUpperCase() : key;
    parts.push(normalizedKey);

    // Only update if we have at least one modifier + one non-modifier key
    if (parts.length >= 2) {
      hotkeyInput.value = parts.join('+');
    }
  }
  // If only modifiers are pressed, don't update — wait for a non-modifier key
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
    saveStatus.textContent = '✗ Hotkey must include a non-modifier key';
    saveStatus.style.color = '#e74c3c';
    setTimeout(() => {
      saveStatus.textContent = '';
      saveStatus.style.color = '';
    }, 3000);
    return;
  }

  const settings = {
    model: modelSelect.value,
    hotkey: hotkeyInput.value,
    autoCopy: autoCopyCheckbox.checked,
    showNotification: showNotificationCheckbox.checked,
  };

  const result = await window.krakwhisper.saveSettings(settings);

  if (result.success) {
    saveStatus.textContent = '✓ Settings saved!';
    saveStatus.style.color = '';
    setTimeout(() => { saveStatus.textContent = ''; }, 2000);
  } else {
    saveStatus.textContent = result.error || '✗ Failed to save';
    saveStatus.style.color = '#e74c3c';
    setTimeout(() => {
      saveStatus.textContent = '';
      saveStatus.style.color = '';
    }, 4000);
  }
});

// ─── Start ───────────────────────────────────────────────────────────
init();
